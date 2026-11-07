import Foundation
import NodeGraphCore

/// The control a node row shows. Chosen from a property's kind, or supplied by a pack.
public enum WidgetKind: Hashable, Sendable {
    case toggle
    /// A bounded number you drag across.
    case slider(min: Double, max: Double, step: Double?, isInteger: Bool)
    /// A number without both bounds: drag to scrub, click to type.
    case number(min: Double?, max: Double?, step: Double?, isInteger: Bool)
    case text
    case multilineText
    case combo([PropertyChoice])
    case color
    /// Shown as text, not edited here (vectors, for now).
    case readOnly
    /// A push button. Pressing it calls ``GraphEditorModel/onWidgetAction``.
    case button(action: String)
    /// Drawn by a renderer a pack registers by this name with
    /// ``GraphEditorModel/registerWidgetRenderer(named:_:)``.
    case custom(String)

    /// How many rows of ``NodeLayoutMetrics/widgetRowHeight`` the widget takes.
    public var rowCount: Int {
        if case .multilineText = self { return 3 }
        return 1
    }
}

/// One row in a node's body: a label and a control bound to a property, or to an action.
public struct NodeWidgetSpec: Hashable, Sendable, Identifiable {
    /// The property id, or the action name for a button. Unique within a node.
    public var id: String
    public var title: String
    public var kind: WidgetKind
    /// The property the widget edits; nil for buttons.
    public var property: PropertyID?

    public init(id: String, title: String, kind: WidgetKind, property: PropertyID? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.property = property
    }

    /// A button that calls ``GraphEditorModel/onWidgetAction`` with `action`.
    public static func button(_ title: String, action: String) -> NodeWidgetSpec {
        NodeWidgetSpec(id: "button.\(action)", title: title, kind: .button(action: action))
    }

    /// The widget for a property: a slider for a number with both limits, a toggle for a bool,
    /// and so on. A custom kind has no editor here and draws with its pack's renderer if there
    /// is one.
    public init(_ property: PropertyDefinition) {
        let kind: WidgetKind
        switch property.kind {
        case .bool:
            kind = .toggle
        case .int(let min, let max, let step):
            let (lo, hi, step) = (min.map(Double.init), max.map(Double.init), step.map(Double.init))
            kind = if let lo, let hi { .slider(min: lo, max: hi, step: step, isInteger: true) }
                else { .number(min: lo, max: hi, step: step, isInteger: true) }
        case .double(let min, let max, let step):
            kind = if let min, let max { .slider(min: min, max: max, step: step, isInteger: false) }
                else { .number(min: min, max: max, step: step, isInteger: false) }
        case .string(let multiline):
            kind = multiline ? .multilineText : .text
        case .choice(let choices):
            kind = .combo(choices)
        case .color:
            kind = .color
        case .vector:
            kind = .readOnly
        case .custom(let name):
            kind = .custom(name)
        }
        self.init(id: property.id.rawValue, title: property.displayName, kind: kind, property: property.id)
    }
}

/// Supplies widgets that are not properties, such as buttons, for a pack's nodes.
public protocol NodeWidgetProvider: Sendable {
    /// Extra widgets for `node`, shown after its property widgets.
    func widgets(for node: Node, definition: NodeDefinition) -> [NodeWidgetSpec]
}

// MARK: - Values

extension WidgetKind {
    /// Where `value` sits between a slider's ends, 0...1. Nil if this is not a slider or the
    /// value is not a number.
    public func fraction(of value: GraphValue) -> Double? {
        guard case .slider(let lo, let hi, _, _) = self, let number = value.numberValue, hi > lo else { return nil }
        return ((number - lo) / (hi - lo)).clamped(to: 0...1)
    }

    /// The slider value at `fraction` of the way across, snapped to the step.
    public func sliderValue(atFraction fraction: Double) -> GraphValue? {
        guard case .slider(let lo, let hi, let step, let isInteger) = self else { return nil }
        var number = lo + fraction.clamped(to: 0...1) * (hi - lo)
        if let step, step > 0 { number = Self.tidy(lo + ((number - lo) / step).rounded() * step) }
        return Self.number(number.clamped(to: lo...hi), isInteger: isInteger)
    }

    /// A number widget's value after dragging `distance` points from `start`: about one step per
    /// eight points (one unit if the property has no step, a hundredth for decimals).
    public func scrubbed(from start: GraphValue, by distance: Double) -> GraphValue? {
        guard case .number(let lo, let hi, let step, let isInteger) = self, let from = start.numberValue else { return nil }
        let unit = step ?? (isInteger ? 1 : 0.01)
        var number = from + distance / 8 * unit
        if isInteger || step != nil { number = Self.tidy((number / unit).rounded() * unit) }
        return Self.number(number.clamped(lo: lo, hi: hi), isInteger: isInteger)
    }

    /// The value for text typed into a number or text widget, or nil if it does not parse or
    /// the widget does not take text. Numbers are limited to the property's range.
    public func value(fromText text: String) -> GraphValue? {
        switch self {
        case .text, .multilineText:
            return .string(text)
        case .number(let lo, let hi, _, let isInteger):
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
            if isInteger, number != number.rounded() { return nil }
            return Self.number(number.clamped(lo: lo, hi: hi), isInteger: isInteger)
        case .slider(let lo, let hi, _, let isInteger):
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
            if isInteger, number != number.rounded() { return nil }
            return Self.number(number.clamped(to: lo...hi), isInteger: isInteger)
        default:
            return nil
        }
    }

    /// How a value reads in the node.
    public func display(_ value: GraphValue?) -> String {
        guard let value else { return "" }
        switch (self, value) {
        case (.toggle, .bool(let on)): return on ? "On" : "Off"
        case (.combo(let choices), .string(let current)): return choices.first { $0.value == current }?.label ?? current
        case (_, .int(let v)): return String(v)
        case (_, .double(let v)): return Self.format(v)
        case (_, .string(let s)): return s
        case (_, .bool(let b)): return b ? "true" : "false"
        case (_, .color(let c)): return Self.hex(c)
        case (_, .vector(let v)): return "(" + v.map(Self.format).joined(separator: ", ") + ")"
        case (_, .null): return ""
        default: return "…"
        }
    }

    /// Drops the binary noise a step multiplication leaves (0.1 times 3 is 0.30000000000000004).
    private static func tidy(_ value: Double) -> Double {
        (value * 1e10).rounded() / 1e10
    }

    private static func number(_ value: Double, isInteger: Bool) -> GraphValue {
        isInteger ? .int(Int64(value.rounded())) : .double(value)
    }

    /// Up to three decimals, without trailing zeros.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func hex(_ color: RGBAColor) -> String {
        func byte(_ v: Double) -> Int { Int((v.clamped(to: 0...1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }
}

extension Double {
    func clamped(lo: Double?, hi: Double?) -> Double {
        var result = self
        if let lo { result = Swift.max(result, lo) }
        if let hi { result = Swift.min(result, hi) }
        return result
    }
}
