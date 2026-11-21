#if !os(tvOS) && !os(watchOS)
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

    /// A list of existing nodes' names (`n1`, ...), possibly empty.
    static func existingPick(aliases: [String], maxNodes: Int) throws -> GenerationSchema {
        try GenerationSchema(
            root: DynamicGenerationSchema(
                arrayOf: DynamicGenerationSchema(
                    name: "ExistingNode", description: "A node already in the graph.", anyOf: aliases),
                minimumElements: 0, maximumElements: maxNodes),
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

    /// A whole change: new nodes (an alias and one of `types`), their settings (a node, a property, and its
    /// value as JSON text), links (`alias.port` to `alias.port`, either end possibly a node already in the
    /// graph) and edits of existing nodes.
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
        let edit = DynamicGenerationSchema(name: "Edit", description: "One change to a node already in the graph.", properties: [
            DynamicGenerationSchema.Property(
                name: "op", description: "What to do.",
                schema: DynamicGenerationSchema(name: "EditKind", anyOf: ["setProperty", "setTitle", "setMode", "connect", "disconnect", "removeNode"]),
                isOptional: false),
            text("node", "An existing node's name, like n3, for every op except connect and disconnect. Empty if unused."),
            text("property", "The setting's name, for setProperty. Empty if unused."),
            text("value", "The new value as JSON, for setProperty, setTitle and setMode. Empty if unused."),
            text("from", "An output like n1.out, for connect and disconnect. Empty if unused."),
            text("to", "An input like n2.a, for connect and disconnect. Empty if unused."),
        ])
        func list(_ name: String, _ item: DynamicGenerationSchema, _ description: String) -> DynamicGenerationSchema.Property {
            DynamicGenerationSchema.Property(name: name, description: description, schema: DynamicGenerationSchema(arrayOf: item), isOptional: false)
        }
        return try GenerationSchema(
            root: DynamicGenerationSchema(name: "Graph", properties: [
                list("nodes", node, "Every node the graph needs."),
                list("settings", setting, "The settings to change from their defaults."),
                list("links", link, "The links, including any from or to a node already in the graph."),
                list("edits", edit, "Changes to nodes already in the graph. Empty if there are none."),
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
#endif
