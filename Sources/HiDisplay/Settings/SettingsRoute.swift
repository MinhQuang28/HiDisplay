import Foundation

/// One entry in the Settings sidebar.
///
/// Held on `AppModel` rather than as view state so that the selected display survives switching
/// between the display page and the HiDPI page, and so a future menu action can open Settings on a
/// particular page. The display case carries the stable profile key, never the `CGDirectDisplayID`,
/// for the same reason `DisplayDevice.id` does: it must still name the same monitor after a replug.
enum SettingsRoute: Hashable {
    case display(String)
    case hiDPI
    case general
    case brightnessKeys
    case diagnostics

    /// Sidebar label for the fixed entries. A display entry is labelled by the display itself.
    var title: String {
        switch self {
        case .display: return "Display"
        case .hiDPI: return "HiDPI Overrides"
        case .general: return "General"
        case .brightnessKeys: return "Brightness Keys"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .display: return "display"
        case .hiDPI: return "rectangle.expand.vertical"
        case .general: return "gearshape"
        case .brightnessKeys: return "keyboard"
        case .diagnostics: return "stethoscope"
        }
    }

    /// The display this route is about, if any.
    var displayID: String? {
        if case .display(let id) = self { return id }
        return nil
    }
}
