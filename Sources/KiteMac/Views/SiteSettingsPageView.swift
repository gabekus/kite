import AppKit
import KiteCore
import SwiftUI

/// One site's settings (kite://site-settings?site=<origin>): what Site Controls' "All Site
/// Settings…" opens in a new tab. Arc opens Chromium's site details page there
/// (`arc://settings/content/siteDetails?site=<URL>`); Kite draws its own, laid out like
/// Chromium's: the site, then a Permissions card with Reset permissions and one row per
/// permission with an Ask (default) / Allow / Block menu. Kite lists the permissions it can read
/// and change (Chromium content settings for camera, microphone, location and notifications);
/// WebKit keeps none, so the page says so.
struct SiteSettingsPageView: View {
    let site: URL?
    /// Reads a permission; nil when this engine keeps no per-site permissions.
    let read: (SitePermission, URL) -> SitePermissionValue?
    let write: (SitePermission, SitePermissionValue, URL) -> Void

    @State private var values: [SitePermission: SitePermissionValue]?

    enum Metrics {
        static let maxWidth: CGFloat = 680
        static let rowHeight: CGFloat = 48
        static let cardRadius: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(InternalPage.siteSettings.title).font(.system(size: 20, weight: .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let site {
                        siteHeader(site)
                        permissions(site)
                    } else {
                        Text("This page isn't about a website.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: Metrics.maxWidth)
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
    }

    private func reload() {
        guard let site, read(.camera, site) != nil else { values = nil; return }
        var read: [SitePermission: SitePermissionValue] = [:]
        for permission in SitePermission.allCases { read[permission] = self.read(permission, site) }
        values = read
    }

    private func set(_ permission: SitePermission, _ value: SitePermissionValue) {
        guard let site else { return }
        write(permission, value, site)
        reload()
    }

    private func siteHeader(_ site: URL) -> some View {
        HStack(spacing: 12) {
            FaviconView(page: site, size: 20)
            Text(SiteControls.origin(of: site) ?? site.absoluteString)
                .font(.system(size: 15, weight: .medium))
                .textSelection(.enabled)
                .accessibilityIdentifier("siteSettingsSite")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func permissions(_ site: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Permissions").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button("Reset permissions") {
                    for permission in SitePermission.allCases { set(permission, .ask) }
                }
                .disabled(values?.values.allSatisfy { $0 == .ask } ?? true)
            }
            .padding(.horizontal, 16)
            .frame(height: Metrics.rowHeight)
            if let values {
                ForEach(SitePermission.allCases, id: \.self) { permission in
                    Divider().padding(.leading, 16)
                    row(permission, values[permission] ?? .ask)
                }
            } else {
                Divider()
                Text("Camera, microphone, location and notification permissions need the Chromium engine.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }

    private func row(_ permission: SitePermission, _ value: SitePermissionValue) -> some View {
        HStack(spacing: 12) {
            Image(systemName: permission.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(permission.title)
            Spacer(minLength: 0)
            Picker(permission.title, selection: Binding(get: { value }, set: { set(permission, $0) })) {
                Text("Ask (default)").tag(SitePermissionValue.ask)
                Text("Allow").tag(SitePermissionValue.allow)
                Text("Block").tag(SitePermissionValue.block)
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.rowHeight)
    }
}
