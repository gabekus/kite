# Kite

Kite is an open-source browser that works like Arc (spaces, pinned tabs, the ⌘T bar,
split view), built on Chromium, with Claude built in. Source: https://github.com/gabekus/kite

## Install

1. Open Terminal, and run `install.sh` from this folder (drag it into the Terminal window
   after typing `bash `):

   ```bash
   bash ~/Downloads/Kite/install.sh
   ```

   It copies Kite.app to Applications (your own `~/Applications` if you're not an
   admin), lets macOS open it, and opens it.
2. In Kite's menu bar, choose **Kite › Allow Claude to Control the Browser**.
3. Say yes when it offers to set things up with Claude. Claude Code starts with Kite's
   setup guide and walks you through the rest: connecting Claude Code and the Claude app,
   importing from Arc, your password manager.

Run the setup again any time:

```bash
/Applications/Kite.app/Contents/Helpers/kite setup
```

Using the Claude app instead of Claude Code? Copy the guide and paste it into a chat:
`/Applications/Kite.app/Contents/Helpers/kite setup --print | pbcopy`.

## Updates

Kite updates itself. It checks for a new version every 8 hours and installs it the next time
you quit Kite; **Kite › Check for Updates…** checks right away. You won't need another
folder like this one.

## If macOS won't open it

This build is signed and notarized by Apple, so macOS should open it like any other
download. If it still refuses (a managed work Mac, or a test build that wasn't notarized),
run `xattr -dr com.apple.quarantine /Applications/Kite.app`, or open it once and then click
**Open Anyway** in System Settings › Privacy & Security. On a managed work Mac, IT may need
to allow it.

## For Claude

If you're Claude reading this folder: the setup guide is `SETUP.md` here (also inside
Kite.app at `Contents/Resources/SETUP.md`). Follow it with the person, one step at a time.
