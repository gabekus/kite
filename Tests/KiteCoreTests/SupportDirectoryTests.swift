import Foundation
import Testing
@testable import KiteCore

@Suite struct SupportDirectoryTests {
    let fallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kite-default", isDirectory: true)

    @Test func usesThePlatformDefaultWithoutAnOverride() throws {
        #expect(try SupportDirectory.resolve(environment: [:], platformDefault: fallback) == fallback)
        #expect(try SupportDirectory.resolve(environment: ["KITE_SUPPORT_PATH": ""], platformDefault: fallback) == fallback)
    }

    @Test func usesAnOverrideThatIsADirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = try SupportDirectory.resolve(environment: ["KITE_SUPPORT_PATH": dir.path], platformDefault: fallback)
        #expect(resolved.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func refusesAnOverrideThatIsAFileOrMissing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: SupportDirectory.Failure.overrideIsNotADirectory(file.path)) {
            try SupportDirectory.resolve(environment: ["KITE_SUPPORT_PATH": file.path], platformDefault: fallback)
        }
        let missing = file.path + "-missing"
        #expect(throws: SupportDirectory.Failure.overrideIsNotADirectory(missing)) {
            try SupportDirectory.resolve(environment: ["KITE_SUPPORT_PATH": missing], platformDefault: fallback)
        }
    }

    @Test func windowsDefaultIsUnderLocalAppData() {
        #expect(SupportDirectory.windowsDefault(environment: [:]) == nil)
        let url = SupportDirectory.windowsDefault(environment: ["LOCALAPPDATA": "/Users/x/AppData/Local"])
        #expect(url?.lastPathComponent == "Kite")
        #expect(url?.deletingLastPathComponent().lastPathComponent == "Local")
    }
}
