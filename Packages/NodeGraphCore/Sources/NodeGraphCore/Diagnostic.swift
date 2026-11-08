/// How serious a diagnostic is. Errors make a connection or graph invalid.
public enum DiagnosticSeverity: String, Hashable, Sendable, Codable {
    case error
    case warning
}

/// A stable, machine-readable identifier for a kind of problem, such as `"connection.cycle"`.
///
/// Codes are open: domain packs add their own. Tools and LLM feedback loops key off the code,
/// not the message text.
public struct DiagnosticCode: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let missingNode: DiagnosticCode = "connection.missingNode"
    public static let missingPort: DiagnosticCode = "connection.missingPort"
    public static let wrongDirection: DiagnosticCode = "connection.wrongDirection"
    public static let selfLink: DiagnosticCode = "connection.selfLink"
    public static let kindMismatch: DiagnosticCode = "connection.kindMismatch"
    public static let typeMismatch: DiagnosticCode = "connection.typeMismatch"
    public static let duplicateLink: DiagnosticCode = "connection.duplicate"
    public static let cycle: DiagnosticCode = "connection.cycle"
    public static let tooManyLinks: DiagnosticCode = "connection.tooManyLinks"
    public static let executionCycle: DiagnosticCode = "execution.cycle"
    public static let unknownNodeType: DiagnosticCode = "node.unknownType"
    public static let unknownProperty: DiagnosticCode = "node.unknownProperty"
    public static let invalidProperty: DiagnosticCode = "node.invalidProperty"
    public static let invalidPortCount: DiagnosticCode = "node.invalidPortCount"
    public static let undeclaredVariable: DiagnosticCode = "node.undeclaredVariable"
}

/// One problem found while validating a connection or graph.
///
/// Carries structured references (node, port, link) as well as a human-readable message, so
/// both an editor and an automated generator can act on it.
public struct GraphDiagnostic: Hashable, Sendable, Codable {
    public var severity: DiagnosticSeverity
    public var code: DiagnosticCode
    public var message: String
    public var node: NodeID?
    public var port: PortAddress?
    public var link: LinkID?

    public init(
        severity: DiagnosticSeverity = .error,
        code: DiagnosticCode,
        message: String,
        node: NodeID? = nil,
        port: PortAddress? = nil,
        link: LinkID? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.node = node
        self.port = port
        self.link = link
    }
}

extension Sequence where Element == GraphDiagnostic {
    /// Whether any diagnostic is an error.
    public var containsErrors: Bool { contains { $0.severity == .error } }
}
