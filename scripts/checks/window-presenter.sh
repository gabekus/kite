#!/bin/zsh
# Fails when KiteMac shows a window, activates Kite, runs a modal or opens another app without WindowPresenter
# (direct makeKeyAndOrderFront, orderFront, NSApp.activate, runModal, an open panel's begin, a level assignment,
# NSWorkspace open, …), which would bring a test-safe run in front of the user's windows. The rules live in
# KiteCore's WindowPresenterGuard; CI runs the same check as WindowPresenterGuardTests.
set -e
repo=${0:A:h:h:h}
cd "$repo"
swift test --filter WindowPresenterGuardTests
