import AppKit
import KiteCore
import UniformTypeIdentifiers

/// Arc's File › Capture… and Capture Full Page (docs/arc-visual-spec.md, "Capture").
/// Capture… dims the focused page and takes the rectangle the user drags, then offers Copy and
/// Save in a popover. Capture Full Page renders the whole page, copies it and offers Save in a toast.
extension BrowserWindowController {
    @objc func capturePage(_ sender: Any?) {
        guard let page = shownPage, let container = page.view.superview else { return NSSound.beep() }
        cancelCapture()
        capturePopover?.close()
        let overlay = CaptureOverlayView(covering: page.view)
        container.addSubview(overlay, positioned: .above, relativeTo: page.view)
        captureOverlay = overlay
        window?.makeFirstResponder(overlay)
        overlay.onCancel = { [weak self] in
            self?.cancelCapture()
            self?.shownPage?.focus()
        }
        overlay.onCapture = { [weak self, weak overlay, weak page] selection in
            guard let self, let overlay, let page else { return }
            let inPage = overlay.convert(selection, to: page.view)
            // Pages take the area from their top-left corner.
            let area = page.view.isFlipped ? inPage
                : NSRect(x: inPage.minX, y: page.view.bounds.height - inPage.maxY, width: inPage.width, height: inPage.height)
            self.cancelCapture()
            page.captureImage(area: area) { [weak self, weak page] data in
                guard let self, let page, let data, let image = NSImage(data: data) else { return NSSound.beep() }
                self.showCapturePreview(image: image, png: data, anchor: inPage, in: page.view)
            }
        }
    }

    @objc func captureFullPage(_ sender: Any?) {
        guard let page = shownPage else { return NSSound.beep() }
        cancelCapture()
        let title = store.state.selectedTab?.title ?? ""
        showToast("Capture in Progress")
        // Arc waits 0.5s (its FullPageCaptureDelay) before rendering the page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak page] in
            page?.captureImage(area: nil) { data in
                guard let self else { return }
                guard let data else { return self.showToast("Failed to Save") }
                let name = Capture.fullPageFilename(title: title, date: Date())
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                do { try data.write(to: file, options: .atomic) } catch { return self.showToast("Failed to Save") }
                Self.copyCapture(png: data, file: file)
                self.showToast("Screenshot Copied to Clipboard", action: ("Save", { [weak self] in
                    self?.saveCapture(name: name) { try FileManager.default.copyItem(at: file, to: $0) }
                }))
            }
        }
    }

    /// Ends Capture… without taking anything.
    func cancelCapture() {
        captureOverlay?.removeFromSuperview()
        captureOverlay = nil
    }

    private func showCapturePreview(image: NSImage, png: Data, anchor: NSRect, in view: NSView) {
        guard view.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = CapturePreviewController(image: image, onCopy: { [weak self, weak popover] in
            popover?.close()
            Self.copyCapture(png: png, file: nil)
            self?.showToast("Copied Image")
        }, onSave: { [weak self, weak popover] in
            popover?.close()
            self?.saveCapture(name: Capture.areaFilename(date: Date())) { try png.write(to: $0, options: .atomic) }
        })
        capturePopover = popover
        // Below the selection; AppKit flips it above when there's no room.
        popover.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    /// Arc's save sheet for a capture: PNG only, titled "Save Capture Image".
    private func saveCapture(name: String, write: @escaping (URL) throws -> Void) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "Save Capture Image"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try? FileManager.default.removeItem(at: url)
                try write(url)
            } catch {
                self?.showToast("Failed to Save")
            }
        }
    }

    /// The image as PNG, plus the file when there is one, so Finder pastes the file. No TIFF:
    /// a full page's would be tens of megabytes.
    private static func copyCapture(png: Data, file: URL?) {
        let pasteboard = capturePasteboard
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        pasteboard.writeObjects([item])
    }

    /// The general pasteboard; a test build (KITE_SUPPORT_PATH) can name its own with
    /// KITE_TEST_PASTEBOARD so trying Capture doesn't replace the user's clipboard.
    static var capturePasteboard: NSPasteboard {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, let name = environment["KITE_TEST_PASTEBOARD"], !name.isEmpty {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        return .general
    }
}
