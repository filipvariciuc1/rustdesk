// Church PC power buttons (fork-only). Power ON only: the plug is never left
// off, so the PC's own power button keeps working as usual.
//
// Config, read fresh on every click. The first one found wins:
//   1. Windows: %APPDATA%\RustDesk\config\church-power.json (admin PC)
//      { "url": "https://...",
//        "key": "long random key the Worker checks (X-Church-Key header)",
//        "accessClientId": "...", "accessClientSecret": "...",  (optional
//            Cloudflare Access service token, CF-Access-Client-Id / -Secret)
//        "peers": { "<rustdesk id>": "<plug id>" },
//        "testCommand": "optional: Power off sends this instead of shutdown" }
//   2. Any platform: RustDesk local option "church-power", written by
//      "Import church PCs" (a CMS key traded once for a device token):
//      { "url": "...", "token": "...", "peers": { "<rustdesk id>": "" } }
//      An empty plug id means "ask by RustDesk id"; the Worker knows the plug.
//
// Power on:  asks the Worker to switch the plug on (the Worker power-cycles it
//            if the plug is already on and the PC is off).
// Power off: desktop only. Shuts Windows down over a hidden terminal session.
//            The plug stays on.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../common.dart';
import '../consts.dart';
import 'formatter/id_formatter.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import '../models/terminal_model.dart';
import '../desktop/pages/computers_tab.dart';
import '../utils/multi_window_manager.dart';

class ChurchPowerConfig {
  final String url;
  final Map<String, String> headers;
  final Map<String, String> peers;
  final String? testCommand;
  ChurchPowerConfig(this.url, this.headers, this.peers, this.testCommand);
}

class _Cancelled implements Exception {}

/// One person's half of a shared PC (the NUC runs two seats). Its card has
/// its own id and opens RDP, through RustDesk, to [peer] as [user].
class ChurchSeat {
  final String id, peer, name, user;
  const ChurchSeat(this.id, this.peer, this.name, this.user);
}

class ChurchPower {
  static const defaultUrl = 'https://church-power.hz-relay-mi5cp4r0.workers.dev';
  static const _opt = 'church-power';

  static const seats = [
    ChurchSeat('nuc-casier', '190681964', 'Casier', r'PASTORAL-OFFICE\Casier'),
    ChurchSeat(
        'nuc-secretar', '190681964', 'Secretar', r'PASTORAL-OFFICE\Secretar'),
  ];

  static ChurchSeat? seatFor(String id) {
    final c = id.replaceAll(' ', '');
    for (final s in seats) {
      if (s.id == c) return s;
    }
    return null;
  }

  /// A seat card's real RustDesk id; any other id unchanged.
  static String realId(String id) =>
      seatFor(id)?.peer ?? id.replaceAll(' ', '');

  /// Seat cards are asked about as their real PC, so they show its online dot.
  static List<String> onlineQueryIds(Iterable<String> ids) =>
      ids.map(realId).toSet().toList(growable: false);

  /// Adds the seat cards to Favorites once, on Windows (RDP needs mstsc),
  /// when this device knows the PC they live on.
  static Future<void> ensureSeats() async {
    if (!Platform.isWindows) return;
    final favs = (await bind.mainGetFav()).toList();
    var added = false;
    for (final s in seats) {
      if (await bind.mainPeerExists(id: s.id)) continue;
      if (!await bind.mainPeerExists(id: s.peer)) continue;
      await bind.mainSetPeerOption(
          id: s.id, key: 'church_platform', value: 'Windows');
      await bind.mainSetPeerOption(id: s.id, key: 'rdp_username', value: s.user);
      await bind.mainSetPeerAlias(id: s.id, alias: s.name);
      if (!favs.contains(s.id)) favs.add(s.id);
      added = true;
    }
    if (!added) return;
    await bind.mainStoreFav(favs: favs);
    bind.mainLoadFavPeers();
    bind.mainLoadRecentPeers();
  }

  /// Hands the seat's RDP user (and password, if saved on the seat card) to
  /// the real PC's settings, which the RDP launcher reads. Returns the real id.
  static Future<String> prepareSeat(ChurchSeat s) async {
    var user = await bind.mainGetPeerOption(id: s.id, key: 'rdp_username');
    if (user.isEmpty) user = s.user;
    final pass = await bind.mainGetPeerOption(id: s.id, key: 'rdp_password');
    await bind.mainSetPeerOption(id: s.peer, key: 'rdp_username', value: user);
    await bind.mainSetPeerOption(id: s.peer, key: 'rdp_password', value: pass);
    return s.peer;
  }

  /// Main isolate: opens the seat's tab in the remote window (creating the
  /// window if needed) and returns the control port rdp-view should call, or
  /// 'open' when the seat's tab is already live, or null on failure.
  static Future<String?> openSeatTab(ChurchSeat s) async {
    final args = jsonEncode({'key': 'seat:${s.id}', 'name': s.name});
    var r = await rustDeskWinManager.call(
        WindowType.RemoteDesktop, kWindowOpenSeatTab, args);
    if (r.windowId == kInvalidWindowId) {
      await rustDeskWinManager.newRemoteDesktop(kComputersTabKey);
      for (var i = 0; i < 17; i++) {
        await Future.delayed(const Duration(milliseconds: 300));
        try {
          r = await rustDeskWinManager.call(
              WindowType.RemoteDesktop, kWindowOpenSeatTab, args);
        } catch (_) {
          continue;
        }
        if (r.result is String && (r.result as String).isNotEmpty) break;
      }
    }
    final port = r.result;
    return port is String && port.isNotEmpty ? port : null;
  }

  static String _clean(String id) => realId(id);

  static Map<String, dynamic>? _readFile() {
    if (!Platform.isWindows) return null;
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return null;
    final f = File('$appData\\RustDesk\\config\\church-power.json');
    if (!f.existsSync()) return null;
    final j = jsonDecode(f.readAsStringSync());
    return j is Map<String, dynamic> ? j : null;
  }

  static Map<String, dynamic>? _readOption() {
    final s = bind.mainGetLocalOption(key: _opt);
    if (s.isEmpty) return null;
    final j = jsonDecode(s);
    return j is Map<String, dynamic> ? j : null;
  }

  static ChurchPowerConfig? _load() {
    try {
      final j = _readFile() ?? _readOption();
      if (j == null) return null;
      final url = (j['url'] ?? '').toString().replaceAll(RegExp(r'/+$'), '');
      final headers = <String, String>{'Content-Type': 'application/json'};
      void header(String name, dynamic v) {
        final s = (v ?? '').toString();
        if (s.isNotEmpty) headers[name] = s;
      }

      header('X-Church-Key', j['key']);
      header('X-Church-Token', j['token']);
      header('CF-Access-Client-Id', j['accessClientId']);
      header('CF-Access-Client-Secret', j['accessClientSecret']);
      final peers = <String, String>{};
      (j['peers'] as Map? ?? {}).forEach((k, v) {
        peers[_clean(k.toString())] = (v ?? '').toString();
      });
      final test = j['testCommand']?.toString();
      if (url.isEmpty || headers.length < 2) return null;
      return ChurchPowerConfig(
          url, headers, peers, (test == null || test.isEmpty) ? null : test);
    } catch (e) {
      debugPrint('[ChurchPower] bad config: $e');
      return null;
    }
  }

  /// The plug id for this peer ('' = the server knows it), or null when this
  /// peer has no plug.
  static String? plugFor(String peerId) => _load()?.peers[_clean(peerId)];

  static Map<String, dynamic> _onBody(String peerId, String plug) =>
      plug.isEmpty
          ? {'peer': _clean(peerId), 'on': true}
          : {'plug': plug, 'on': true};

  // ---------- Worker calls ----------

  static Future<Map<String, dynamic>> _postTo(String url,
      Map<String, String> headers, Map<String, dynamic> body) async {
    try {
      final r = await http
          .post(Uri.parse(url), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      dynamic j;
      try {
        j = jsonDecode(r.body);
      } catch (_) {}
      final err = j is Map ? j['error'] : null;
      if (r.statusCode >= 300) {
        if (err != null) return {'error': err.toString()};
        return {'error': 'The power server refused this PC.'};
      }
      if (j is Map<String, dynamic>) return j;
      return {'error': 'The power server sent a bad answer.'};
    } on TimeoutException {
      return {'error': 'The power server did not answer. Check the internet.'};
    } catch (e) {
      return {'error': 'Could not reach the power server. Check the internet.'};
    }
  }

  static Future<Map<String, dynamic>> _post(
          ChurchPowerConfig c, String path, Map<String, dynamic> body) =>
      _postTo('${c.url}$path', c.headers, body);

  // ---------- UI helpers ----------

  static void _message(String title, String text) {
    gFFI.dialogManager.show((setState, close, context) => CustomAlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [dialogButton('OK', onPressed: close)],
          onSubmit: close,
          onCancel: close,
        ));
  }

  static Future<bool> _confirmOff(String name) async {
    final r = await gFFI.dialogManager.show<bool>(
        (setState, close, context) => CustomAlertDialog(
              title: Text('Power off $name?'),
              content: const Text(
                  'Windows will shut down. Unsaved work on that PC will be lost.'),
              actions: [
                dialogButton('Cancel',
                    onPressed: () => close(false), isOutline: true),
                dialogButton('Power off', onPressed: () => close(true)),
              ],
              onSubmit: () => close(true),
              onCancel: () => close(false),
            ));
    return r == true;
  }

  /// Shows a progress dialog. Returns its tag and a step-text notifier.
  static (String, ValueNotifier<String>) _progress(
      String title, void Function() onCancel) {
    final step = ValueNotifier<String>('Starting...');
    final tag = 'church-power-${DateTime.now().microsecondsSinceEpoch}';
    gFFI.dialogManager.show((setState, close, context) {
      cancel() {
        onCancel();
        close();
      }

      return CustomAlertDialog(
        title: Text(title),
        content: Row(children: [
          const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 16),
          Expanded(
              child: ValueListenableBuilder<String>(
                  valueListenable: step, builder: (_, v, __) => Text(v))),
        ]),
        actions: [dialogButton('Cancel', onPressed: cancel, isOutline: true)],
        onCancel: cancel,
      );
    }, tag: tag);
    return (tag, step);
  }

  // ---------- Power on ----------

  static Future<void> powerOn(String peerId, String name) async {
    final c = _load();
    final plug = c?.peers[_clean(peerId)];
    if (c == null || plug == null) {
      _message('Power on', 'This PC has no power plug set up.');
      return;
    }
    var cancelled = false;
    final (tag, step) = _progress('Power on $name', () => cancelled = true);
    step.value = 'Turning the plug on...';
    final r = await _post(c, '/api/switch', _onBody(peerId, plug));
    gFFI.dialogManager.dismissByTag(tag);
    if (cancelled) return;
    if (r['error'] != null) {
      _message('Power on $name', r['error'].toString());
    } else {
      showToast((r['message'] ?? 'Power is on. The PC will start.').toString(),
          timeout: const Duration(seconds: 5));
    }
  }

  // ---------- Double-click on a PC that is off ----------

  static String nameFor(String peerId) {
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    return alias.isEmpty ? formatID(peerId) : alias;
  }

  static Future<bool> askPowerOn(String name, {OverlayDialogManager? dm}) async {
    final r = await (dm ?? gFFI.dialogManager).show<bool>(
        (setState, close, context) => CustomAlertDialog(
              title: Text(name),
              content: const Text(
                  'Target device is offline or powered off. Power on?'),
              actions: [
                dialogButton('No',
                    onPressed: () => close(false), isOutline: true),
                dialogButton('Yes', onPressed: () => close(true)),
              ],
              onSubmit: () => close(true),
              onCancel: () => close(false),
            ));
    return r == true;
  }

  /// Main window: double-click on an offline card. Returns false when this
  /// card has no plug, so the caller connects as usual.
  static bool onDoubleClick(String peerId, bool online, String name) {
    if (online || plugFor(peerId) == null) return false;
    () async {
      if (await askPowerOn(name)) await powerOn(peerId, name);
    }();
    return true;
  }

  /// Remote window: the connection failed because the PC is offline. Offers
  /// Power on, then shows the usual error box (with Retry) with the result.
  static bool onOfflineInSession(String peerId, String type, String text,
      OverlayDialogManager dm, void Function(String title, String text) box) {
    if (type != 'error' ||
        // "Remote desktop is offline", or the rendezvous server's
        // "Failed to connect: the target device is offline or does not exist."
        !text.toLowerCase().contains('offline') ||
        plugFor(peerId) == null) {
      return false;
    }
    () async {
      if (!await askPowerOn(nameFor(peerId), dm: dm)) {
        box('Connection Error', text);
        return;
      }
      final c = _load();
      final plug = c?.peers[_clean(peerId)];
      if (c == null || plug == null) {
        box('Power on', 'This PC has no power plug set up.');
        return;
      }
      final tag = dm.showLoading('Turning the plug on...', showCancel: false);
      final r = await _post(c, '/api/switch', _onBody(peerId, plug));
      dm.dismissByTag(tag);
      box('Power on',
          (r['error'] ?? r['message'] ?? 'Power is on. The PC will start.')
              .toString());
    }();
    return true;
  }

  // ---------- Power off (Windows shutdown only, plug stays on) ----------

  static Future<void> powerOff(String peerId, String name) async {
    final c = _load();
    if (c == null || c.peers[_clean(peerId)] == null) {
      _message('Power off', 'This PC has no power plug set up.');
      return;
    }
    if (!await _confirmOff(name)) return;

    var cancelled = false;
    final (tag, step) = _progress('Power off $name', () => cancelled = true);
    void check() {
      if (cancelled) throw _Cancelled();
    }

    try {
      final test = c.testCommand;
      step.value =
          test != null ? 'Sending the test command...' : 'Shutting down Windows...';
      final sent =
          await _runOnPeer(peerId, test ?? 'shutdown /s /f /t 0', check);
      gFFI.dialogManager.dismissByTag(tag);
      if (!sent) {
        _message('Power off $name', 'Could not reach that PC to shut it down.');
      } else if (test != null) {
        showToast('Test command sent.');
      } else {
        showToast('$name is shutting down.',
            timeout: const Duration(seconds: 5));
      }
    } on _Cancelled {
      // The user closed the dialog. Stop quietly.
    } catch (e) {
      gFFI.dialogManager.dismissByTag(tag);
      _message('Power off $name', e.toString());
    }
  }

  // ---------- Import church PCs (CMS key -> device token) ----------

  static Future<String> _deviceName() async {
    try {
      if (Platform.isAndroid) {
        final a = await DeviceInfoPlugin().androidInfo;
        return '${a.brand} ${a.model}';
      }
      return Platform.localHostname;
    } catch (_) {
      return Platform.operatingSystem;
    }
  }

  static Future<void> importChurchPCs() async {
    final ctrl = TextEditingController();
    final key = await gFFI.dialogManager.show<String>(
        (setState, close, context) {
      submit() {
        final k = ctrl.text.trim();
        if (k.isNotEmpty) close(k);
      }

      return CustomAlertDialog(
        title: const Text('Import church PCs'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Paste the key from the church CMS.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration:
                  const InputDecoration(labelText: 'Key from the church CMS'),
              onSubmitted: (_) => submit(),
            ),
          ],
        ),
        actions: [
          dialogButton('Cancel', onPressed: () => close(null), isOutline: true),
          dialogButton('Import', onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: () => close(null),
      );
    });
    if (key == null || key.isEmpty) return;

    var cancelled = false;
    final (tag, step) =
        _progress('Import church PCs', () => cancelled = true);
    step.value = 'Checking the key...';
    final r = await _postTo(
        '$defaultUrl/api/invite/redeem',
        {'Content-Type': 'application/json'},
        {
          'key': key,
          'name': await _deviceName(),
          'platform': Platform.operatingSystem,
        });
    gFFI.dialogManager.dismissByTag(tag);
    if (cancelled) return;
    final token = (r['token'] ?? '').toString();
    if (r['error'] != null || token.isEmpty) {
      _message('Import church PCs',
          (r['error'] ?? 'The power server sent a bad answer.').toString());
      return;
    }

    final pcs = (r['pcs'] as List? ?? []).whereType<Map>().toList();
    Map<String, dynamic> old = {};
    try {
      old = _readOption() ?? {};
    } catch (_) {}
    final peers = <String, dynamic>{...(old['peers'] as Map? ?? {})};
    final favs = (await bind.mainGetFav()).toList();
    for (final pc in pcs) {
      final id = _clean((pc['id'] ?? '').toString());
      if (id.isEmpty) continue;
      if (pc['power'] == true) peers[id] = '';
      // Without a platform the peer lists hide (and delete) the entry.
      await bind.mainSetPeerOption(
          id: id, key: 'church_platform', value: 'Windows');
      final name = (pc['name'] ?? '').toString();
      if (name.isNotEmpty &&
          bind.mainGetPeerOptionSync(id: id, key: 'alias').isEmpty) {
        await bind.mainSetPeerAlias(id: id, alias: name);
      }
      if (!favs.contains(id)) favs.add(id);
    }
    await bind.mainSetLocalOption(
        key: _opt,
        value: jsonEncode({'url': defaultUrl, 'token': token, 'peers': peers}));
    await bind.mainStoreFav(favs: favs);
    bind.mainLoadRecentPeers();
    bind.mainLoadFavPeers();
    await ensureSeats();
    showToast('Added ${pcs.length} church PCs.',
        timeout: const Duration(seconds: 5));
  }

  /// Opens a hidden terminal session to [peerId], sends [command], closes it.
  /// Uses the saved peer password. Returns false if the terminal never opened.
  static Future<bool> _runOnPeer(
      String peerId, String command, void Function() check) async {
    final ffi = FFI(null);
    // Sessions are shared per (peer, kind): with a Terminal window open to
    // this PC, this run joins that connection, never gets its own "ready",
    // and terminal 0 may be the window's. So use our own terminal id and ask
    // for it ourselves until it opens.
    const tid = 77;
    final model = TerminalModel(ffi, tid);
    var sent = false;
    // RustDesk saves one terminal id per PC and reattaches to that remote
    // shell. Clear it so this run gets its own fresh shell (not the one an
    // open Terminal window is using), then put the saved id back.
    const key = 'terminal-service-id';
    final savedService = bind.mainGetPeerOptionSync(id: peerId, key: key);
    bind.mainSetPeerOptionSync(id: peerId, key: key, value: '');
    try {
      ffi.start(peerId, isTerminal: true);
      ffi.registerTerminalModel(tid, model);
      final until = DateTime.now().add(const Duration(seconds: 30));
      var nextAsk = DateTime.now().add(const Duration(seconds: 2));
      while (!model.terminalOpened && DateTime.now().isBefore(until)) {
        await Future.delayed(const Duration(milliseconds: 300));
        check();
        if (!model.terminalOpened && DateTime.now().isAfter(nextAsk)) {
          nextAsk = DateTime.now().add(const Duration(seconds: 3));
          model.openTerminal().catchError((_) {});
        }
      }
      if (!model.terminalOpened) return false;
      // A fresh shell needs a moment to start; give it time to read and
      // run the line before the terminal is closed.
      await Future.delayed(const Duration(seconds: 3));
      await bind.sessionSendTerminalInput(
          sessionId: ffi.sessionId, terminalId: tid, data: '$command\r');
      sent = true;
      await Future.delayed(const Duration(seconds: 5));
      return true;
    } finally {
      try {
        await model.closeTerminal();
      } catch (_) {}
      try {
        ffi.unregisterTerminalModel(tid);
        await ffi.close();
      } catch (_) {}
      bind.mainSetPeerOptionSync(id: peerId, key: key, value: savedService);
      debugPrint('[ChurchPower] terminal to $peerId done, sent=$sent');
    }
  }
}
