import HiDisplayKit
import SwiftUI

/// The Settings window: a sidebar of displays and app pages on the left, one page on the right.
///
/// The layout System Settings uses, because the people opening this window already know it. A
/// `NavigationSplitView` with a `.sidebar` list picks up Liquid Glass on macOS 26 when built with
/// Xcode 26 and renders as the classic source list on macOS 15, with no code specific to either.
/// Not a `TabView`: on macOS 26 a `Settings` scene's `TabView` renders as an oversized floating
/// toolbar, which is what the segmented picker this replaces was avoiding.
///
/// Everything here is navigation. The pages live in `Settings/Pages/`, the HiDPI workflow in
/// `HiDPI/`, and the selected display and route on `AppModel` so they outlive the window.
struct SettingsView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            SettingsDetail()
        }
        // There is nothing to collapse the sidebar *to*: the window is the sidebar plus one page.
        .toolbar(removing: .sidebarToggle)
        // Minimums rather than a fixed size: the HiDPI page is content-heavy, and pinning the
        // window's height is what pushed its Install button out of sight in an earlier version.
        .frame(minWidth: 760, idealWidth: 780, minHeight: 560, idealHeight: 600)
    }
}

/// Displays first, then the tools, then the app itself.
struct SettingsSidebar: View {

    @EnvironmentObject private var model: AppModel

    /// Selection writes go through `navigate(to:)` so the selected display follows the route.
    private var route: Binding<SettingsRoute?> {
        Binding(
            get: { model.resolvedSettingsRoute },
            set: { if let route = $0 { model.navigate(to: route) } })
    }

    var body: some View {
        List(selection: route) {
            Section("Displays") {
                if model.displays.isEmpty {
                    Text("No displays detected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.displays) { display in
                        DisplaySidebarRow(display: display)
                            .tag(SettingsRoute.display(display.id))
                    }
                }
            }

            Section("Tools") {
                sidebarLabel(.hiDPI)
            }

            Section("App") {
                sidebarLabel(.general)
                sidebarLabel(.brightnessKeys)
                    .badge(model.brightnessKeysEnabled && !model.isAccessibilityTrusted ? "!" : nil)
                sidebarLabel(.diagnostics)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("HiDisplay \(AppModel.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    private func sidebarLabel(_ route: SettingsRoute) -> some View {
        Label(route.title, systemImage: route.systemImage)
            .tag(route)
    }
}

/// One display in the sidebar: name, kind, and the two things worth a glance — whether it is the main
/// display, and whether something about it needs attention.
struct DisplaySidebarRow: View {

    let display: DisplayDevice
    @EnvironmentObject private var model: AppModel

    /// An unconfirmed identity or a controller warning: both are shown in full on the display's
    /// page, and both are worth a glance from the sidebar so they are not only found by visiting.
    private var needsAttention: Bool {
        model.ambiguousKeys.contains(display.id) || model.brightness.warnings[display.id] != nil
    }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention")
                }
            }
        } icon: {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
        }
        .help(display.name)
    }

    private var subtitle: String {
        var parts = [display.isBuiltIn ? "Built-in" : "External"]
        if display.isMain { parts.append("Main") }
        if !display.isBuiltIn, let kind = model.brightness.controller(for: display.id) {
            parts.append(kind.label)
        }
        return parts.joined(separator: " · ")
    }
}

/// The right-hand pane: one page per route, titled after it.
struct SettingsDetail: View {

    @EnvironmentObject private var model: AppModel

    private var route: SettingsRoute { model.resolvedSettingsRoute }

    var body: some View {
        Group {
            switch route {
            case .display(let id):
                if let display = model.displays.first(where: { $0.id == id }) {
                    DisplayPage(display: display)
                } else {
                    // Transient: `AppModel.reconcileSelection` moves the route on the next display
                    // change, which is the same event that removed this one.
                    ContentUnavailableView(
                        "Display disconnected", systemImage: "display.trianglebadge.exclamationmark")
                }
            case .hiDPI: HiDPIWizard()
            case .general: GeneralPage()
            case .brightnessKeys: BrightnessKeysPage()
            case .diagnostics: DiagnosticsPage()
            }
        }
        .navigationTitle(title)
        .toolbar {
            // Same command as the menu's, for someone whose screen is too dark to read the menu but
            // who already has this window open.
            ToolbarItem {
                Button("Reset Dimming", systemImage: "sun.max") { model.resetDimming() }
                    .help("Clear gamma and overlay dimming on every display")
            }
        }
    }

    private var title: String {
        if let id = route.displayID, let display = model.displays.first(where: { $0.id == id }) {
            return display.name
        }
        return route.title
    }
}
