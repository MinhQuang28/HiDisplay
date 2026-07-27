import AppKit
import HiDisplayKit
import SwiftUI

/// The on-screen brightness indicator, shown on the display being adjusted.
///
/// macOS draws its own HUD for the built-in panel but nothing at all for an external one, so pressing
/// F1 on a docked monitor changes the brightness with no feedback — you cannot tell whether the key
/// registered, or which display it hit. This fills that gap, and deliberately only for external
/// displays: drawing a second HUD next to the system's own would be worse than drawing none.
///
/// It is a non-activating panel: it must never take focus, never appear in the app switcher, and never
/// interrupt what the user is typing into.
@MainActor
final class BrightnessOSD {

    /// Matches the system HUD's dwell time closely enough to feel native.
    private static let visibleDuration: TimeInterval = 1.2
    private static let size = CGSize(width: 200, height: 200)

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private let model = OSDModel()

    /// Shows the indicator on `display`, or moves it there if already visible.
    func show(value: Float, display: DisplayDevice) {
        model.value = min(max(value, 0), 1)
        model.displayName = display.name

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, on: display)
        panel.orderFrontRegardless()

        // Re-arm rather than stack: holding the key down should keep one indicator alive, not queue a
        // dismissal per press.
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            // `.nonactivatingPanel` is the part that matters: without it, showing the HUD would pull
            // focus away from whatever the user is working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OSDView(model: model))
        return panel
    }

    /// Places the panel bottom-centre of the target display.
    ///
    /// `DisplayDevice.frame` is in CoreGraphics' top-left-origin space while `NSPanel` wants AppKit's
    /// bottom-left-origin space, so converting by hand would be an easy off-by-a-screen-height bug on a
    /// multi-monitor desk. Looking the display up in `NSScreen.screens` avoids the conversion entirely.
    private func position(_ panel: NSPanel, on display: DisplayDevice) {
        let frame = screenFrame(for: display.cgDisplayID) ?? NSScreen.main?.frame ?? .zero
        let origin = CGPoint(
            x: frame.midX - Self.size.width / 2,
            // Roughly where the system HUD sits, so the two never feel like different apps.
            y: frame.minY + 140)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
    }

    private func screenFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }?.frame
    }
}

/// Observable payload, so re-showing updates the existing panel instead of rebuilding it.
@MainActor
private final class OSDModel: ObservableObject {
    @Published var value: Float = 1
    @Published var displayName: String = ""
}

private struct OSDView: View {

    @ObservedObject var model: OSDModel

    /// The system HUD uses sixteen segments; matching it makes a key press land on exactly one segment.
    private static let segments = 16

    private var filledSegments: Int {
        Int((model.value * Float(Self.segments)).rounded())
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(.primary)

            HStack(spacing: 2) {
                ForEach(0..<Self.segments, id: \.self) { index in
                    Rectangle()
                        .fill(index < filledSegments ? Color.primary : Color.primary.opacity(0.22))
                        .frame(height: 8)
                }
            }
            .frame(width: 140)
            .clipShape(RoundedRectangle(cornerRadius: 2))

            // Which display this applies to — the whole point of the HUD when several are attached.
            Text(model.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 160)
        }
        .frame(width: 200, height: 200)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
    }
}

/// The system's HUD material, so the indicator matches the platform rather than approximating it.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
