import FoundationModels
import NodeGraphAssistant

/// Output schemas for the stages of generation, built from what the registry and the editor
/// allow, so the model chooses among valid answers instead of writing free text.
enum StageSchemas {
    /// A list of node type ids, each one of `types`.
    static func nodePick(types: [String], maxNodes: Int) throws -> GenerationSchema {
        try GenerationSchema(
            root: DynamicGenerationSchema(
                arrayOf: DynamicGenerationSchema(
                    name: "NodeType", description: "A node type to add.", anyOf: types),
                minimumElements: 1, maximumElements: maxNodes),
            dependencies: [])
    }

    /// An object with one optional field per slot, each constrained to its shape.
    static func properties(for slots: [PropertySlot]) throws -> GenerationSchema {
        try GenerationSchema(
            root: DynamicGenerationSchema(
                name: "Properties",
                properties: slots.map { slot in
                    DynamicGenerationSchema.Property(
                        name: slot.id, description: slot.title, schema: schema(for: slot), isOptional: true)
                }),
            dependencies: [])
    }

    /// A whole graph: nodes (an alias and one of `types`), settings (a node, a property, and its value as
    /// JSON text) and links (`alias.port` to `alias.port`).
    static func graph(types: [String]) throws -> GenerationSchema {
        func text(_ name: String, _ description: String) -> DynamicGenerationSchema.Property {
            DynamicGenerationSchema.Property(name: name, description: description, schema: DynamicGenerationSchema(type: String.self), isOptional: false)
        }
        let node = DynamicGenerationSchema(name: "Node", description: "One node.", properties: [
            text("alias", "A short name for the node: letters and digits only."),
            DynamicGenerationSchema.Property(
                name: "type", description: "The node type.", schema: DynamicGenerationSchema(name: "NodeType", anyOf: types), isOptional: false),
        ])
        let setting = DynamicGenerationSchema(name: "Setting", description: "One setting of a node.", properties: [
            text("node", "The alias of the node."), text("property", "The setting's name."),
            text("value", "The value as JSON: 2, \"hello\" with quotes, or true."),
        ])
        let link = DynamicGenerationSchema(name: "Link", description: "One link.", properties: [
            text("from", "An output, written alias.port."), text("to", "An input, written alias.port."),
        ])
        func list(_ name: String, _ item: DynamicGenerationSchema, _ description: String) -> DynamicGenerationSchema.Property {
            DynamicGenerationSchema.Property(name: name, description: description, schema: DynamicGenerationSchema(arrayOf: item), isOptional: false)
        }
        return try GenerationSchema(
            root: DynamicGenerationSchema(name: "Graph", properties: [
                list("nodes", node, "Every node the graph needs."),
                list("settings", setting, "The settings to change from their defaults."),
                list("links", link, "The links between nodes."),
            ]),
            dependencies: [])
    }

    /// One output, written `alias.port`, or "none".
    static func source(from sources: [String]) throws -> GenerationSchema {
        try GenerationSchema(
            root: DynamicGenerationSchema(name: "Source", description: "The output that feeds the input.", anyOf: sources + ["none"]),
            dependencies: [])
    }

    private static func schema(for slot: PropertySlot) -> DynamicGenerationSchema {
        switch slot.shape {
        case .bool:
            return DynamicGenerationSchema(type: Bool.self)
        case .int(let low, let high):
            switch (low, high) {
            case (let low?, let high?) where low <= high: return DynamicGenerationSchema(type: Int.self, guides: [.range(low...high)])
            case (let low?, nil): return DynamicGenerationSchema(type: Int.self, guides: [.minimum(low)])
            case (nil, let high?): return DynamicGenerationSchema(type: Int.self, guides: [.maximum(high)])
            default: return DynamicGenerationSchema(type: Int.self)
            }
        case .double(let low, let high):
            switch (low, high) {
            case (let low?, let high?) where low <= high: return DynamicGenerationSchema(type: Double.self, guides: [.range(low...high)])
            case (let low?, nil): return DynamicGenerationSchema(type: Double.self, guides: [.minimum(low)])
            case (nil, let high?): return DynamicGenerationSchema(type: Double.self, guides: [.maximum(high)])
            default: return DynamicGenerationSchema(type: Double.self)
            }
        case .text:
            return DynamicGenerationSchema(type: String.self)
        case .choice(let choices):
            return DynamicGenerationSchema(name: slot.id + "Choice", anyOf: choices)
        }
    }
}
