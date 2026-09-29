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
/// The shape follows the macOS 27 HUD: a wide glass capsule tucked under the menu bar towards the
/// top-right of the display, an outlined sun on the left and a sixteen-segment level bar on the right,
/// drawn in white. The old 200-point square in the lower middle of the screen was the pre-26 HUD, and
/// next to the current system one it read as a different operating system.
///
/// It is a non-activating panel: it must never take focus, never appear in the app switcher, and never
/// interrupt what the user is typing into.
@MainActor
final class BrightnessOSD {

    /// Matches the system HUD's dwell time closely enough to feel native.
    private static let visibleDuration: TimeInterval = 1.2
    /// The system HUD fades rather than vanishing. Appearing is instant, so only the exit is animated.
    private static let fadeDuration: TimeInterval = 0.25
    fileprivate static let width: CGFloat = 300
    fileprivate static let height: CGFloat = 64
    /// Extra height for the caption row, used only when the panel could not sit on its own display.
    private static let captionHeight: CGFloat = 18
    /// Gap between the menu bar and the capsule.
    private static let topInset: CGFloat = 10
    /// Right margin as a share of the display width, so the capsule sits at the same relative spot on
    /// a 24-inch panel and an ultrawide instead of hugging the corner on one and floating on the other.
    private static let rightMarginFraction: CGFloat = 0.10

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
        let landed = position(panel, on: display)
        model.displayName = landed ? nil : display.name
        if !landed { position(panel, on: display) } // re-fit for the caption row

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

    private var currentSize: CGSize {
        CGSize(width: Self.width, height: Self.height + (model.displayName == nil ? 0 : Self.captionHeight))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: currentSize),
            // `.nonactivatingPanel` is the part that matters: without it, showing the HUD would pull
            // focus away from whatever the user is working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow follows the capsule's alpha, not the window rectangle, so it reads as the
        // floating glass slab the system HUD is rather than as a card.
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OSDView(model: model))
        return panel
    }

    /// Places the panel under the menu bar, inset from the right edge by a tenth of the display width.
    ///
    /// `DisplayDevice.frame` is in CoreGraphics' top-left-origin space while `NSPanel` wants AppKit's
    /// bottom-left-origin space, so converting by hand would be an easy off-by-a-screen-height bug on a
    /// multi-monitor desk. Looking the display up in `NSScreen.screens` avoids the conversion entirely,
    /// and `visibleFrame` already excludes the menu bar (and the notch region on a laptop panel).
    /// - Returns: whether the panel actually landed on `display`, rather than on a fallback screen.
    @discardableResult
    private func position(_ panel: NSPanel, on display: DisplayDevice) -> Bool {
        let matched = screen(for: display.cgDisplayID)
        let frame = (matched ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = currentSize
        let origin = CGPoint(
            x: frame.maxX - frame.width * Self.rightMarginFraction - size.width,
            y: frame.maxY - size.height - Self.topInset)
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        return matched != nil
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}

/// Observable payload, so re-showing updates the existing panel instead of rebuilding it.
@MainActor
private final class OSDModel: ObservableObject {
    @Published var value: Float = 1
    /// Set only when the panel could not be placed on the display it describes.
    @Published var displayName: String?
}

/// The capsule: an outlined sun, then a level bar of sixteen segments. Proportions follow the
/// macOS 27 HUD — a wide glass pill, glyph on the left, the segmented bar taking the rest of the row.
private struct OSDView: View {

    @ObservedObject var model: OSDModel

    /// The system HUD's step count: one segment per brightness-key press.
    private static let segments = 16
    private static let barHeight: CGFloat = 5
    private static let segmentGap: CGFloat = 2.5
    /// Flat dashes with softened corners, not pills — the system bar reads as one dotted line.
    private static let segment = RoundedRectangle(cornerRadius: 1.5, style: .continuous)

    /// Sixteen segments, filled left to right. The segment the level falls inside is filled
    /// proportionally, so the quarter steps that ⌥-F1/F2 make are still visible.
    private var bar: some View {
        let level = CGFloat(model.value) * CGFloat(Self.segments)
        return HStack(spacing: Self.segmentGap) {
            ForEach(0..<Self.segments, id: \.self) { index in
                let fill = min(max(level - CGFloat(index), 0), 1)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Self.segment.fill(.white.opacity(0.25))
                        Self.segment.fill(.white).frame(width: geometry.size.width * fill)
                    }
                }
            }
        }
        .frame(height: Self.barHeight)
        // One key press moves the bar one step; the step should glide, not jump, or a held key
        // looks like it is stuttering.
        .animation(.easeOut(duration: 0.12), value: model.value)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 18) {
                Image(systemName: "sun.max")
                    .font(.system(size: 24, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 28)
                bar
            }
            .padding(.horizontal, 24)

            // Normally absent. The HUD appears on the display it is describing, which says which
            // display far better than a caption does; the name is a fallback for the one case
            // where positioning fell through to another screen.
            if let name = model.displayName {
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
            }
        }
        .frame(width: BrightnessOSD.width)
        .frame(minHeight: BrightnessOSD.height)
        // The macOS 27 HUD draws white glyphs on its glass over light and dark desktops alike; the
        // dark glass variant underneath keeps them readable over a white window.
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        .background(GlassBackground())
        .environment(\.colorScheme, .dark)
    }
}

/// Liquid Glass on macOS 26 and later; the HUD material underneath that.
///
/// `glassEffect` adapts to what is behind it and to the desktop appearance, which is how the system
/// HUD behaves now. The fallback keeps the pre-26 convention — dark material regardless of appearance —
/// because that is what those systems' own HUD looks like, and a light capsule next to it would be
/// the odd one out.
private struct GlassBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            VisualEffectBackground()
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
        }
    }
}

/// The system's HUD material, for macOS 15.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        // The pre-26 HUD is dark whatever the desktop appearance.
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
