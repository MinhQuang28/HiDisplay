import Foundation

/// Where a display stands in the probe → choose → hold cycle, for the UI to show.
///
/// `BrightnessCoordinator.controller(for:)` answers "which controller", and `nil` there used to be
/// rendered as "no brightness control available" — which is also what it says for the two seconds
/// before the first probe runs, and for the whole time a known-DDC monitor is *held* while its
/// firmware finishes booting. Both are the app doing the right thing; neither looked like it. This
/// type is the distinction the menu and Settings need in order to say "checking…" or "waiting for
/// DDC" instead of "unavailable".
public enum BrightnessPhase: Equatable, Sendable {
    /// No probe has completed for this connection yet. The default for a display the coordinator
    /// has not seen, which covers the settle delay before the first probe.
    case probing
    /// Evidence says the monitor speaks DDC but the last probe failed anyway, so no software dimming
    /// has been applied and the saved value is shown. The next settle, wake, or user brightness
    /// action re-probes. See `BrightnessCoordinator.probeAndChoose`.
    case heldForDDC
    /// A controller has been chosen and is live.
    case ready(BrightnessControllerKind)
    /// The probe finished and nothing applies: the built-in panel, or an external display with no
    /// usable controller at all.
    case unavailable
}
