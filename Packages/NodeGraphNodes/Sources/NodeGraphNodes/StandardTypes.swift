import NodeGraphCore

extension PortType {
    /// A floating-point number. Ports of this type carry `GraphValue.double`; nodes also accept
    /// `.int` on input.
    public static let number: PortType = "number"
    public static let bool: PortType = "bool"
    public static let string: PortType = "string"
    /// An ordered list of values: `GraphValue.array`.
    public static let array: PortType = "array"
    /// Named values: `GraphValue.object`.
    public static let object: PortType = "object"
}

/// The port types the built-in packs use.
public enum StandardTypes {
    /// Registers `number`, `bool`, `string`, `array` and `object`.
    public static func register(in types: inout TypeRegistry) {
        types.register(PortTypeInfo(
            type: .number, displayName: "Number", color: RGBAColor(red: 0.35, green: 0.62, blue: 0.95)))
        types.register(PortTypeInfo(
            type: .bool, displayName: "Boolean", color: RGBAColor(red: 0.90, green: 0.40, blue: 0.40)))
        types.register(PortTypeInfo(
            type: .string, displayName: "String", color: RGBAColor(red: 0.45, green: 0.78, blue: 0.50)))
        types.register(PortTypeInfo(
            type: .array, displayName: "Array", color: RGBAColor(red: 0.90, green: 0.70, blue: 0.30), shape: .grid))
        types.register(PortTypeInfo(
            type: .object, displayName: "Object", color: RGBAColor(red: 0.70, green: 0.50, blue: 0.85), shape: .square))
    }
}

/// Every built-in pack: math, logic, string, flow, utility and data.
public enum StandardPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        MathPack.register(nodes: &nodes, types: &types)
        LogicPack.register(nodes: &nodes, types: &types)
        StringPack.register(nodes: &nodes, types: &types)
        FlowPack.register(nodes: &nodes, types: &types)
        UtilityPack.register(nodes: &nodes, types: &types)
        DataPack.register(nodes: &nodes, types: &types)
    }
}
