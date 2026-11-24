import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../consts.dart';
import '../../models/platform_model.dart';
import '../../utils/multi_window_manager.dart';

// The "New tab" in the remote window shows the stock start page
// (DesktopHomePage with asTab: true). The hidden main window is the only one
// that gets peer lists and online dots from Rust, so it forwards them.
const kComputersTabKey = '__computers__';
const kHomeTabScheme = 'rustdesk-church';
const kHomeTabLink = 'rustdesk-church://home';
const kWindowShowSettings = 'church_show_settings';
const kWindowForwardEvent = 'church_forward_event';

const _forwardedEvents = [
  'load_recent_peers',
  'load_fav_peers',
  'load_lan_peers',
  'callback_query_onlines',
];

/// Main isolate: show the start page as a tab, creating the tab window if
/// there is none yet.
Future<void> openComputersHome() async {
  final r = await rustDeskWinManager.call(WindowType.RemoteDesktop,
      kWindowEventNewRemoteDesktop, jsonEncode({'id': kComputersTabKey}));
  if (r.windowId == kInvalidWindowId) {
    await rustDeskWinManager.newRemoteDesktop(kComputersTabKey);
  }
}

/// Main isolate: pass the peer events Rust sends to main on to tab windows.
void forwardPeerEventsToTabs() {
  for (final name in _forwardedEvents) {
    platformFFI.registerEventHandler(name, 'church-forward', (evt) async {
      try {
        await rustDeskWinManager.callAll(
            WindowType.RemoteDesktop, kWindowForwardEvent, jsonEncode(evt));
      } catch (e) {
        debugPrint('forward $name failed: $e');
      }
    });
  }
}

/// Tab isolate: ask the main window to show Settings.
Future<void> openSettingsFromTab() async {
  await rustDeskWinManager.call(WindowType.Main, kWindowShowSettings, '');
}
