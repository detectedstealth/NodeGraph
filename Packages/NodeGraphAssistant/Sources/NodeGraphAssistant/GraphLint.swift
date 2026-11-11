import NodeGraphCore

/// What a lint looks at: the graph with its registries, plus the subgraph definitions, which
/// the validation context does not carry but some lints need (to see who uses a variable).
public struct LintContext: Sendable {
    public var validation: ValidationContext
    public var subgraphs: [SubgraphDefinition]

    public var graph: Graph { validation.graph }
    public var nodes: NodeRegistry { validation.nodes }

    public init(validation: ValidationContext, subgraphs: [SubgraphDefinition] = []) {
        self.validation = validation
        self.subgraphs = subgraphs
    }

    /// The root graph of `editor` as it is now.
    public init(editor: GraphEditor) {
        self.init(validation: editor.validationContext, subgraphs: Array(editor.subgraphs.values))
    }
}

/// An edit that would resolve a finding, ready to preview and apply.
public struct SuggestedFix: Hashable, Sendable {
    public var description: String
    public var command: GraphCommand

    public init(description: String, command: GraphCommand) {
        self.description = description
        self.command = command
    }
}

/// One thing a lint noticed.
public struct LintFinding: Hashable, Sendable {
    public enum Level: String, Hashable, Sendable, Codable {
        /// Probably wrong: the graph will not do what it looks like it does.
        case problem
        /// Works, but could be simpler or tidier.
        case hint
    }

    /// The id of the lint that found it.
    public var lint: String
    public var level: Level
    /// The structured form, with the node, port or link it is about, for tools to act on.
    public var diagnostic: GraphDiagnostic
    /// An edit that resolves it, when a safe one exists.
    public var fix: SuggestedFix?

    public init(lint: String, level: Level, diagnostic: GraphDiagnostic, fix: SuggestedFix? = nil) {
        self.lint = lint
        self.level = level
        self.diagnostic = diagnostic
        self.fix = fix
    }
}

/// A deterministic check for something that is probably a mistake or could be better.
///
/// Lints look at structure only and never run the graph. Core's ``GraphValidator`` says what is
/// invalid; lints say what is valid but suspicious. Domain packs add their own.
public protocol GraphLint: Sendable {
    /// Stable identifier, unique among lints, such as `"lint.unusedOutput"`.
    var id: String { get }
    /// One sentence on what it looks for, suitable for showing to a user or a model.
    var summary: String { get }
    func check(in context: LintContext) -> [LintFinding]
}

/// Runs a set of lints.
public struct GraphLinter: Sendable {
    public var lints: [any GraphLint]

    public init(lints: [any GraphLint] = GraphLinter.standardLints) {
        self.lints = lints
    }

    /// The lints that need no domain knowledge.
    public static var standardLints: [any GraphLint] {
        [Lints.UnconnectedInput(), Lints.IsolatedNode(), Lints.UnusedOutput(), Lints.InactiveNode(),
         Lints.ConstantExpression(), Lints.DuplicateNode(), Lints.EmptyGroup(), Lints.UnusedVariable()]
    }

    public func adding(_ lint: any GraphLint) -> GraphLinter {
        GraphLinter(lints: lints + [lint])
    }

    /// Every finding, in lint order and then graph order, so the same graph gives the same list.
    public func run(in context: LintContext) -> [LintFinding] {
        lints.flatMap { $0.check(in: context) }
    }
}

/// Offers a Core ``GraphRule`` (a domain constraint such as "exactly one render node") as a lint,
/// so a pack's existing rules show up beside the standard lints. Its findings are problems.
public struct RuleLint: GraphLint {
    public var rule: any GraphRule
    public var id: String { "rule." + rule.id }
    public var summary: String { rule.summary }

    public init(_ rule: any GraphRule) { self.rule = rule }

    public func check(in context: LintContext) -> [LintFinding] {
        rule.check(in: context.validation).map { LintFinding(lint: id, level: .problem, diagnostic: $0) }
    }
}

extension DiagnosticCode {
    public static let unconnectedInput: DiagnosticCode = "lint.unconnectedInput"
    public static let isolatedNode: DiagnosticCode = "lint.isolatedNode"
    public static let unusedOutput: DiagnosticCode = "lint.unusedOutput"
    public static let inactiveNode: DiagnosticCode = "lint.inactiveNode"
    public static let constantExpression: DiagnosticCode = "lint.constantExpression"
    public static let duplicateNode: DiagnosticCode = "lint.duplicateNode"
    public static let emptyGroup: DiagnosticCode = "lint.emptyGroup"
    public static let unusedVariable: DiagnosticCode = "lint.unusedVariable"
}
