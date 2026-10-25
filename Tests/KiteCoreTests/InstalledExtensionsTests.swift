import Foundation
import Testing
@testable import KiteCore

@Suite struct InstalledExtensionsTests {
    let uBlock = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    let darkReader = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    @Test func readsPopupsAndIcons() throws {
        let mv3 = try ExtensionManifest(data: Data(#"""
        {"manifest_version":3,"action":{"default_popup":"popup.html",
         "default_icon":{"16":"img/16.png","32":"img/32.png","64":"img/64.png"}},
         "icons":{"128":"img/128.png"}}
        """#.utf8))
        #expect(mv3.popupPath == "popup.html")
        #expect(mv3.iconPath(forSize: 32) == "img/32.png")
        #expect(mv3.iconPath(forSize: 40) == "img/64.png")
        #expect(mv3.iconPath(forSize: 200) == "img/64.png")

        let mv2 = try ExtensionManifest(data: Data("\u{FEFF}{\"browser_action\":{\"default_popup\":\" \",\"default_icon\":\"i.png\"},\"icons\":{\"48\":\"b.png\"}}".utf8))
        #expect(mv2.popupPath == nil)
        #expect(mv2.iconPath(forSize: 32) == "i.png")

        let noAction = try ExtensionManifest(data: Data(#"{"icons":{"48":"a.png","128":"b.png"}}"#.utf8))
        #expect(noAction.popupPath == nil)
        #expect(noAction.iconPath(forSize: 32) == "a.png")
    }

    @Test func findsExtensionFolders() {
        let prefs = Data(#"""
        {"extensions":{"settings":{
          "ddkjiahejlhfcafbddmgiahcphecmpfh":{"location":8,"path":"/tmp/unpacked/ublock"},
          "eimadpbcbfnmbkopoojfekhnkhdbieeh":{"location":1,"path":"eimadpbcbfnmbkopoojfekhnkhdbieeh/4.9.133_0"},
          "not-an-id":{"path":"/x"},
          "mhjfbmdgcfjbbpaeojofohoefgiehjai":{"location":5}
        }}}
        """#.utf8)
        let base = URL(fileURLWithPath: "/profile/Default/Extensions", isDirectory: true)
        let folders = InstalledExtensions.folders(securePreferences: prefs, extensionsDirectory: base)
        #expect(folders.count == 2)
        #expect(folders[uBlock]?.path == "/tmp/unpacked/ublock")
        #expect(folders[darkReader]?.path == "/profile/Default/Extensions/eimadpbcbfnmbkopoojfekhnkhdbieeh/4.9.133_0")
    }

    @Test func buildsTheList() {
        let management = Data(#"""
        [{"id":"eimadpbcbfnmbkopoojfekhnkhdbieeh","name":"Dark Reader","enabled":false,"type":"extension","mayDisable":true},
         {"id":"ddkjiahejlhfcafbddmgiahcphecmpfh","name":"uBlock Origin Lite","enabled":true,"type":"extension",
          "optionsUrl":"chrome-extension://ddkjiahejlhfcafbddmgiahcphecmpfh/dashboard.html"},
         {"id":"kaoomgmkpckaljldplcclhdahmmjnhlo","name":"Kite","enabled":true,"type":"extension"},
         {"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"A theme","enabled":true,"type":"theme"}]
        """#.utf8)
        let folders = [uBlock: URL(fileURLWithPath: "/u", isDirectory: true)]
        let list = InstalledExtensions.list(managementJSON: management, folders: folders) { url in
            url.path == "/u/manifest.json"
                ? Data(#"{"action":{"default_popup":"/popup.html","default_icon":{"32":"img/32.png"}}}"#.utf8) : nil
        }
        #expect(list.map(\.name) == ["Dark Reader", "uBlock Origin Lite"])
        #expect(list[0].enabled == false)
        #expect(list[0].popupURL == nil)
        #expect(list[1].popupURL?.absoluteString == "chrome-extension://\(uBlock)/popup.html")
        #expect(list[1].iconFile?.path == "/u/img/32.png")
        #expect(list[1].optionsURL?.absoluteString == "chrome-extension://\(uBlock)/dashboard.html")
    }

    #if canImport(CryptoKit)
    @Test func helperIDMatchesItsManifestKey() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/KiteHelperExtension/manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        let key = try #require(Data(base64Encoded: manifest?["key"] as? String ?? ""))
        #expect(ChromeExtensionID.fromPublicKey(key) == KiteHelperExtension.id)
    }
    #endif
}
