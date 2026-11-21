#if !os(tvOS) && !os(watchOS)
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The only place that reads platform input state. Everything else takes ``InputModifiers``.
enum PlatformInput {
    /// The modifier keys held right now.
    @MainActor static var modifiers: InputModifiers {
        #if canImport(AppKit)
        return modifiers(from: NSEvent.modifierFlags)
        #else
        // Touch gestures read the keys from their recognizer instead; see `modifiers(from:)`.
        return []
        #endif
    }

    #if canImport(UIKit)
    static func modifiers(from flags: UIKeyModifierFlags) -> InputModifiers {
        var result: InputModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
    #endif

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
#endif
