import AppKit
import KiteCore
import SwiftUI

/// Floats over the top of the page while Claude is driving a tab, with Stop.
struct ClaudeControlBanner: View {
    let automation: AutomationController
    let store: BrowserStore

    var body: some View {
        let controlled = automation.controlledTabs
        let front = store.state.selectedTab?.id
        if !controlled.isEmpty {
            let frontControlled = front.map { controlled[$0] != nil } ?? false
            let latest = controlled.max { $0.value.lastActive < $1.value.lastActive }?.key
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                Text(message(controlled: controlled, frontControlled: frontControlled, latest: latest))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !frontControlled, let latest {
                    Button("Show") { store.mutate { $0.select(tab: latest) } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
                Button {
                    // Stop the tab in front if Claude is on it, otherwise every tab Claude holds.
                    automation.stop(tabs: frontControlled ? [front!] : Set(controlled.keys))
                } label: {
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .help("Take control back from Claude")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .frame(maxWidth: 520)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Claude is controlling the browser")
        }
    }

    private func message(controlled: [UUID: AutomationController.ControlledTab], frontControlled: Bool, latest: UUID?) -> String {
        if frontControlled { return controlled.count == 1 ? "Claude is controlling this tab" : "Claude is controlling this tab and \(controlled.count - 1) more" }
        if controlled.count > 1 { return "Claude is controlling \(controlled.count) tabs" }
        let title = latest.flatMap { store.state.tab($0)?.displayTitle } ?? "a tab"
        return "Claude is controlling “\(title.count > 40 ? title.prefix(39) + "…" : Substring(title))”"
    }
}

extension BrowserWindowController: AutomationHost {
    func automationPage(for tab: BrowserTab) -> WebPage {
        pool.page(for: tab)
    }

    func closeAutomatedTab(_ id: UUID) {
        close(tab: id)
    }

    /// Pins the banner to the top of the page area, above the web view.
    func installAutomationBanner(_ automation: AutomationController) {
        guard let root = window?.contentView else { return }
        let host = NSHostingView(rootView: ClaudeControlBanner(automation: automation, store: store))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: contentFrame.centerXAnchor),
            host.topAnchor.constraint(equalTo: contentFrame.topAnchor, constant: 10),
        ])
    }
}
