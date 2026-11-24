# rustdesk-power (Filip's RustDesk fork, branch `power-buttons`)

## Build (Windows)
- Flutter **3.24.5 only**: `PATH=/c/dev/tools/flutter-rustdesk/bin:$PATH flutter build windows --release`
  from `flutter/`. Dart/C++ only takes ~40 s. Never run `flutter_rust_bridge_codegen`.
- The running fork locks `flutter/build/windows/x64/runner/Release/*`. Before building, rename
  each locked file to `*.old-running` and copy it back (see the loop in git history / handoffs),
  then stop the fork (`Get-Process rustdesk | ? Path -like 'C:\dev\*'`) and relaunch.
- Never kill the stock `C:\Program Files\RustDesk\RustDesk.exe` (service).

## Traps
- Almost every Dart file and `windows/runner/main.cpp` is **CRLF**. Edit with a CRLF-aware tool.
- `flutter/pubspec.lock` carries changes that are not ours: never commit or stash it.
  Commit by pathspec.
- Push: `git ls-remote fork refs/heads/power-buttons` must equal the parent of the new commit,
  then `git push fork power-buttons` (`pull --rebase` refuses while the tree is dirty).

## Design notes
- No separate start window: the hidden main window opens the remote tab window with a
  "New tab" (`kComputersTabKey`) that is the stock `DesktopHomePage(asTab: true)`.
  `asTab` skips the window method handler, quit listener and uni links (they belong to main).
- Rust sends peer lists and online dots to the main window only; main forwards them to tab
  windows (`forwardPeerEventsToTabs` in `computers_tab.dart`).
- A second launch sends `rustdesk-church://home` to the running app (`main.cpp`).

## Seats (NUC) traps
- RDP sessions are keyed per session id in `insert_session` (`src/flutter.rs`), never by peer id: keyed by peer id, a 2nd seat (Casier after Secretar) joined the 1st seat's session and never connected.
- Do not `SetParent` mstsc.exe itself (rejected: connection bar, focus, fullscreen break). Seat tabs use `rdp-view/` (RDP ActiveX host).
- Do not touch Filip's own mstsc windows.
- Do not log off casier/secretar sessions you did not create; never log off NUC session id 1.
- Do not call `Ocx.Disconnect()` in SeatHost (NUC side).
- Do not remove the hidden-tunnel work in `320edf095`; the tab view rides that tunnel.
- Do not name a WinForms method `Handle` (shadows `Control.Handle`).
- Do not reuse `set_rdp_window_title` for rdp-view (it renames the child's windows).
- rdp-view must be an owned popup (`WS_POPUP` + `GWLP_HWNDPARENT`), never a child window: Flutter's swap chain paints over child windows.
- Both seats share NUC peer `190681964`: port-forward tabs (and their `pf_` Get tags) are keyed by seat (`tabKey` = `seat:<id>`), never by peer id, or the second seat is dropped as "port forward exists".
- `rustDeskWinManager` is main-isolate only: a seat double-clicked in a tab window forwards `kWindowConnect` to main, which runs `connect()` there.
