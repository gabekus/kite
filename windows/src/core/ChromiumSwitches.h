#pragma once
// Chromium's browser-process switches as Kite gives them (shell/Chromium.cpp,
// KiteApp::OnBeforeCommandLineProcessing): Kite's own defaults, then --chromium-switches'
// entries, with the feature lists merged into what the command line already has (CEF's own).
// `kitecore chromium-switches` prints what this makes of a request.

#include <string>
#include <string_view>
#include <vector>

namespace kite::chromium_switches {

// Chromium's native window occlusion tracker (NativeWindowOcclusionTrackerWin). Off by default
// (docs/windows-native-occlusion.md): in CEF 156 it can't see Kite's pages, which are child
// windows, so it never hides a covered Kite, and it wakes about 1,800 times a second whenever
// any app's window animates anywhere on the desktop. What it did do for Kite, hide the pages on
// lock and display off, Kite's own occlusion does (shell/Occlusion.h, P2).
// --chromium-switches "--enable-features=CalculateNativeWinOcclusion" turns it back on (test
// profiles: the A/B tool, and a check after a CEF update).
inline constexpr std::string_view kNativeOcclusion = "CalculateNativeWinOcclusion";

// The features Kite turns off in Chromium's browser process unless a request turns them on.
std::vector<std::string> DefaultDisabledFeatures();

// A feature list's names, in order: "A,B<Trial,*C:p/v" gives A, B and C. Empty items are left out.
std::vector<std::string> FeatureNames(std::string_view list);

// The switches to append to the browser process's command line, in order, each "name" or
// "name=value" without dashes: `requested`'s (--chromium-switches, already allow-listed) other
// than the feature lists, as given, then enable-features and disable-features, each the
// existing value (`existingEnable`, `existingDisable`: "" for none) with the new names after it,
// none twice. Appending a switch again replaces its value, so these are the whole lists.
// Kite's default-off features go into disable-features unless enable-features has them; a
// feature the request turns on is taken out of disable-features too. So Chromium never gets
// one both on and off (it would read that as off). A list that stays as it was isn't repeated.
std::vector<std::string> BrowserSwitches(const std::vector<std::string>& requested, std::string_view existingEnable,
                                         std::string_view existingDisable);

// What's wrong with a browser process's feature lists as Chromium has them (`enable`,
// `disable`), for `requested`: "" when every default-off feature is off unless the request
// turned it on, and on if it did, and none is both. --smoke-test fails on anything else, so a
// CEF update that turns one of them on itself (BrowserSwitches then leaves it on) is noticed.
std::string FeatureProblem(const std::vector<std::string>& requested, std::string_view enable, std::string_view disable);

}  // namespace kite::chromium_switches
