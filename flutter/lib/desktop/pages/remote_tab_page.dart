import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/desktop/pages/computers_tab.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/pages/seat_rdp_tab.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/desktop/widgets/material_mod_popup_menu.dart'
    as mod_menu;
import 'package:flutter_hbb/desktop/widgets/popup_menu.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:bot_toast/bot_toast.dart';

import '../../common/widgets/dialog.dart';
import '../../models/platform_model.dart';

class _MenuTheme {
  static const Color blueColor = MyTheme.button;
  // kMinInteractiveDimension
  static const double height = 20.0;
  static const double dividerHeight = 12.0;
}

class ConnectionTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const ConnectionTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<ConnectionTabPage> createState() => _ConnectionTabPageState(params);
}

class _ConnectionTabPageState extends State<ConnectionTabPage> {
  final tabController =
      Get.put(DesktopTabController(tabType: DesktopTabType.remoteScreen));
  final contentKey = UniqueKey();
  static const IconData selectedIcon = Icons.desktop_windows_sharp;
  static const IconData unselectedIcon = Icons.desktop_windows_outlined;

  String? peerId;
  bool _isScreenRectSet = false;
  int? _display;

  var connectionMap = RxList<Widget>.empty(growable: true);

  _ConnectionTabPageState(Map<String, dynamic> params) {
    RemoteCountState.init();
    peerId = params['id'];
    final sessionId = params['session_id'];
    final tabWindowId = params['tab_window_id'];
    final display = params['display'];
    final displays = params['displays'];
    final screenRect = parseParamScreenRect(params);
    _isScreenRectSet = screenRect != null;
    _display = display as int?;
    tryMoveToScreenAndSetFullscreen(screenRect);
    if (peerId != null) {
      if (peerId != kComputersTabKey) ConnectionTypeState.init(peerId!);
      tabController.onSelected = (id) {
        if (isSeatTabKey(id)) {
          WindowController.fromWindowId(params['windowId']).setTitle(
              SeatRdpSession.all[id]?.name ?? getWindowName());
          return;
        }
        if (id == kComputersTabKey) {
          WindowController.fromWindowId(params['windowId'])
              .setTitle(getWindowName());
          return;
        }
        final remotePage = tabController.widget(id);
        if (remotePage is RemotePage) {
          final ffi = remotePage.ffi;
          bind.setCurSessionId(sessionId: ffi.sessionId);
        }
        WindowController.fromWindowId(params['windowId'])
            .setTitle(getWindowNameWithId(id));
        UnreadChatCountState.find(id).value = 0;
      };
      if (peerId == kComputersTabKey) {
        _openComputersTab();
        Future.delayed(Duration.zero, () {
          WindowController.fromWindowId(params['windowId'])
              .setTitle(getWindowName());
        });
      } else {
      tabController.add(TabInfo(
        key: peerId!,
        label: peerId!,
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        onTabCloseButton: () async {
          if (await desktopTryShowTabAuditDialogCloseCancelled(
            id: peerId!,
            tabController: tabController,
          )) {
            return;
          }
          tabController.closeBy(peerId!);
        },
        page: RemotePage(
          key: ValueKey(peerId),
          id: peerId!,
          sessionId: sessionId == null ? null : SessionID(sessionId),
          tabWindowId: tabWindowId,
          display: display,
          displays: displays?.cast<int>(),
          password: params['password'],
          loginMethod: params['loginMethod'] ?? '',
          toolbarState: ToolbarState(),
          tabController: tabController,
          switchUuid: params['switch_uuid'],
          forceRelay: params['forceRelay'],
          isSharedPassword: params['isSharedPassword'],
        ),
      ));
      }
      _update_remote_count();
    }
    tabController.onRemoved = (_, id) => onRemoveId(id);
    rustDeskWinManager.setMethodHandler(_remoteMethodHandler);
  }

  // The stock start page, as a tab. Picking a PC there replaces it.
  void _openComputersTab() {
    FocusManager.instance.primaryFocus?.unfocus();
    tabController.add(TabInfo(
      key: kComputersTabKey,
      label: 'New tab',
      selectedIcon: Icons.home,
      unselectedIcon: Icons.home_outlined,
      onTabCloseButton: () => tabController.closeBy(kComputersTabKey),
      // Same providers the main window's App gives the start page.
      page: MultiProvider(
        key: const ValueKey(kComputersTabKey),
        providers: [
          ChangeNotifierProvider.value(value: gFFI.ffiModel),
          ChangeNotifierProvider.value(value: gFFI.imageModel),
          ChangeNotifierProvider.value(value: gFFI.cursorModel),
          ChangeNotifierProvider.value(value: gFFI.canvasModel),
          ChangeNotifierProvider.value(value: gFFI.peerTabModel),
        ],
        child: const DesktopHomePage(asTab: true),
      ),
    ));
  }

  // Ctrl+T opens the Computers tab only while no remote screen has the keyboard;
  // otherwise it goes to the remote PC as before.
  bool _onCtrlT(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyT) {
      return false;
    }
    final k = HardwareKeyboard.instance;
    if (!k.isControlPressed || k.isAltPressed || k.isShiftPressed) return false;
    final focusCtx = FocusManager.instance.primaryFocus?.context;
    if (focusCtx?.findAncestorWidgetOfExactType<RemotePage>() != null) {
      return false;
    }
    _openComputersTab();
    return true;
  }

  // Clicking the tab bar hands the keyboard back to this PC, so Ctrl+T works.
  Widget _unfocusOnTabBarClick(Widget child) => Listener(
        onPointerDown: (e) {
          if (e.localPosition.dy < kDesktopRemoteTabBarHeight &&
              stateGlobal.fullscreen.isFalse) {
            FocusManager.instance.primaryFocus?.unfocus();
          }
        },
        child: child,
      );

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onCtrlT);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onCtrlT);

    if (!_isScreenRectSet) {
      Future.delayed(Duration.zero, () {
        restoreWindowPosition(
          WindowType.RemoteDesktop,
          windowId: windowId(),
          peerId: tabController.state.value.tabs.isEmpty
              ? null
              : tabController.state.value.tabs[0].key,
          display: _display,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: _unfocusOnTabBarClick(DesktopTab(
        controller: tabController,
        onWindowCloseButton: handleWindowCloseButton,
        tail: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RelativeMouseModeHint(tabController: tabController),
            ActionIcon(
                message: 'New tab (Ctrl+T)',
                icon: IconFont.add,
                onTap: _openComputersTab,
                isClose: false),
          ],
        ),
        selectedBorderColor: MyTheme.accent,
        pageViewBuilder: (pageView) => pageView,
        labelGetter: DesktopTab.tablabelGetter,
        tabBuilder: (key, icon, label, themeConf) => key == kComputersTabKey ||
                isSeatTabKey(key)
            ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [icon, label])
            : Obx(() {
          final connectionType = ConnectionTypeState.find(key);
          if (!connectionType.isValid()) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                label,
              ],
            );
          } else {
            bool secure =
                connectionType.secure.value == ConnectionType.strSecure;
            bool direct =
                connectionType.direct.value == ConnectionType.strDirect;
            String msgConn = getConnectionText(
                secure, direct, connectionType.stream_type.value);
            var msgFingerprint = '${translate('Fingerprint')}:\n';
            var fingerprint = FingerprintState.find(key).value;
            if (fingerprint.isEmpty) {
              fingerprint = 'N/A';
            }
            if (fingerprint.length > 5 * 8) {
              var first = fingerprint.substring(0, 39);
              var second = fingerprint.substring(40);
              msgFingerprint += '$first\n$second';
            } else {
              msgFingerprint += fingerprint;
            }

            final tab = Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                Tooltip(
                  message: '$msgConn\n$msgFingerprint',
                  child: SvgPicture.asset(
                    'assets/${connectionType.secure.value}${connectionType.direct.value}.svg',
                    width: themeConf.iconSize,
                    height: themeConf.iconSize,
                  ).paddingOnly(right: 5),
                ),
                label,
                unreadMessageCountBuilder(UnreadChatCountState.find(key))
                    .marginOnly(left: 4),
              ],
            );

            return Listener(
              onPointerDown: (e) {
                if (e.kind != ui.PointerDeviceKind.mouse) {
                  return;
                }
                final remotePage = tabController.state.value.tabs
                    .firstWhere((tab) => tab.key == key)
                    .page as RemotePage;
                if (remotePage.ffi.ffiModel.pi.isSet.isTrue && e.buttons == 2) {
                  showRightMenu(
                    (CancelFunc cancelFunc) {
                      return _tabMenuBuilder(key, cancelFunc);
                    },
                    target: e.position,
                  );
                }
              },
              child: tab,
            );
          }
        }),
      )),
    );
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(context, child)
        : workaroundWindowBorder(
            context,
            Obx(() => Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: MyTheme.color(context).border!,
                        width: stateGlobal.windowBorderWidth.value),
                  ),
                  child: child,
                )));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : Obx(() => SubWindowDragToResizeArea(
              key: contentKey,
              child: tabWidget,
              // Specially configured for a better resize area and remote control.
              childPadding: kDragToResizeAreaPadding,
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: subWindowManagerEnableResizeEdges,
              windowId: stateGlobal.windowId,
            ));
  }

  // Note: Some dup code to ../widgets/remote_toolbar
  Widget _tabMenuBuilder(String key, CancelFunc cancelFunc) {
    final List<MenuEntryBase<String>> menu = [];
    const EdgeInsets padding = EdgeInsets.only(left: 8.0, right: 5.0);
    final remotePage = tabController.state.value.tabs
        .firstWhere((tab) => tab.key == key)
        .page as RemotePage;
    final ffi = remotePage.ffi;
    final pi = ffi.ffiModel.pi;
    final perms = ffi.ffiModel.permissions;
    final sessionId = ffi.sessionId;
    final toolbarState = remotePage.toolbarState;
    menu.addAll([
      MenuEntryButton<String>(
        childBuilder: (TextStyle? style) => Obx(() => Text(
              translate(
                  toolbarState.hide.isTrue ? 'Show Toolbar' : 'Hide Toolbar'),
              style: style,
            )),
        proc: () {
          toolbarState.switchHide(sessionId);
          cancelFunc();
        },
        padding: padding,
      ),
    ]);

    if (tabController.state.value.tabs.length > 1) {
      final splitAction = MenuEntryButton<String>(
        childBuilder: (TextStyle? style) => Text(
          translate('Move tab to new window'),
          style: style,
        ),
        proc: () async {
          await DesktopMultiWindow.invokeMethod(
              kMainWindowId,
              kWindowEventMoveTabToNewWindow,
              '${windowId()},$key,$sessionId,RemoteDesktop');
          cancelFunc();
        },
        padding: padding,
      );
      menu.insert(1, splitAction);
    }

    if (perms['restart'] != false &&
        (pi.platform == kPeerPlatformLinux ||
            pi.platform == kPeerPlatformWindows ||
            pi.platform == kPeerPlatformMacOS)) {
      menu.add(MenuEntryButton<String>(
        childBuilder: (TextStyle? style) => Text(
          translate('Restart remote device'),
          style: style,
        ),
        proc: () => showRestartRemoteDevice(
            pi, peerId ?? '', sessionId, ffi.dialogManager),
        padding: padding,
        dismissOnClicked: true,
        dismissCallback: cancelFunc,
      ));
    }

    if (perms['keyboard'] != false && !ffi.ffiModel.viewOnly) {
      menu.add(RemoteMenuEntry.insertLock(sessionId, padding,
          dismissFunc: cancelFunc));

      if (pi.platform == kPeerPlatformLinux || pi.sasEnabled) {
        menu.add(RemoteMenuEntry.insertCtrlAltDel(sessionId, padding,
            dismissFunc: cancelFunc));
      }
    }

    menu.addAll([
      MenuEntryDivider<String>(),
      MenuEntryButton<String>(
        childBuilder: (TextStyle? style) => Text(
          translate('Copy Fingerprint'),
          style: style,
        ),
        proc: () => onCopyFingerprint(FingerprintState.find(key).value),
        padding: padding,
        dismissOnClicked: true,
        dismissCallback: cancelFunc,
      ),
      MenuEntryButton<String>(
        childBuilder: (TextStyle? style) => Text(
          translate('Close'),
          style: style,
        ),
        proc: () async {
          if (await desktopTryShowTabAuditDialogCloseCancelled(
            id: key,
            tabController: tabController,
          )) {
            return;
          }
          tabController.closeBy(key);
          cancelFunc();
        },
        padding: padding,
      )
    ]);

    return mod_menu.PopupMenu<String>(
      items: menu
          .map((entry) => entry.build(
              context,
              const MenuConfig(
                commonColor: _MenuTheme.blueColor,
                height: _MenuTheme.height,
                dividerHeight: _MenuTheme.dividerHeight,
              )))
          .expand((i) => i)
          .toList(),
    );
  }

  void onRemoveId(String id) async {
    SeatRdpSession.all[id]?.close();
    if (tabController.state.value.tabs.isEmpty) {
      // Keep calling until the window status is hidden.
      //
      // Workaround for Windows:
      // If you click other buttons and close in msgbox within a very short period of time, the close may fail.
      // `await WindowController.fromWindowId(windowId()).close();`.
      Future<void> loopCloseWindow() async {
        int c = 0;
        final windowController = WindowController.fromWindowId(windowId());
        while (c < 20 &&
            tabController.state.value.tabs.isEmpty &&
            (!await windowController.isHidden())) {
          await windowController.close();
          await Future.delayed(Duration(milliseconds: 100));
          c++;
        }
      }

      loopCloseWindow();
    }
    ConnectionTypeState.delete(id);
    // Clean up relative mouse mode state for this peer.
    stateGlobal.relativeMouseModeState.remove(id);
    _update_remote_count();
  }

  int windowId() {
    return widget.params["windowId"];
  }

  // A seat card (Casier / Secretar): its Remote Desktop, in a tab.
  Future<String> _openSeatTab(Map<String, dynamic> args) async {
    final String key = args['key'];
    final String name = args['name'];
    final port = await SeatRdpSession.open(key, name,
        windowId: windowId(),
        selected: () => tabController.state.value.selectedTabInfo.key == key,
        ended: () => tabController.closeBy(key));
    if (!tabController.jumpToByKey(key)) {
      tabController.add(TabInfo(
        key: key,
        label: name,
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        onTabCloseButton: () => tabController.closeBy(key),
        page: SeatRdpView(
            key: ValueKey(key), session: SeatRdpSession.all[key]!),
      ));
      // Same as a picked PC: the seat replaces the New tab it came from.
      Future.delayed(const Duration(milliseconds: 400), () {
        final keys = tabController.state.value.tabs.map((t) => t.key);
        if (keys.contains(kComputersTabKey) && keys.contains(key)) {
          tabController.closeBy(kComputersTabKey);
        }
      });
    }
    _update_remote_count();
    windowOnTop(windowId());
    return port;
  }

  Future<bool> handleWindowCloseButton() async {
    final connLength = tabController.length;
    if (connLength == 1) {
      if (await desktopTryShowTabAuditDialogCloseCancelled(
        id: tabController.state.value.tabs[0].key,
        tabController: tabController,
      )) {
        return false;
      }
    }
    if (connLength <= 1) {
      tabController.clear();
      return true;
    } else {
      final bool res;
      if (!option2bool(kOptionEnableConfirmClosingTabs,
          bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs))) {
        res = true;
      } else {
        res = await closeConfirmDialog();
      }
      if (res) {
        tabController.clear();
      }
      return res;
    }
  }

  _update_remote_count() =>
      RemoteCountState.find().value = tabController.length;

  Future<dynamic> _remoteMethodHandler(call, fromWindowId) async {
    debugPrint(
        "[Remote Page] call ${call.method} with args ${call.arguments} from window $fromWindowId");

    dynamic returnValue;
    // for simplify, just replace connectionId
    if (call.method == kWindowEventNewRemoteDesktop) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      if (id == kComputersTabKey) {
        _openComputersTab();
        _update_remote_count();
        windowOnTop(windowId());
        return null;
      }
      final switchUuid = args['switch_uuid'];
      final sessionId = args['session_id'];
      final tabWindowId = args['tab_window_id'];
      final display = args['display'];
      final displays = args['displays'];
      final screenRect = parseParamScreenRect(args);
      final prePeerCount = tabController.length;
      Future.delayed(Duration.zero, () async {
        if (stateGlobal.fullscreen.isTrue) {
          await WindowController.fromWindowId(windowId()).setFullscreen(false);
          stateGlobal.setFullscreen(false, procWnd: false);
        }
        await setNewConnectWindowFrame(windowId(), id!, prePeerCount,
            WindowType.RemoteDesktop, display, screenRect);
        Future.delayed(Duration(milliseconds: isWindows ? 100 : 0), () async {
          await windowOnTop(windowId());
        });
      });
      ConnectionTypeState.init(id);
      tabController.add(TabInfo(
        key: id,
        label: id,
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        onTabCloseButton: () async {
          if (await desktopTryShowTabAuditDialogCloseCancelled(
            id: id,
            tabController: tabController,
          )) {
            return;
          }
          tabController.closeBy(id);
        },
        page: RemotePage(
          key: ValueKey(id),
          id: id,
          sessionId: sessionId == null ? null : SessionID(sessionId),
          tabWindowId: tabWindowId,
          display: display,
          displays: displays?.cast<int>(),
          password: args['password'],
          loginMethod: args['loginMethod'] ?? '',
          toolbarState: ToolbarState(),
          tabController: tabController,
          switchUuid: switchUuid,
          forceRelay: args['forceRelay'],
          isSharedPassword: args['isSharedPassword'],
        ),
      ));
      // Browser-like: the new tab becomes the PC that was picked. Wait until
      // the page view has built the PC page: DesktopTab reuses its cached page
      // list when the tab count looks unchanged, so add+close in one frame
      // left the start page showing and the PC page never started.
      Future.delayed(const Duration(milliseconds: 400), () {
        final keys = tabController.state.value.tabs.map((t) => t.key);
        if (keys.contains(kComputersTabKey) && keys.contains(id)) {
          tabController.closeBy(kComputersTabKey);
        }
      });
    } else if (call.method == kWindowOpenSeatTab) {
      return await _openSeatTab(jsonDecode(call.arguments));
    } else if (call.method == kWindowDisableGrabKeyboard) {
      // ???
    } else if (call.method == "onDestroy") {
      tabController.clear();
    } else if (call.method == kWindowActionRebuild) {
      reloadCurrentWindow();
    } else if (call.method == kWindowEventActiveSession) {
      final jumpOk = tabController.jumpToByKey(call.arguments);
      if (jumpOk) {
        windowOnTop(windowId());
      }
      return jumpOk;
    } else if (call.method == kWindowEventActiveDisplaySession) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      final display = args['display'];
      final jumpOk = tabController.jumpToByKeyAndDisplay(id, display);
      if (jumpOk) {
        windowOnTop(windowId());
      }
      return jumpOk;
    } else if (call.method == kWindowForwardEvent) {
      await platformFFI.tryHandle(
          Map<String, dynamic>.from(jsonDecode(call.arguments)));
    } else if (call.method == kWindowEventGetRemoteList) {
      return tabController.state.value.tabs
          .where((e) => e.key != kComputersTabKey)
          .map((e) => e.key)
          .toList()
          .join(',');
    } else if (call.method == kWindowEventGetSessionIdList) {
      return tabController.state.value.tabs
          .where((e) => e.page is RemotePage)
          .map((e) => '${e.key},${(e.page as RemotePage).ffi.sessionId}')
          .toList()
          .join(';');
    } else if (call.method == kWindowEventGetCachedSessionData) {
      // Ready to show new window and close old tab.
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      final close = args['close'];
      RemotePage? remotePage;
      try {
        remotePage = tabController.state.value.tabs
            .firstWhere((tab) => tab.key == id)
            .page as RemotePage;
        returnValue = remotePage.ffi.ffiModel.cachedPeerData.toString();
      } catch (e) {
        debugPrint('Failed to get cached session data: $e');
      }
      if (close && returnValue != null && remotePage != null) {
        remotePage.releaseMacOSInputForTabTransfer();
        closeSessionOnDispose[id] = false;
        tabController.closeBy(id);
      }
    } else if (call.method == kWindowEventRemoteWindowCoords &&
        tabController.state.value.selectedTabInfo.page is RemotePage) {
      final remotePage =
          tabController.state.value.selectedTabInfo.page as RemotePage;
      final ffi = remotePage.ffi;
      final displayRect = ffi.ffiModel.displaysRect();
      if (displayRect != null) {
        final wc = WindowController.fromWindowId(windowId());
        Rect? frame;
        try {
          frame = await wc.getFrame();
        } catch (e) {
          debugPrint(
              "Failed to get frame of window $windowId, it may be hidden");
        }
        if (frame != null) {
          ffi.cursorModel.moveLocal(0, 0);
          final coords = RemoteWindowCoords(
              frame,
              CanvasCoords.fromCanvasModel(ffi.canvasModel),
              CursorCoords.fromCursorModel(ffi.cursorModel),
              displayRect);
          returnValue = jsonEncode(coords.toJson());
        }
      }
    } else if (call.method == kWindowEventSetFullscreen) {
      stateGlobal.setFullscreen(call.arguments == 'true');
    }
    _update_remote_count();
    return returnValue;
  }
}

/// A widget that displays a hint in the tab bar when relative mouse mode is active.
/// This helps users remember how to exit relative mouse mode.
class _RelativeMouseModeHint extends StatelessWidget {
  final DesktopTabController tabController;

  const _RelativeMouseModeHint({Key? key, required this.tabController})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Check if there are any tabs
      if (tabController.state.value.tabs.isEmpty) {
        return const SizedBox.shrink();
      }

      // Get current selected tab's RemotePage
      final selectedTabInfo = tabController.state.value.selectedTabInfo;
      if (selectedTabInfo.page is! RemotePage) {
        return const SizedBox.shrink();
      }

      final remotePage = selectedTabInfo.page as RemotePage;
      final String peerId = remotePage.id;

      // Use global state to check relative mouse mode (synced from InputModel).
      // This avoids timing issues with FFI registration.
      final isRelativeMouseMode =
          stateGlobal.relativeMouseModeState[peerId] ?? false;

      if (!isRelativeMouseMode) {
        return const SizedBox.shrink();
      }

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.2),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.orange.withOpacity(0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mouse,
              size: 14,
              color: Colors.orange[700],
            ),
            const SizedBox(width: 4),
            Text(
              translate(
                  'rel-mouse-exit-{${isMacOS ? "Cmd+G" : "Ctrl+Alt"}}-tip'),
              style: TextStyle(
                fontSize: 11,
                color: Colors.orange[700],
              ),
            ),
          ],
        ),
      );
    });
  }
}
