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
        registerConvert(in: &nodes)
        registerPeak(in: &nodes)
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

/// Turns a temperature into a plain number in the unit you choose.
func registerConvert(in nodes: inout NodeRegistry) {
    nodes.register(NodeDefinition(
        typeID: "temperature.convert",
        displayName: "Convert Temperature",
        category: "Temperature",
        ports: [
            PortDefinition(
                id: "temperature", direction: .input, type: .temperature, defaultValue: 20.0),
            PortDefinition(id: "result", direction: .output, type: .init("number")),
        ],
        properties: [
            PropertyDefinition(
                id: "unit", displayName: "Unit",
                kind: .choice([
                    PropertyChoice(value: "celsius", label: "Celsius"),
                    PropertyChoice(value: "fahrenheit", label: "Fahrenheit"),
                    PropertyChoice(value: "kelvin", label: "Kelvin"),
                ]),
                defaultValue: "celsius"),
        ],
        isPure: true,
    )) { ctx in
        let celsius = try ctx.number("temperature")
        switch try ctx.property("unit").stringValue {
        case "fahrenheit": return ["result": .double(celsius * 9 / 5 + 32)]
        case "kelvin": return ["result": .double(celsius + 273.15)]
        default: return ["result": .double(celsius)]
        }
    }
}

/// Remembers the highest temperature it has been given.
func registerPeak(in nodes: inout NodeRegistry) {
    nodes.register(NodeDefinition(
        typeID: "temperature.peak",
        displayName: "Peak Temperature",
        category: "Temperature",
        ports: [
            PortDefinition(
                id: "temperature", direction: .input, type: .temperature, defaultValue: 20.0),
            PortDefinition(id: "reset", direction: .input, kind: .trigger),
            PortDefinition(id: "peak", direction: .output, type: .temperature),
        ],
    )) { ctx in
        let reading = try ctx.number("temperature")
        // The state is whatever the node returned last pass. A node that keeps state must not be
        // pure, or cached passes would skip its updates.
        let before = ctx.didTrigger("reset") ? reading : (ctx.state?.numberValue ?? reading)
        let peak = max(before, reading)
        return NodeOutputs(["peak": .double(peak)], state: .double(peak))
    }
}
