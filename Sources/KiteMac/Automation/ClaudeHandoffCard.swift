import AppKit
import KiteCore
import SwiftUI

/// handoff's card, over the bottom of the page: what Claude needs the user to do here and why it stopped, with
/// Back, Skip, Next and Done. The page itself rings the control to click. The chevron folds the card to a pill ("Claude
/// needs you · 3 steps"). A step on another tab shows nothing here: the sidebar already rings that tab. When the user
/// hands back (the last step ended, or a step's click opened a tab), it says whether Claude is taking over or needs telling.
struct ClaudeHandoffCard: View {
    let automation: AutomationController
    let store: BrowserStore
    /// Opens once the host is in the window, so the card comes in with its transition.
    let gate: HandoffCardGate

    var body: some View {
        let front = store.state.selectedTab?.id
        let waiting = automation.waitingHandoffSteps
        Group {
            // sign_in's own pill owns the bottom of a tab that's signing in.
            if !gate.isOpen {
                EmptyView()
            } else if let front, automation.signIns[front] != nil {
                EmptyView()
            } else if let handback = automation.handback {
                HandbackCard(automation: automation, handback: handback)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !automation.handoffCardCollapsed, let current = automation.cardStep(front: front) {
                HandoffStepCard(automation: automation, handoff: current.handoff, step: current.step,
                                onFront: current.step.tab == nil || current.step.tab == front,
                                others: waiting.count - 1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if Self.pillShows(automation, store: store, front: front) {
                HandoffPill(count: waiting.count, front: automation.cardStep(front: front) != nil) {
                    if automation.cardStep(front: front) != nil {
                        automation.handoffCardCollapsed = false
                    } else {
                        automation.showNextHandoffStep()
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.28, bounce: 0.15), value: gate.isOpen ? automation.cardStep(front: front)?.step.id : nil)
        .animation(.easeInOut(duration: 0.18), value: automation.handoffCardCollapsed)
        .animation(.easeInOut(duration: 0.18), value: automation.handback)
        .animation(.easeInOut(duration: 0.18), value: gate.isOpen)
    }

    /// Whether the card or its pill shows, as `body` decides it.
    @MainActor static func shows(_ automation: AutomationController, store: BrowserStore, front: UUID?) -> Bool {
        if let front, automation.signIns[front] != nil { return false }
        guard automation.handback == nil else { return true }
        return pillShows(automation, store: store, front: front)
    }

    /// The pill shows for a folded card, or for a step the sidebar can't show (one outside the browser, or on a closed
    /// tab). Steps on other open tabs leave the bottom of the page alone.
    @MainActor static func pillShows(_ automation: AutomationController, store: BrowserStore, front: UUID?) -> Bool {
        automation.cardStep(front: front) != nil
            || automation.waitingHandoffSteps.contains { $0.step.tab.map { store.state.tab($0) == nil } ?? true }
    }
}

/// Lets the card in once its host is back in the window: a host attached with the card already showing would
/// skip the card's transition.
@MainActor
@Observable
final class HandoffCardGate {
    var isOpen = false
}

/// One step: why Claude stopped, what to do, and (for a step outside the browser) the command to copy.
private struct HandoffStepCard: View {
    let automation: AutomationController
    let handoff: Handoff
    let step: Handoff.Step
    /// The step belongs on the tab in front (or on no tab), so Show Tab isn't needed.
    let onFront: Bool
    /// Steps waiting besides this one, across every handoff.
    let others: Int
    @State private var copied = false

    private var tabClosed: Bool { automation.stepTabIsClosed(step) }
    private var canReopen: Bool { automation.canReopenStepTab(step) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClaudeMark()
                    .stroke(Color.claude, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 12, height: 12)
                Text("Claude needs you")
                    .font(.system(size: 12, weight: .semibold))
                if let session = handoff.session {
                    Text(session)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text("Step \(step.number) of \(handoff.steps.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Dismiss All Steps") { automation.dismissHandoff(handoff.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                Button {
                    automation.handoffCardCollapsed = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide until you need it")
            }

            // Why Claude stopped: the step's own reason when it has one.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.claude)
                Text(step.why ?? handoff.reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(step.number)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.claude))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4.5 }
                Text(step.instruction)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let command = step.command {
                HStack(alignment: .top, spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .controlSize(.small)
                    .help("Copy the command, then paste it in Terminal")
                }
                Text("Run it in Terminal, then press Done.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if tabClosed {
                HandoffBlockedNote(text: "This step's tab is closed." + (canReopen ? "" : " Press Skip if you no longer need it."))
            } else if !onFront {
                Text("This step is in another tab.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if case .disabled(let why)? = step.blocker {
                HandoffBlockedNote(text: handoff.isBlocked(step)
                    ? Self.disabledText(target: step.targetName, why: why)
                    : "It's turned off for now. It may turn on once you've done the steps before it.")
            } else if step.blocker == .offPage {
                HandoffBlockedNote(text: "This tab is no longer on this step's page.")
            } else if step.locator != nil, step.found == false {
                Text("Kite can't find it on this page yet. Do it by hand, then press Done.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                if tabClosed, canReopen {
                    Button("Reopen Tab") { automation.reopenStepTab(step.id) }
                        .controlSize(.small)
                        .help("Open this step's tab again")
                } else if onFront, step.blocker == .offPage, step.url != nil {
                    Button("Take Me Back") { automation.returnToStepPage(step.id) }
                        .controlSize(.small)
                        .help("Go back to \(step.url.flatMap { URL(string: $0)?.host } ?? "the step's page")")
                } else if !onFront {
                    Button("Show Tab") { automation.showTab(of: step.id) }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                if step.number > 1 {
                    Button("Back") { automation.showPreviousHandoffStep(before: step.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .help("Go back to step \(step.number - 1): it waits for you again, and Claude hears so")
                }
                Button("Skip") { automation.answerHandoff(step.id, .skipped) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .help("Leave this step undone: Claude hears you skipped it")
                if others > 0 {
                    Button("Next") { automation.showNextHandoffStep(after: step.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .help("Go to the next step without finishing this one")
                }
                Button {
                    automation.answerHandoff(step.id, .done)
                } label: {
                    Text("Done").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.claude)
                .controlSize(.small)
                .help("You did it: tell Claude")
            }
        }
        .padding(12)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.claude.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude needs you: \(step.instruction)")
    }

    /// "“Invite members” is turned off on the page, so it can't be clicked yet. The page says “…”." The page's own
    /// words are quoted and cut short: they're the page speaking, not Kite or Claude.
    static func disabledText(target: String?, why: String?) -> String {
        let control = target.map { "“\(short($0, 60))”" } ?? "The control"
        let said = why.map { " The page says “\(short($0, 120))”." }
            ?? " Something it needs may be missing, such as a field to fill in or a box to tick."
        return "\(control) is turned off on the page, so it can't be clicked yet." + said + " If you can't change that, press Skip."
    }

    private static func short(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

/// Back to Claude: the user ended the last step, or a step's click opened a tab. While Claude waits on the handoff it
/// takes over and this goes after a few seconds; otherwise Claude can't be woken, so it offers the words to tell it.
private struct HandbackCard: View {
    let automation: AutomationController
    let handback: HandoffHandback
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClaudeMark()
                    .stroke(Color.claude, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 12, height: 12)
                Text("Back to Claude")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    automation.closeHandback()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if handback.claudeWaiting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.claude)
                }
                Text(handback.message)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !handback.claudeWaiting {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(copied ? "Copied" : "Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(handback.note, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .controlSize(.small)
                    .help("Copy a message for your Claude chat that tells Claude to carry on")
                }
            }
        }
        .padding(12)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.claude.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Back to Claude: \(handback.message)")
    }
}

/// What's in the way of a step, in the card.
private struct HandoffBlockedNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// The folded card, or a step the sidebar can't show: how many steps wait on the user. Clicking brings up the next one.
private struct HandoffPill: View {
    let count: Int
    /// A step waits on the tab in front (the card was folded).
    let front: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ClaudeMark()
                    .stroke(Color.claude, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 11, height: 11)
                Text("Claude needs you")
                    .font(.system(size: 12, weight: .medium))
                Text(count == 1 ? "1 step" : "\(count) steps")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: front ? "chevron.up" : "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.claude.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(front ? "Show what Claude needs here" : "Go to the next thing Claude needs you to do")
        .accessibilityLabel("Claude needs you: \(count) steps")
    }
}

extension BrowserWindowController {
    /// The handoff card, over the bottom centre of the page. It takes clicks only on itself.
    func installClaudeHandoffCard(_ automation: AutomationController) {
        let card = HandoffCardFrame()
        let gate = HandoffCardGate()
        let host = HandoffHostingView(card: card, rootView: ClaudeHandoffCard(automation: automation, store: store, gate: gate)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HandoffCardFrame.space)) } action: { card.rect = $0 }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .coordinateSpace(.named(HandoffCardFrame.space)))
        host.sizingOptions = []
        host.safeAreaRegions = []
        // In the window only while a step waits: an empty host there still re-renders on every store change.
        let container = DetachingContainer(host: host)
        container.passesClicks = true
        container.frame = contentFrame.bounds
        container.autoresizingMask = [.width, .height]
        contentFrame.addSubview(container, positioned: .above, relativeTo: nil)
        watchHandoffCard(container, gate, automation)
    }

    /// Attaches the host, then opens the gate a turn later so the card animates in; on close, the card animates
    /// out before the host leaves.
    private func watchHandoffCard(_ container: DetachingContainer, _ gate: HandoffCardGate, _ automation: AutomationController) {
        let shows = withObservationTracking {
            ClaudeHandoffCard.shows(automation, store: store, front: store.state.selectedTab?.id)
        } onChange: { [weak self, weak container, weak gate, weak automation] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let container, let gate, let automation else { return }
                    self.watchHandoffCard(container, gate, automation)
                }
            }
        }
        if shows {
            container.isHidden = false
            guard !gate.isOpen else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if !container.isHidden { gate.isOpen = true } } }
        } else if !container.isHidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak container, weak gate, weak automation] in
                MainActor.assumeIsolated {
                    guard let self, let container, let gate, let automation,
                          !ClaudeHandoffCard.shows(automation, store: self.store, front: self.store.state.selectedTab?.id) else { return }
                    gate.isOpen = false
                    container.isHidden = true
                }
            }
        }
    }
}

/// Where the card (or its pill) sits in its host, in the host's flipped coordinates.
final class HandoffCardFrame {
    static let space = "handoffHost"
    var rect: CGRect = .zero
}

/// Lets clicks through to the page everywhere except on the card. Unlike `BannerHostingView`, the card's own
/// background and its plain buttons (the chevron, the pill) take clicks too: SwiftUI draws those itself, so
/// they hit-test to the hosting view.
final class HandoffHostingView<Content: View>: NSHostingView<Content> {
    private let card: HandoffCardFrame

    init(card: HandoffCardFrame, rootView: Content) {
        self.card = card
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor @preconcurrency required init(rootView: Content) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self else { return hit }
        return card.rect.contains(convert(point, from: superview)) ? self : nil
    }
}
