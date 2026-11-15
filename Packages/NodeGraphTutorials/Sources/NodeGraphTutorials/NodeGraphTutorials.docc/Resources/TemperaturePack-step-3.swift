import NodeGraphCore

extension PortType {
    /// A temperature, carried as a number of degrees Celsius.
    public static let temperature: PortType = "temperature"
}

/// Describes the temperature port type to the editor and the connection rules.
func registerTemperatureType(in types: inout TypeRegistry) {
    types.register(PortTypeInfo(
        type: .temperature,
        displayName: "Temperature",
        color: RGBAColor(red: 0.95, green: 0.45, blue: 0.25),
        // Any number can feed a temperature input as it is.
        acceptsFrom: [.init("number")],
    ))
    // A temperature can feed a number input.
    types.registerConversion(from: .temperature, to: .init("number"))
}

/// Temperature port type and nodes.
public enum TemperaturePack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        registerTemperatureType(in: &types)
        registerSensor(in: &nodes)
    }
}

/// A source node: a temperature you type in.
func registerSensor(in nodes: inout NodeRegistry) {
    nodes.register(NodeDefinition(
        typeID: "temperature.sensor",
        displayName: "Temperature Sensor",
        category: "Temperature",
        ports: [
            PortDefinition(id: "value", displayName: "Temperature", direction: .output, type: .temperature),
        ],
        properties: [
            PropertyDefinition(
                id: "celsius", displayName: "Degrees Celsius",
                kind: .double(min: -273.15), defaultValue: 20.0),
        ],
        isPure: true,
    )) { ctx in
        ["value": try ctx.property("celsius")]
    }
}
