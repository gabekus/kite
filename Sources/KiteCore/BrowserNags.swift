import Foundation

/// Kite's own filter list: hides prompts to switch browsers ("Switch to Chrome",
/// "Get Microsoft Edge", "Download Opera") on the sites that show them.
///
/// Unlike the downloaded lists it's written for Kite (MIT, like the rest of the
/// repo), so it ships in the app. It's part of the main engine and also has a
/// tiny engine of its own, so the nags stay hidden where the ad blocker is off.
///
/// Every rule names the sites it applies to: a generic rule could hide real
/// content, such as a page about browsers. Rules hide the nag; none block scripts.
public enum BrowserNags {
    public static let id = "kite-browser-nags"
    public static let name = "Kite browser nags"

    /// Trusted, so it may use uBO's procedural filters (`:has-text()`, `:upward()`).
    public static let trusted = true

    public static let list = #"""
        [Adblock Plus 2.0]
        ! Title: Kite browser nags
        ! Description: Hides prompts to switch browsers on the sites that show them. Every rule is scoped to its site.
        ! License: MIT
        ! Homepage: https://github.com/gabekus/kite

        ! Opera add-ons covers the catalogue with a "Download Opera browser" overlay,
        ! and puts "made for the Opera browser" boxes on the catalogue and extension pages.
        ! Removed rather than hidden: the site's CSP blocks injected style sheets, and its
        ! script shows the overlay again after an inline hide.
        addons.opera.com#?##overlay-content .get-opera-link:upward(#overlay):remove()
        addons.opera.com##.get-opera:remove()
        ! Opera forums: a "Download Opera" banner above the categories.
        forums.opera.com###download-opera

        ! Edge Add-ons: "To install add-ons, you'll need the new Microsoft Edge" across the top.
        microsoftedge.microsoft.com#?##banner > [role="banner"] a[href*="microsoft.com/"][href*="/edge"]:upward([role="banner"])

        ! Bing, Microsoft 365, Outlook, Copilot and MSN: dialogs and flyouts asking to switch to Edge.
        ! Not www.microsoft.com, where Edge's own download dialog says the same thing.
        bing.com,office.com,live.com,cloud.microsoft,copilot.microsoft.com,copilot.com,msn.com#?#[role="dialog"]:has-text(/(switch to|try|get|download|use) (the new )?microsoft edge/i)
        bing.com#?##bnp_container:has-text(/microsoft edge/i)

        ! Google: "Switch to Chrome" and "Try Chrome" bubbles and sheets on Search and in the apps' account bar.
        www.google.*,mail.google.com,drive.google.com,docs.google.com,meet.google.com,calendar.google.com,photos.google.com,maps.google.com,news.google.com,translate.google.com,accounts.google.com,www.youtube.com#?#[role="dialog"]:has-text(/(switch to|try|download) (google )?chrome|chrome is the browser|browser (built|made) by google/i)
        www.google.*,mail.google.com,drive.google.com,docs.google.com,meet.google.com,calendar.google.com,photos.google.com,maps.google.com,news.google.com,translate.google.com,accounts.google.com,www.youtube.com##[role="dialog"][aria-label*="Google Chrome"]
        www.google.*#?#g-bottom-sheet:has-text(/(switch to|try|download) (google )?chrome/i)

        ! Brave Search: a "Brave Browser … Download" card under the search box.
        search.brave.com##.ntp .download-cta

        """#

    /// The list's rules: lines that aren't blank, comments or the header.
    public static var rules: [String] {
        list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[") }
    }

    /// The sites a cosmetic rule applies to (`a.com,b.com##…` gives both), or nil
    /// for a rule that isn't cosmetic.
    public static func domains(of rule: String) -> [String]? {
        for separator in ["#?#", "#$#", "#@#", "##"] {
            if let range = rule.range(of: separator) {
                return rule[..<range.lowerBound].split(separator: ",").map(String.init)
            }
        }
        return nil
    }

    /// Changes whenever the list's text does, so an engine cached with an older
    /// copy of it is rebuilt. FNV-1a, since `hashValue` differs between launches.
    public static let fingerprint: String = {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in list.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }()

    /// The lists an engine is built from: the downloaded ones, then this one.
    public static func withBuiltIn(_ downloaded: [(text: Data, trusted: Bool)]) -> [(text: Data, trusted: Bool)] {
        downloaded + [(Data(list.utf8), trusted)]
    }
}
