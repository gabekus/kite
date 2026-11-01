import Foundation
import Testing
@testable import KiteCore

@Suite struct PasswordManagerTests {
    @Test func savedChoiceWins() {
        #expect(PasswordManager.current(saved: "bitwarden", installed: { _ in false }) == .bitwarden)
        #expect(PasswordManager.current(saved: "none", installed: { $0 == .onePassword }) == PasswordManager.none)
    }

    @Test func otherwiseWhatsInstalled() {
        #expect(PasswordManager.current(saved: nil, installed: { $0 == .bitwarden }) == .bitwarden)
        #expect(PasswordManager.current(saved: nil, installed: { _ in true }) == .onePassword)
        #expect(PasswordManager.current(saved: nil, installed: { _ in false }) == .onePassword)
        #expect(PasswordManager.current(saved: "lastpass", installed: { $0 == .bitwarden }) == .bitwarden)
    }

    @Test func extensions() {
        #expect(PasswordManager(extensionID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa") == .onePassword)
        #expect(PasswordManager(extensionID: "nngceckbapebfimnlniiiahkandclblb") == .bitwarden)
        #expect(PasswordManager.bitwarden.popupURL?.absoluteString == "chrome-extension://nngceckbapebfimnlniiiahkandclblb/popup/index.html")
        #expect(PasswordManager.none.extensionID == nil)
        for manager in PasswordManager.allCases {
            if let id = manager.extensionID { #expect(ChromeWebStore.isExtensionID(id)) }
        }
    }
}
