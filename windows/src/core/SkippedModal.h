#pragma once
// A modal a quiet run skips, and how it answers instead: KiteCore's SkippedModal
// (WindowPresentation.swift). Every one answers as if dismissed (no button's action runs)
// except "Downloads in progress", which quits, cancelling the downloads, so a test Kite never
// blocks a logoff or a scripted close.

namespace kite {

enum class SkippedModal { Alert, OpenOrSavePanel, QuitConfirmation, DownloadsInProgress };

constexpr bool Proceeds(SkippedModal modal) { return modal == SkippedModal::DownloadsInProgress; }

}  // namespace kite
