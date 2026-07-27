import Foundation
import HiDisplayKit
import ServiceManagement

/// Launch at login, via `SMAppService`.
///
/// `SMLoginItemSetEnabled` and the old shared-file-list route are both deprecated; `SMAppService` is
/// the supported API from macOS 13, which is this app's deployment target — one of the reasons that
/// target was chosen.
///
/// The subtlety worth knowing: registration can succeed and still not run, because the user is allowed
/// to switch it off in System Settings → General → Login Items. That shows up as `.requiresApproval`,
/// which is **not** an error and must not be reported as one — the app's job is to explain where the
/// switch is, not to insist something went wrong.
enum LoginItem {

    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user has it switched off in System Settings.
        case requiresApproval
        case unavailable(String)

        var isOn: Bool { self == .enabled }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            // Observed cause, on this project's own machine: LaunchServices held *two* records for the
            // same bundle identifier — the copy in /Applications and an older one in the build
            // directory — and `SMAppService` could not decide which bundle it is.
            //
            // The first version of this message blamed the app not being in /Applications, which was
            // simply wrong: it was. Guessing at a cause and stating it as fact is worse than describing
            // the symptom and giving the user something that actually fixes it.
            return .unavailable(
                "macOS could not resolve this app's login item. This usually means more than one copy "
                + "of HiDisplay is registered — for example one in /Applications and another left in a "
                + "build or Downloads folder. Delete the extra copies, then run:\n\n"
                + "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices."
                + "framework/Support/lsregister -f /Applications/HiDisplay.app")
        @unknown default:
            return .unavailable("unknown login item status")
        }
    }

    /// - Returns: the resulting state, so the caller can show approval guidance without re-querying.
    @discardableResult
    static func set(_ enabled: Bool) -> State {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.notice("login item \(enabled ? "registered" : "unregistered", privacy: .public)")
        } catch {
            // A failure here is worth surfacing verbatim: the usual causes (app not in /Applications,
            // signature the system will not accept) are things only the user can fix.
            Log.app.error("login item change failed: \(String(describing: error), privacy: .public)")
            return .unavailable("\(error.localizedDescription)")
        }
        return state
    }
}
