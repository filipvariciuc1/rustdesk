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
- `flutter/pubspec.lock` and `flutter/lib/desktop/pages/port_forward_tab_page.dart` carry
  changes that are not ours: never commit or stash them. Commit by pathspec.
- Push: `git ls-remote fork refs/heads/power-buttons` must equal the parent of the new commit,
  then `git push fork power-buttons` (`pull --rebase` refuses while the tree is dirty).

## Design notes
- No separate start window: the hidden main window opens the remote tab window with a
  "New tab" (`kComputersTabKey`) that is the stock `DesktopHomePage(asTab: true)`.
  `asTab` skips the window method handler, quit listener and uni links (they belong to main).
- Rust sends peer lists and online dots to the main window only; main forwards them to tab
  windows (`forwardPeerEventsToTabs` in `computers_tab.dart`).
- A second launch sends `rustdesk-church://home` to the running app (`main.cpp`).
