import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/desktop/pages/port_forward_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:get/get.dart';

class PortForwardTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const PortForwardTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<PortForwardTabPage> createState() => _PortForwardTabPageState(params);
}

class _PortForwardTabPageState extends State<PortForwardTabPage> {
  late final DesktopTabController tabController;
  late final bool isRDP;
  // Seat RDP sessions started here, by tab key (see PortForwardPage.preStartedFfi).
  final Map<String, FFI> _rdpFfis = {};
  // Bumped each time a leftover seat tunnel tab is replaced.
  int _pageGen = 0;

  static const IconData selectedIcon = Icons.forward_sharp;
  static const IconData unselectedIcon = Icons.forward_outlined;

  _PortForwardTabPageState(Map<String, dynamic> params) {
    isRDP = params['isRDP'];
    tabController =
        Get.put(DesktopTabController(tabType: DesktopTabType.portForward));
    tabController.onSelected = (id) {
      WindowController.fromWindowId(windowId())
          .setTitle(getWindowNameWithId(id));
    };
    tabController.onRemoved = (_, id) => onRemoveId(id);
    final String tabKey = params['tabKey'] ?? params['id'];
    final preFfi = _startRdp(tabKey, params);
    tabController.add(TabInfo(
        key: tabKey,
        label: tabKey,
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        page: PortForwardPage(
          key: ValueKey(tabKey),
          id: params['id'],
          tabKey: tabKey,
          password: params['password'],
          loginMethod: params['loginMethod'] ?? '',
          isSharedPassword: params['isSharedPassword'],
          tabController: tabController,
          isRDP: isRDP,
          forceRelay: params['forceRelay'],
          connToken: params['connToken'],
          preStartedFfi: preFfi,
        )));
  }

  /// Starts a seat RDP session right away instead of in PortForwardPage.initState.
  FFI? _startRdp(String tabKey, Map<String, dynamic> p) {
    if (p['isRDP'] != true) return null;
    final ffi = FFI(null);
    ffi.start(p['id'],
        isPortForward: true,
        password: p['password'],
        loginMethod: p['loginMethod'] ?? '',
        isSharedPassword: p['isSharedPassword'],
        forceRelay: p['forceRelay'],
        connToken: p['connToken'],
        isRdp: true);
    Get.put<FFI>(ffi, tag: 'pf_$tabKey');
    _rdpFfis[tabKey] = ffi;
    // Seat tunnel tabs are keyed by seat, not by peer id: when the desktop
    // closes, close this tab by its own key (see FFI.onRdpClosed).
    ffi.onRdpClosed = () {
      if (_rdpFfis[tabKey] != ffi) return; // replaced by a newer tunnel
      if (tabController.state.value.tabs.any((e) => e.key == tabKey)) {
        tabController.closeBy(tabKey);
      }
    };
    return ffi;
  }

  void _closeRdp(String tabKey) {
    final ffi = _rdpFfis.remove(tabKey);
    if (ffi == null) return;
    if (!ffi.closed) ffi.close();
    Get.delete<FFI>(tag: 'pf_$tabKey');
  }

  @override
  void initState() {
    super.initState();

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      debugPrint(
          "[Port Forward] call ${call.method} with args ${call.arguments} from window $fromWindowId");
      // for simplify, just replace connectionId
      if (call.method == kWindowEventNewPortForward) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        final String tabKey = args['tabKey'] ?? id;
        final isRDP = args['isRDP'];
        if (isRDP != true) windowOnTop(windowId());
        if (tabController.state.value.tabs
                .indexWhere((e) => e.key == tabKey) >=
            0) {
          if (isRDP != true || !_rdpFfis.containsKey(tabKey)) {
            debugPrint("port forward $tabKey exists");
            return;
          }
          // Main only asks for a seat tunnel when that seat's desktop is not
          // open, so this tab is a leftover: drop it and start a fresh one.
          // Not closeBy: it closes this window when it is the last tab.
          debugPrint("port forward $tabKey is a leftover, replacing it");
          _closeRdp(tabKey);
          tabController.state.value.tabs.removeWhere((e) => e.key == tabKey);
          tabController.state.refresh();
          _pageGen++;
        }
        final preFfi = _startRdp(tabKey, args);
        tabController.add(TabInfo(
            key: tabKey,
            label: tabKey,
            selectedIcon: selectedIcon,
            unselectedIcon: unselectedIcon,
            page: PortForwardPage(
              // A replaced leftover gets a new key, so its old page state
              // (holding the dead session) is not reused.
              key: ValueKey(_pageGen == 0 ? tabKey : '$tabKey#$_pageGen'),
              id: id,
              tabKey: tabKey,
              password: args['password'],
              loginMethod: args['loginMethod'] ?? '',
              isSharedPassword: args['isSharedPassword'],
              isRDP: isRDP,
              tabController: tabController,
              forceRelay: args['forceRelay'],
              connToken: args['connToken'],
              preStartedFfi: preFfi,
            )));
      } else if (call.method == "onDestroy") {
        for (final k in _rdpFfis.keys.toList()) {
          _closeRdp(k);
        }
        tabController.clear();
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      }
    });
    Future.delayed(Duration.zero, () async {
      await restoreWindowPosition(WindowType.PortForward,
          windowId: windowId());
      if (isRDP == true) {
        WindowController.fromWindowId(windowId()).hide();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final child = Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: DesktopTab(
        controller: tabController,
        onWindowCloseButton: () async {
          tabController.clear();
          return true;
        },
        tail: AddButton(),
        selectedBorderColor: MyTheme.accent,
        labelGetter: DesktopTab.tablabelGetter,
      ),
    );
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(
            context,
            Scaffold(
                backgroundColor: Theme.of(context).colorScheme.background,
                body: child),
          )
        : workaroundWindowBorder(
            context,
            Container(
              decoration: BoxDecoration(
                  border: Border.all(color: MyTheme.color(context).border!)),
              child: child,
            ));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : Obx(
            () => SubWindowDragToResizeArea(
              child: tabWidget,
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: subWindowManagerEnableResizeEdges,
              windowId: stateGlobal.windowId,
            ),
          );
  }

  void onRemoveId(String id) {
    _closeRdp(id);
    if (tabController.state.value.tabs.isEmpty) {
      WindowController.fromWindowId(windowId()).close();
    }
  }

  int windowId() {
    return widget.params["windowId"];
  }
}
