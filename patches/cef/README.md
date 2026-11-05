# Kite's CEF patches

`scripts/build-cef.sh` applies these to CEF's own source (`chromium/src/cef`) after
checking it out, then regenerates CEF's C API with `tools/version_manager.py`.
Kite builds against a stock CEF too: each patch defines a macro that Kite checks, and
without it Kite does what it did before.

| Patch | Adds | Macro | Without it |
|---|---|---|---|
| `navigation-state.patch` | `CefBrowserHost::GetNavigationState` and `RestoreNavigationState`: a tab's back/forward list with each page's scroll position and form contents, written and read the way Chrome's session restore does (`sessions::ContentSerializedNavigationBuilder`) | `KITE_CEF_NAVIGATION_STATE` | A tab revived after it was put to sleep loads its URL with no back/forward history |

To change a patch: edit `chromium/src/cef` in the build's checkout, then
`git -C chromium/src/cef diff > patches/cef/NAME.patch` (leaving out the files
`version_manager.py` regenerates).
