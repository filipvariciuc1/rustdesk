// A seat card (Casier / Secretar on the NUC) shows its Remote Desktop inside a
// tab of the remote window, like RDCMan or mRemoteNG, instead of in mstsc.
//
// Rust starts rdp-view.exe (the RDP ActiveX in a borderless window) when the
// peer option `rdp_view_ctl` holds a loopback port. This tab listens on that
// port; rdp-view connects, becomes a child window of this tab window, and is
// told where the tab's page is (physical px inside the Flutter view) and when
// to show or hide. Closing the tab closes the socket, which ends rdp-view and,
// through Rust, the RDP tunnel.
//
// The session lives here, not in the page's State: tab pages can be disposed
// on tab switch.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:win32/win32.dart' as win32;

import '../../common.dart';

const kSeatTabPrefix = 'seat:';

bool isSeatTabKey(String key) => key.startsWith(kSeatTabPrefix);

class SeatRdpSession {
  static final Map<String, SeatRdpSession> all = {};
  static final Map<int, int> _hwndByWindow = {};

  final String key, name;
  final int windowId;
  final bool Function() selected;
  final void Function() ended;
  final viewKey = GlobalKey();

  /// waiting (for rdp-view), connecting, connected, failed.
  final phase = 'waiting'.obs;
  ServerSocket? _server;
  Socket? _sock;
  Timer? _tick, _giveUp;
  bool _wasConnected = false;
  bool? _shown;
  String _lastRect = '';
  int _hwnd = 0;

  SeatRdpSession._(
      this.key, this.name, this.windowId, this.selected, this.ended);

  bool get live => phase.value != 'failed';

  /// Opens (or reopens after a failure) the seat's session. Returns the
  /// control port for Rust, or 'open' when a live session already exists.
  static Future<String> open(String key, String name,
      {required int windowId,
      required bool Function() selected,
      required void Function() ended}) async {
    final old = all[key];
    if (old != null && old.live) return 'open';
    final s = old ?? SeatRdpSession._(key, name, windowId, selected, ended);
    all[key] = s;
    return await s._start();
  }

  Future<String> _start() async {
    _stop();
    phase.value = 'waiting';
    _wasConnected = false;
    _shown = null;
    _lastRect = '';
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_onHelper);
    // rdp-view starts once the RDP tunnel is up; give up after a minute.
    _giveUp = Timer(const Duration(seconds: 60), () {
      if (_sock == null) _fail('no rdp-view after 60 s');
    });
    return server.port.toString();
  }

  void _onHelper(Socket sock) async {
    if (_sock != null) {
      sock.destroy();
      return;
    }
    _sock = sock;
    _giveUp?.cancel();
    sock.setOption(SocketOption.tcpNoDelay, true);
    phase.value = 'connecting';
    sock
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onHelperGone, onError: (_) => _onHelperGone());
    final hwnd = await _windowHwnd();
    if (hwnd == 0) {
      _fail('tab window handle not found');
      return;
    }
    _hwnd = hwnd;
    _send('parent $hwnd');
    _tick = Timer.periodic(const Duration(milliseconds: 150), (_) => _sync());
    _sync();
  }

  void _onLine(String line) {
    debugPrint('[seat $name] $line');
    if (line.startsWith('state connected')) {
      _wasConnected = true;
      phase.value = 'connected';
    } else if (line.startsWith('state disconnected')) {
      _onHelperGone();
    }
  }

  void _onHelperGone() {
    if (_sock == null) return;
    if (_wasConnected) {
      // The session ended (signed out, or closed on the PC): close the tab.
      _stop();
      ended();
    } else {
      _fail('rdp-view ended before connecting');
    }
  }

  void _fail(String why) {
    debugPrint('[seat $name] failed: $why');
    _stop();
    phase.value = 'failed';
  }

  /// Tells rdp-view where the page is and whether it can be seen.
  void _sync() {
    final ctx = viewKey.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    final visible = selected() &&
        box != null &&
        box.attached &&
        box.hasSize &&
        win32.IsWindowVisible(_hwnd) != 0 &&
        win32.IsIconic(_hwnd) == 0;
    if (visible) {
      final dpr = View.of(ctx!).devicePixelRatio;
      final o = box.localToGlobal(Offset.zero);
      final r = '${(o.dx * dpr).round()} ${(o.dy * dpr).round()} '
          '${(box.size.width * dpr).round()} ${(box.size.height * dpr).round()} '
          '${(dpr * 100).round()}';
      // The first rect starts the RDP connection, at this size.
      if (r != _lastRect) {
        _lastRect = r;
        _send('rect $r');
      }
    }
    if (visible != _shown && (visible || _shown != null)) {
      _shown = visible;
      _send(visible ? 'show' : 'hide');
    }
  }

  void focus() => _send('focus');

  void _send(String s) {
    try {
      _sock?.write('$s\n');
    } catch (_) {}
  }

  /// The tab window's HWND: give it a unique title for a moment and look it up.
  Future<int> _windowHwnd() async {
    final cached = _hwndByWindow[windowId];
    if (cached != null && win32.IsWindow(cached) != 0) return cached;
    final wc = WindowController.fromWindowId(windowId);
    final marker = 'rdpview-${DateTime.now().microsecondsSinceEpoch}';
    var hwnd = 0;
    await wc.setTitle(marker);
    final p = marker.toNativeUtf16();
    try {
      for (var i = 0; i < 20 && hwnd == 0; i++) {
        hwnd = win32.FindWindow(nullptr, p);
        if (hwnd == 0) await Future.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      calloc.free(p);
    }
    await wc.setTitle(selected() ? name : getWindowName());
    if (hwnd != 0) _hwndByWindow[windowId] = hwnd;
    return hwnd;
  }

  void _stop() {
    _tick?.cancel();
    _tick = null;
    _giveUp?.cancel();
    _giveUp = null;
    final sock = _sock;
    _sock = null;
    try {
      sock?.destroy();
    } catch (_) {}
    _server?.close();
    _server = null;
  }

  /// Tab closed: ends rdp-view (socket EOF) and with it the tunnel.
  void close() {
    _stop();
    all.remove(key);
  }
}

/// The page under rdp-view's window. Shows a spinner until rdp-view covers
/// it, or the failure text.
class SeatRdpView extends StatelessWidget {
  final SeatRdpSession session;

  const SeatRdpView({Key? key, required this.session}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => session.focus(),
      child: Container(
        key: session.viewKey,
        color: const Color(0xFF1E1E1E),
        alignment: Alignment.center,
        child: Obx(() {
          final failed = session.phase.value == 'failed';
          const style = TextStyle(color: Colors.white70, fontSize: 14);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: failed
                ? [
                    Text(
                        'Could not open ${session.name}. Close this tab and try again.',
                        style: style),
                  ]
                : [
                    const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 3)),
                    const SizedBox(height: 14),
                    Text('Opening ${session.name}...', style: style),
                  ],
          );
        }),
      ),
    );
  }
}
