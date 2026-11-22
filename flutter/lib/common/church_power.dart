// Church PC power buttons (fork-only, Windows only).
//
// Config file, read fresh on every click:
//   %APPDATA%\RustDesk\config\church-power.json
//   { "url": "https://...",
//     "key": "long random key the Worker checks (X-Church-Key header)",
//     "accessClientId": "...", "accessClientSecret": "...",  (Cloudflare Access
//         service token, sent as CF-Access-Client-Id / -Secret)
//     "peers": { "<rustdesk id>": "<plug id>" },
//     "testCommand": "optional: Power off only sends this, no plug steps" }
//
// Power on:  asks the Worker to switch the plug on (the Worker power-cycles it
//            if the plug is already on and the PC is off).
// Power off: shuts Windows down over a hidden terminal session, waits until the
//            plug reads standby watts, then switches the plug off.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../common.dart';
import 'formatter/id_formatter.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import '../models/terminal_model.dart';

class ChurchPowerConfig {
  final String url;
  final Map<String, String> headers;
  final Map<String, String> peers;
  final String? testCommand;
  ChurchPowerConfig(this.url, this.headers, this.peers, this.testCommand);
}

class _Cancelled implements Exception {}

class ChurchPower {
  static const _offWaitLimit = Duration(minutes: 3);
  static const _pollEvery = Duration(seconds: 5);

  static ChurchPowerConfig? _load() {
    if (!Platform.isWindows) return null;
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return null;
    final f = File('$appData\\RustDesk\\config\\church-power.json');
    try {
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      final url = (j['url'] ?? '').toString().replaceAll(RegExp(r'/+$'), '');
      final headers = <String, String>{'Content-Type': 'application/json'};
      void header(String name, dynamic v) {
        final s = (v ?? '').toString();
        if (s.isNotEmpty) headers[name] = s;
      }

      header('X-Church-Key', j['key']);
      header('CF-Access-Client-Id', j['accessClientId']);
      header('CF-Access-Client-Secret', j['accessClientSecret']);
      final peers = <String, String>{};
      (j['peers'] as Map? ?? {}).forEach((k, v) {
        peers[k.toString().replaceAll(' ', '')] = v.toString();
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

  /// The plug id for this peer, or null when this peer has no plug.
  static String? plugFor(String peerId) =>
      _load()?.peers[peerId.replaceAll(' ', '')];

  // ---------- Worker calls ----------

  static Future<Map<String, dynamic>> _post(
      ChurchPowerConfig c, String path, Map<String, dynamic> body) async {
    try {
      final r = await http
          .post(Uri.parse('${c.url}$path'),
              headers: c.headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 401 || r.statusCode == 403 || r.isRedirect ||
          (r.statusCode >= 300 && r.statusCode < 400)) {
        return {'error': 'The power server refused this PC. The key is wrong.'};
      }
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic>) return j;
      return {'error': 'The power server sent a bad answer.'};
    } on TimeoutException {
      return {'error': 'The power server did not answer. Check the internet.'};
    } catch (e) {
      return {'error': 'Could not reach the power server. Check the internet.'};
    }
  }

  static Future<Map<String, dynamic>?> _plugStatus(
      ChurchPowerConfig c, String plug, void Function(String) fail) async {
    final r = await _post(c, '/api/status', {});
    if (r['error'] != null) {
      fail(r['error'].toString());
      return null;
    }
    final list = (r['plugs'] as List? ?? []);
    final p = list.cast<Map>().firstWhere((p) => p['id'] == plug,
        orElse: () => <String, dynamic>{});
    if (p.isEmpty) {
      fail('The power server does not know this plug.');
      return null;
    }
    return {
      ...p.cast<String, dynamic>(),
      'offMaxWatts': (r['offMaxWatts'] as num?) ?? 15,
    };
  }

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
    final plug = c?.peers[peerId.replaceAll(' ', '')];
    if (c == null || plug == null) {
      _message('Power on', 'This PC has no power plug set up.');
      return;
    }
    var cancelled = false;
    final (tag, step) = _progress('Power on $name', () => cancelled = true);
    step.value = 'Turning the plug on...';
    final r = await _post(c, '/api/switch', {'plug': plug, 'on': true});
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
    if (!isWindows || online || plugFor(peerId) == null) return false;
    () async {
      if (await askPowerOn(name)) await powerOn(peerId, name);
    }();
    return true;
  }

  /// Remote window: the connection failed because the PC is offline. Offers
  /// Power on, then shows the usual error box (with Retry) with the result.
  static bool onOfflineInSession(String peerId, String type, String text,
      OverlayDialogManager dm, void Function(String title, String text) box) {
    if (!isWindows ||
        type != 'error' ||
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
      final plug = c?.peers[peerId.replaceAll(' ', '')];
      if (c == null || plug == null) {
        box('Power on', 'This PC has no power plug set up.');
        return;
      }
      final tag = dm.showLoading('Turning the plug on...', showCancel: false);
      final r = await _post(c, '/api/switch', {'plug': plug, 'on': true});
      dm.dismissByTag(tag);
      box('Power on',
          (r['error'] ?? r['message'] ?? 'Power is on. The PC will start.')
              .toString());
    }();
    return true;
  }

  // ---------- Power off ----------

  static Future<void> powerOff(String peerId, String name) async {
    final c = _load();
    final plug = c?.peers[peerId.replaceAll(' ', '')];
    if (c == null || plug == null) {
      _message('Power off', 'This PC has no power plug set up.');
      return;
    }
    if (!await _confirmOff(name)) return;

    var cancelled = false;
    final (tag, step) = _progress('Power off $name', () => cancelled = true);
    String? error;
    void fail(String e) => error = e;
    void check() {
      if (cancelled) throw _Cancelled();
    }

    try {
      // Test mode: only prove the hidden terminal path, touch no plug.
      if (c.testCommand != null) {
        step.value = 'Sending the test command...';
        final sent = await _runOnPeer(peerId, c.testCommand!, check);
        gFFI.dialogManager.dismissByTag(tag);
        if (sent) {
          showToast('Test command sent.');
        } else {
          _message('Power off $name',
              'Could not open a terminal on that PC. Nothing was sent.');
        }
        return;
      }

      step.value = 'Checking the plug...';
      var p = await _plugStatus(c, plug, fail);
      check();
      if (p == null) throw error!;
      if (p['online'] != true) throw 'That plug is offline.';
      if (p['on'] == false) {
        gFFI.dialogManager.dismissByTag(tag);
        showToast('It is already off.');
        return;
      }
      final offMax = (p['offMaxWatts'] as num).toDouble();
      var watts = (p['watts'] as num?)?.toDouble();
      if (watts == null) throw 'Could not read the power use. Not turning off.';

      if (watts > offMax) {
        step.value = 'Shutting down Windows...';
        final sent = await _runOnPeer(peerId, 'shutdown /s /f /t 0', check);
        check();
        if (!sent) {
          throw 'Could not reach that PC to shut it down. The plug was left on.';
        }
        final until = DateTime.now().add(_offWaitLimit);
        while (true) {
          step.value =
              'Waiting for Windows to finish (${watts!.toStringAsFixed(0)} W)...';
          await Future.delayed(_pollEvery);
          check();
          p = await _plugStatus(c, plug, fail);
          check();
          if (p == null) throw error!;
          watts = (p['watts'] as num?)?.toDouble();
          if (watts != null && watts <= offMax) break;
          if (DateTime.now().isAfter(until)) {
            throw 'The PC is still on after 3 minutes. The plug was left on.';
          }
          watts ??= offMax + 1;
        }
      }

      step.value = 'Turning the plug off...';
      final r = await _post(c, '/api/switch', {'plug': plug, 'on': false});
      check();
      if (r['error'] != null) throw r['error'].toString();
      gFFI.dialogManager.dismissByTag(tag);
      showToast('$name is off.', timeout: const Duration(seconds: 5));
    } on _Cancelled {
      // The user closed the dialog. Stop quietly.
    } catch (e) {
      gFFI.dialogManager.dismissByTag(tag);
      _message('Power off $name', e.toString());
    }
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
