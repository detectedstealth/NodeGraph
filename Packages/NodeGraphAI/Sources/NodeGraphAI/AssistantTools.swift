#if !os(tvOS) && !os(watchOS)
import FoundationModels
import NodeGraphAssistant

// Tool wrappers for the model (decision 226). Each is a thin shell over an `AssistantWorkspace`
// function, which holds the logic and the tests. A tool never throws for a bad argument: it
// answers with the problem in words, so the model can correct its next call instead of the whole
// response failing. Descriptions stay short, since every definition costs context on a 4K model.

/// Looks up node types in the registry.
public struct SearchNodesTool: Tool {
    public let name = "searchNodes"
    public let description = "Finds node types by what they do. Use before choosing a node type."

    let workspace: AssistantWorkspace

    @Generable
    public struct Arguments {
        @Guide(description: "Words describing the node, like \"add numbers\".")
        public var query: String
        public init(query: String) { self.query = query }
    }

    public init(workspace: AssistantWorkspace) { self.workspace = workspace }

    public func call(arguments: Arguments) async throws -> String {
        let found = workspace.searchNodes(arguments.query, limit: 6)
        return found.isEmpty ? "No node type matches \"\(arguments.query)\"." : found.map(\.rendered).joined(separator: "\n")
    }
}

/// Describes one node type: ports, properties and defaults.
public struct DescribeNodeTool: Tool {
    public let name = "describeNode"
    public let description = "Lists the ports and properties of a node type."

    let workspace: AssistantWorkspace

    @Generable
    public struct Arguments {
        @Guide(description: "A node type id, like \"math.add\".")
        public var type: String
        public init(type: String) { self.type = type }
    }

    public init(workspace: AssistantWorkspace) { self.workspace = workspace }

    public func call(arguments: Arguments) async throws -> String {
        workspace.describeNode(type: arguments.type) ?? "There is no node type \"\(arguments.type)\". Use searchNodes."
    }
}

/// Reports what is wrong with the graph.
public struct CheckGraphTool: Tool {
    public let name = "checkGraph"
    public let description = "Lists validation errors and lint findings in the graph."

    let workspace: AssistantWorkspace

    @Generable
    public struct Arguments {}

    public init(workspace: AssistantWorkspace) { self.workspace = workspace }

    public func call(arguments: Arguments) async throws -> String {
        let diagnostics = workspace.diagnostics()
        let findings = workspace.lint()
        if diagnostics.isEmpty && findings.isEmpty { return "No problems found." }
        return [workspace.render(diagnostics), workspace.render(findings)].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Explains where a value of the last run came from.
public struct TraceValueTool: Tool {
    public let name = "traceValue"
    public let description = "Shows why an output port had its value in the last run, upstream step by step."

    let workspace: AssistantWorkspace

    @Generable
    public struct Arguments {
        @Guide(description: "An output port like \"n3.result\".")
        public var port: String
        public init(port: String) { self.port = port }
    }

    public init(workspace: AssistantWorkspace) { self.workspace = workspace }

    public func call(arguments: Arguments) async throws -> String {
        do {
            return try workspace.traceUpstream(arguments.port).rendered(aliases: workspace.aliases)
        } catch {
            return "\(error)"
        }
    }
}

/// Proposes small edits to existing nodes. The editor shows them; nothing changes until accepted.
public struct ProposeEditTool: Tool {
    public let name = "proposeEdit"
    public let description = "Proposes edits to existing nodes: set a property, title or mode, connect, disconnect or remove."

    let workspace: AssistantWorkspace
    let inbox: ProposalInbox

    @Generable
    public enum Kind: String, CaseIterable {
        case setProperty, setTitle, setMode, connect, disconnect, removeNode
    }

    @Generable
    public struct Operation {
        public var op: Kind
        @Guide(description: "Node alias like \"n3\", for every op except connect and disconnect.")
        public var node: String?
        @Guide(description: "Property name, for setProperty.")
        public var property: String?
        @Guide(description: "New value as JSON text (4, \"hi\", true), for setProperty, setTitle and setMode.")
        public var value: String?
        @Guide(description: "Output port like \"n1.out\", for connect and disconnect.")
        public var from: String?
        @Guide(description: "Input port like \"n2.a\", for connect and disconnect.")
        public var to: String?

        public init(op: Kind, node: String? = nil, property: String? = nil, value: String? = nil, from: String? = nil, to: String? = nil) {
            self.op = op
            self.node = node
            self.property = property
            self.value = value
            self.from = from
            self.to = to
        }
    }

    @Generable
    public struct Arguments {
        public var operations: [Operation]
        public init(operations: [Operation]) { self.operations = operations }
    }

    public init(workspace: AssistantWorkspace, inbox: ProposalInbox) {
        self.workspace = workspace
        self.inbox = inbox
    }

    public func call(arguments: Arguments) async throws -> String {
        let change = workspace.proposeEdit(arguments.operations.map(\.editOperation))
        inbox.put(change)
        return change.rendered(in: workspace)
    }
}

/// Proposes a new set of nodes and links. Slice 2 replaces the JSON text with generated schemas.
public struct ProposeGraphTool: Tool {
    public let name = "proposeGraph"
    public let description = "Proposes new nodes and links, as a graph spec in JSON."

    let workspace: AssistantWorkspace
    let inbox: ProposalInbox

    @Generable
    public struct Arguments {
        @Guide(description: "JSON: {\"nodes\":[{\"alias\":\"a\",\"type\":\"util.number\",\"properties\":{\"value\":4}}],\"links\":[{\"from\":\"a.value\",\"to\":\"b.a\"}]}")
        public var spec: String
        public init(spec: String) { self.spec = spec }
    }

    public init(workspace: AssistantWorkspace, inbox: ProposalInbox) {
        self.workspace = workspace
        self.inbox = inbox
    }

    public func call(arguments: Arguments) async throws -> String {
        do {
            let change = try workspace.propose(json: arguments.spec)
            inbox.put(change)
            return change.rendered(in: workspace)
        } catch {
            return "\(error)"
        }
    }
}

/// The tools handed to a session.
public enum AssistantTools {
    /// Tools that only read. Few on purpose: three to five per request is the budget for a small model.
    public static func reading(_ workspace: AssistantWorkspace) -> [any Tool] {
        [SearchNodesTool(workspace: workspace), DescribeNodeTool(workspace: workspace),
         CheckGraphTool(workspace: workspace), TraceValueTool(workspace: workspace)]
    }

    /// The tools for changing a graph: lookup of node types, plus the two propose tools.
    public static func proposing(_ workspace: AssistantWorkspace, into inbox: ProposalInbox) -> [any Tool] {
        [SearchNodesTool(workspace: workspace), DescribeNodeTool(workspace: workspace),
         ProposeEditTool(workspace: workspace, inbox: inbox), ProposeGraphTool(workspace: workspace, inbox: inbox)]
    }
}
#endif
