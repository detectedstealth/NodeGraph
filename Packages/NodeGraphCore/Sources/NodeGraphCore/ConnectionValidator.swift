/// The outcome of checking a ``ConnectionProposal``.
public struct ConnectionCheck: Hashable, Sendable {
    public var diagnostics: [GraphDiagnostic]
    /// Existing links that adding the connection would remove, because a single-link port
    /// can hold only one. Empty when the connection is rejected.
    public var replacedLinks: [LinkID]

    /// Whether the connection may be made.
    public var isAllowed: Bool { !diagnostics.containsErrors }

    public init(diagnostics: [GraphDiagnostic] = [], replacedLinks: [LinkID] = []) {
        self.diagnostics = diagnostics
        self.replacedLinks = replacedLinks
    }
}

/// Decides whether a proposed link is allowed by running an ordered list of rules.
///
/// The single place connection policy lives. Editors, undo-aware commands, importers, and
/// generators all ask it. A domain pack customises policy by building a validator with a
/// different rule list.
public struct ConnectionValidator: Sendable {
    public var rules: [any ConnectionRule]

    public init(rules: [any ConnectionRule] = ConnectionRules.standard) {
        self.rules = rules
    }

    /// A copy with `rule` appended.
    public func adding(_ rule: any ConnectionRule) -> ConnectionValidator {
        ConnectionValidator(rules: rules + [rule])
    }

    /// A copy without the rule whose id matches.
    public func removing(ruleID: String) -> ConnectionValidator {
        ConnectionValidator(rules: rules.filter { $0.id != ruleID })
    }

    /// Runs every rule and reports all diagnostics, then works out which links would be replaced.
    public func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> ConnectionCheck {
        let diagnostics = rules.flatMap { $0.check(proposal, in: context) }
        guard !diagnostics.containsErrors else {
            return ConnectionCheck(diagnostics: diagnostics)
        }
        return ConnectionCheck(
            diagnostics: diagnostics, replacedLinks: replacedLinks(for: proposal, in: context))
    }

    /// Links displaced because the target input or source output accepts only one link.
    func replacedLinks(for proposal: ConnectionProposal, in context: ValidationContext) -> [LinkID] {
        var replaced: [LinkID] = []
        if context.port(proposal.target)?.allowsMultipleLinks == false {
            replaced += context.graph.links(into: proposal.target).map(\.id)
        }
        if context.port(proposal.source)?.allowsMultipleLinks == false {
            replaced += context.graph.links(from: proposal.source).map(\.id)
        }
        var seen = Set<LinkID>()
        return replaced.filter { seen.insert($0).inserted }
    }
}
