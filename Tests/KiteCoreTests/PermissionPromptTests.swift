import Foundation
import Testing
@testable import KiteCore

@Suite struct PermissionPromptTests {
    @Test func namesTheSiteByHost() {
        #expect(PermissionPrompt.siteName(for: URL(string: "https://meet.example.com/")) == "meet.example.com")
        #expect(PermissionPrompt.siteName(for: URL(string: "http://127.0.0.1:8123")) == "127.0.0.1:8123")
        #expect(PermissionPrompt.siteName(for: URL(string: "about:blank")) == "this website")
        #expect(PermissionPrompt.siteName(for: nil) == "this website")
    }

    @Test func asksWithArcsSentences() {
        let camera = PermissionPrompt.title(site: "a.com", permissions: [.camera])
        #expect(camera.text == "Allow a.com to access your camera?")
        #expect(camera.text[camera.siteRange] == "a.com")
        #expect(PermissionPrompt.title(site: "a.com", permissions: [.location]).text == "Allow a.com to access your location?")
        #expect(PermissionPrompt.title(site: "a.com", permissions: [.notifications]).text == "Allow a.com to send you notifications?")
        #expect(PermissionPrompt.title(site: "a.com", permissions: [.camera, .microphone]).text
            == "Allow a.com to access your camera and microphone?")
    }

    @Test func joinsSeveralNames() {
        #expect(PermissionPrompt.joinedNames([.microphone]) == "microphone")
        #expect(PermissionPrompt.joinedNames([.camera, .microphone, .location]) == "camera, microphone and location")
    }

    @Test func usesThePermissionsSymbol() {
        #expect(PermissionPrompt.symbol(for: [.location]) == "location.fill")
        #expect(PermissionPrompt.symbol(for: [.camera, .microphone]) == "video.fill")
    }
}
