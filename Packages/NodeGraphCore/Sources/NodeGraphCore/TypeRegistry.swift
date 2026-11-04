import Collections

/// A platform-neutral RGBA color, components in 0...1.
public struct RGBAColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Describes a registered ``PortType``.
public struct PortTypeInfo: Hashable, Sendable, Codable {
    public var type: PortType
    public var displayName: String
    public var color: RGBAColor
    /// Types whose outputs this type's inputs accept as-is, with no conversion (for example
    /// `"number"` accepting `"int"`). Identity and ``PortType/any`` are always accepted.
    public var acceptsFrom: Set<PortType>

    public init(
        type: PortType,
        displayName: String,
        color: RGBAColor,
        acceptsFrom: Set<PortType> = []
    ) {
        self.type = type
        self.displayName = displayName
        self.color = color
        self.acceptsFrom = acceptsFrom
    }
}

/// How an output of one type can feed an input of another.
public enum Connectability: Hashable, Sendable {
    /// Same type, or either side is ``PortType/any``.
    case identical
    /// The input type declares it accepts the output type unchanged.
    case accepted
    /// A conversion from the output type to the input type is registered.
    case converted
    case incompatible

    public var isConnectable: Bool { self != .incompatible }
}

/// Registry of port types, their display info, and compatibility and conversion rules.
///
/// A value type, injected where needed rather than global. Packs mutate it during setup.
public struct TypeRegistry: Hashable, Sendable {
    private var infos: OrderedDictionary<PortType, PortTypeInfo> = [:]
    private var conversions: Set<Conversion> = []

    private struct Conversion: Hashable, Sendable {
        var from: PortType
        var to: PortType
    }

    public init() {}

    /// All registered types in registration order.
    public var registeredTypes: [PortTypeInfo] { Array(infos.values) }

    /// Registers a type, replacing any earlier registration with the same id.
    public mutating func register(_ info: PortTypeInfo) {
        infos[info.type] = info
    }

    /// Declares that outputs of `from` can be converted to inputs of `to`.
    ///
    /// This records only that the connection is allowed. The value conversion itself
    /// is attached once `GraphValue` exists.
    public mutating func registerConversion(from: PortType, to: PortType) {
        conversions.insert(Conversion(from: from, to: to))
    }

    /// Returns the registered info for a type, if any.
    public func info(for type: PortType) -> PortTypeInfo? {
        infos[type]
    }

    /// Whether an output of type `output` may connect to an input of type `input`.
    ///
    /// Unregistered types are compatible only with themselves and ``PortType/any``.
    public func connectability(from output: PortType, to input: PortType) -> Connectability {
        if output == input || output == .any || input == .any {
            return .identical
        }
        if infos[input]?.acceptsFrom.contains(output) == true {
            return .accepted
        }
        if conversions.contains(Conversion(from: output, to: input)) {
            return .converted
        }
        return .incompatible
    }
}
