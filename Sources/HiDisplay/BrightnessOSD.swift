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
    /// The system HUD fades rather than vanishing. Appearing is instant, so only the exit is animated.
    private static let fadeDuration: TimeInterval = 0.25
    private static let size = CGSize(width: 200, height: 200)

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private let model = OSDModel()

    /// Shows the indicator on `display`, or moves it there if already visible.
    func show(value: Float, display: DisplayDevice) {
        model.value = min(max(value, 0), 1)

        let panel = panel ?? makePanel()
        self.panel = panel
        // The name is redundant when the HUD is sitting on the display it describes, which is the whole
        // point of positioning it there — so it is shown only when that failed and the panel landed
        // somewhere else. See `OSDView`.
        model.displayName = position(panel, on: display) ? nil : display.name

        // Cancel any fade still in flight, or a press during the fade-out would leave the panel
        // half-transparent for the rest of its life.
        panel.alphaValue = 1
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
        guard let panel, panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            // Only withdraw if nothing re-showed it mid-fade; `show` resets alpha to 1.
            MainActor.assumeIsolated {
                guard let panel, panel.alphaValue == 0 else { return }
                panel.orderOut(nil)
            }
        }
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
    /// - Returns: whether the panel actually landed on `display`, rather than on a fallback screen.
    @discardableResult
    private func position(_ panel: NSPanel, on display: DisplayDevice) -> Bool {
        let matched = screenFrame(for: display.cgDisplayID)
        let frame = matched ?? NSScreen.main?.frame ?? .zero
        let origin = CGPoint(
            x: frame.midX - Self.size.width / 2,
            // Roughly where the system HUD sits, so the two never feel like different apps.
            y: frame.minY + 140)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
        return matched != nil
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
    /// Set only when the panel could not be placed on the display it describes.
    @Published var displayName: String?
}

/// Laid out against the system HUD's own proportions rather than by eye.
///
/// The numbers below are the ones AppKit's HUD uses: a 200 pt square with an 18 pt continuous corner,
/// the glyph optically centred in the upper portion, and a 16-segment bar 150 pt wide sitting 30 pt off
/// the bottom. Guessing at these is what makes a look-alike read as "almost, but not quite" — the icon
/// being too large and the bar too tall are exactly what gave the first version away.
private struct OSDView: View {

    @ObservedObject var model: OSDModel

    /// Sixteen, so one key press moves exactly one segment — the system uses the same count for the
    /// same reason.
    private static let segments = 16
    private static let segmentWidth: CGFloat = 7
    private static let segmentHeight: CGFloat = 6
    private static let segmentGap: CGFloat = 2.5

    private var filledSegments: Int {
        Int((model.value * Float(Self.segments)).rounded())
    }

    private var indicator: some View {
        HStack(spacing: Self.segmentGap) {
            ForEach(0..<Self.segments, id: \.self) { index in
                // Each segment is rounded on its own. Clipping the row as a whole — the previous
                // approach — rounds only the two outermost corners, which reads as a progress bar
                // rather than the system's row of discrete ticks.
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.white.opacity(index < filledSegments ? 0.95 : 0.25))
                    .frame(width: Self.segmentWidth, height: Self.segmentHeight)
            }
        }
    }

    var body: some View {
        ZStack {
            // Optically centred, not geometrically: the bar below pulls the composition down, so the
            // glyph sits slightly above the midpoint to compensate.
            Image(systemName: "sun.max.fill")
                .font(.system(size: 74, weight: .regular))
                .foregroundStyle(.white)
                .offset(y: -18)

            VStack(spacing: 6) {
                Spacer(minLength: 0)
                indicator

                // Normally absent. The HUD appears on the display it is describing, which says which
                // display far better than a caption does; the name is a fallback for the one case
                // where positioning fell through to another screen.
                if let name = model.displayName {
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 160)
                }
            }
            .padding(.bottom, 30)
        }
        .frame(width: 200, height: 200)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        // A hairline the material does not provide on its own. Without it the panel's edge dissolves
        // into a light wallpaper and the square loses its shape.
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// The system's HUD material, so the indicator matches the platform rather than approximating it.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        // The system HUD is dark whatever the desktop appearance. Inheriting the app's appearance
        // instead gives a pale panel in Light Mode that no other part of macOS looks like.
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
