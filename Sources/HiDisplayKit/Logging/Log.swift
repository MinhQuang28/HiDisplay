import OSLog

/// OSLog categories, one per subsystem boundary. Keeping them separate means `log stream
/// --predicate 'category == "ddc.transport"'` shows only the I2C traffic, which is the only
/// practical way to debug a monitor that answers slowly on a user's machine.
///
/// Nothing here may log a serial number, EDID blob, or absolute home path — diagnostics that
/// need those go through `DiagnosticsReport`, which is explicitly consented to and redactable.
public enum Log {
    public static let subsystem = "com.hidisplay.app"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let discovery = Logger(subsystem: subsystem, category: "display.discovery")
    public static let identity = Logger(subsystem: subsystem, category: "display.identity")
    public static let modes = Logger(subsystem: subsystem, category: "display.modes")
    public static let shims = Logger(subsystem: subsystem, category: "platform.shims")
    public static let ddcTransport = Logger(subsystem: subsystem, category: "ddc.transport")
    public static let ddcBrightness = Logger(subsystem: subsystem, category: "ddc.brightness")
    public static let brightness = Logger(subsystem: subsystem, category: "brightness.coordinator")
    public static let gamma = Logger(subsystem: subsystem, category: "brightness.gamma")
    public static let shade = Logger(subsystem: subsystem, category: "brightness.shade")
    public static let hidpiGenerator = Logger(subsystem: subsystem, category: "hidpi.generator")
    public static let hidpiInstaller = Logger(subsystem: subsystem, category: "hidpi.installer")
    public static let profile = Logger(subsystem: subsystem, category: "profile")
    public static let recovery = Logger(subsystem: subsystem, category: "recovery")
}
