import Foundation
import Testing
@testable import KiteCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

struct PageFocusScriptTests {
    /// Whether `source` parses as JavaScript (always true where JavaScriptCore isn't available).
    private func parses(_ source: String) -> Bool {
        #if canImport(JavaScriptCore)
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(context, script, nil, 1, nil)
        #else
        return true
        #endif
    }

    @Test func bothScriptsParseAndShareTheTextFieldCheck() {
        #expect(parses(PageFocusScript.editingFocus))
        #expect(parses(PageFocusScript.jumpToSelection))
        #expect(PageFocusScript.editingFocus.contains(PageFocusScript.isTextField))
        #expect(PageFocusScript.jumpToSelection.contains(PageFocusScript.isTextField))
    }

    @Test func jumpCentresTheRangeNotItsElement() {
        let script = PageFocusScript.jumpToSelection
        #expect(script.contains("range.getClientRects()"))
        #expect(script.contains("isContentEditable"))
        #expect(!script.contains("[contenteditable]"))
        #expect(!script.contains("block: 'center'"))
    }
}
