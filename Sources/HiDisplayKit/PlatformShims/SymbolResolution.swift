import Foundation

/// Looks up a C symbol in a `dlopen` handle and reinterprets it as a Swift function type.
///
/// Every private-API binding in the app goes through this one function, so the set of undocumented
/// symbols the app depends on is exactly the set of call sites here — which is what makes the
/// allowlist check in docs/private-apis.md possible to enforce.
///
/// Returns `nil` on a missing symbol rather than trapping: a macOS release that removes one of these
/// must degrade a feature, not crash the app on launch.
///
/// `T` must be a `@convention(c)` function type matching the symbol's C signature. Nothing here can
/// enforce that — `unsafeBitCast` to a plain Swift function type would compile and then corrupt the
/// call — so every call site declares its typealias with `@convention(c)` explicitly.
func resolveSymbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
}
