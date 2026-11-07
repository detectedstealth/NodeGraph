#if canImport(AppKit)
import AppKit
#endif

/// The only place that reads platform input state. Everything else takes ``InputModifiers``.
enum PlatformInput {
    /// The modifier keys held right now.
    @MainActor static var modifiers: InputModifiers {
        #if canImport(AppKit)
        return modifiers(from: NSEvent.modifierFlags)
        #else
        // Hardware keyboard modifiers on iPadOS arrive with the iPad input work.
        return []
        #endif
    }

    #if canImport(AppKit)
    static func modifiers(from flags: NSEvent.ModifierFlags) -> InputModifiers {
        var result: InputModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
    #endif
}
