import AppKit
import KiteCore

/// Edit › Undo (⌘Z) and Redo (⇧⌘Z), Arc's way: they undo the sidebar (SidebarUndo, Undo Archive
/// Tab, Undo Close Peek, Undo Tidy Tabs…) unless the keyboard is in something that undoes its own
/// typing. A text field in Kite's chrome (the command bar, a rename, Find) undoes its typing as
/// usual. A web page undoes its own typing when a text field or editable area has focus there,
/// and otherwise hands ⌘Z to the sidebar: Chromium's page view answers `undo:` itself, so without
/// this a page with focus would swallow every sidebar undo.
extension BrowserWindowController {
    /// What a page reports about its focus: whether ⌘Z there would undo the page's own editing.
    /// A focused frame Kite can't look into (another site's iframe) counts as editing, so typing
    /// there is never lost to a sidebar undo.
    static let pageEditingFocusScript = """
    (() => {
      const editing = (doc) => {
        if (!doc) return true;
        if (doc.designMode === 'on') return true;
        let e = doc.activeElement;
        while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
        if (!e || e === doc.body || e === doc.documentElement) return false;
        if (e.isContentEditable) return true;
        const tag = e.tagName;
        if (tag === 'IFRAME' || tag === 'FRAME') {
          let inner = null;
          try { inner = e.contentDocument; } catch (_) {}
          return editing(inner);
        }
        if (e.disabled || e.readOnly) return false;
        if (tag === 'TEXTAREA') return true;
        if (tag === 'INPUT') {
          const type = (e.getAttribute('type') || 'text').toLowerCase();
          return ['text', 'search', 'url', 'tel', 'email', 'password', 'number', 'date', 'datetime-local',
                  'month', 'time', 'week'].includes(type);
        }
        return false;
      };
      return editing(document);
    })()
    """

    /// The page that has the keyboard (a tab's, a split pane's or a Peek's), with the view inside
    /// it that's first responder; nil when the keyboard is anywhere else.
    var pageWithKeyboard: (page: WebPage, responder: NSResponder)? {
        guard let window, let responder = window.firstResponder, let view = responder as? NSView,
              !(responder is NSText) else { return nil }
        for page in visiblePages + [linkPeek?.page].compactMap({ $0 }) where view.isDescendant(of: page.view) {
            return (page, responder)
        }
        return nil
    }

    /// Edit › Undo or Redo with a page holding the keyboard. The page says whether it's editing;
    /// if it is, or the sidebar has nothing to undo, the page gets the command, as it would without Kite.
    func undoWithPageFocused(redo: Bool, sender: Any?) {
        guard let (page, responder) = pageWithKeyboard else { return }
        let action = redo ? Self.redoAction : Self.undoAction
        page.evaluateJavaScript(Self.pageEditingFocusScript) { [weak self, weak responder] result in
            guard let self else { return }
            let editing = (result as? Bool) ?? (result as? NSNumber)?.boolValue ?? true
            let manager = self.window?.undoManager
            if !editing, let manager, redo ? manager.canRedo : manager.canUndo {
                redo ? manager.redo() : manager.undo()
            } else if let responder, responder.responds(to: action) {
                NSApp.sendAction(action, to: responder, from: sender)
            }
        }
    }

    /// The Undo or Redo item's title and state with a page holding the keyboard: the sidebar's step
    /// when there is one ("Undo Archive Tab"), else plain "Undo", left on so the page can take it.
    func validateUndoWithPageFocused(_ item: NSMenuItem, redo: Bool) -> Bool {
        let manager = window?.undoManager
        if let manager, redo ? manager.canRedo : manager.canUndo {
            item.title = redo ? manager.redoMenuItemTitle : manager.undoMenuItemTitle
        } else {
            item.title = redo ? "Redo" : "Undo"
        }
        return true
    }

    static let undoAction = Selector(("undo:"))
    static let redoAction = Selector(("redo:"))
}

/// The Edit menu's Undo and Redo items target the MenuRouter, which sends them on here.
extension MenuRouter {
    @objc func routeUndo(_ sender: Any?) { route(redo: false, sender) }
    @objc func routeRedo(_ sender: Any?) { route(redo: true, sender) }

    /// The window Undo and Redo act on: the browser window `ui input` is delivering to, else the key window.
    private var undoWindow: NSWindow? {
        Self.deliveringTo?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    /// A browser window with a page holding the keyboard, when that's where Undo goes.
    private var browserWithPageFocus: BrowserWindowController? {
        guard let controller = undoWindow?.windowController as? BrowserWindowController,
              controller.pageWithKeyboard != nil else { return nil }
        return controller
    }

    private func route(redo: Bool, _ sender: Any?) {
        if let controller = browserWithPageFocus { return controller.undoWithPageFocused(redo: redo, sender: sender) }
        guard let target = undoTarget(redo: redo) else { return NSSound.beep() }
        NSApp.sendAction(redo ? BrowserWindowController.redoAction : BrowserWindowController.undoAction, to: target, from: sender)
    }

    /// Who answers `undo:` / `redo:` everywhere else, as AppKit's own responder chain would pick:
    /// a text view's own undo, or the window (its undo manager: the sidebar's steps and typing).
    private func undoTarget(redo: Bool) -> NSResponder? {
        let action = redo ? BrowserWindowController.redoAction : BrowserWindowController.undoAction
        var responder = undoWindow?.firstResponder
        while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
        return responder
    }

    /// Validates Undo and Redo; true when it took the item.
    func validateUndoItem(_ item: NSMenuItem) -> Bool? {
        let redo: Bool
        switch item.action {
        case #selector(routeUndo(_:)): redo = false
        case #selector(routeRedo(_:)): redo = true
        default: return nil
        }
        if let controller = browserWithPageFocus { return controller.validateUndoWithPageFocused(item, redo: redo) }
        guard let target = undoTarget(redo: redo) else {
            item.title = redo ? "Redo" : "Undo"
            return false
        }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }
}
