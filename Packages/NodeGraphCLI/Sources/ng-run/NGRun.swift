import ArgumentParser
import Foundation
import NodeGraphAssistant
import NodeGraphCore
import NodeGraphRunKit

/// `ng-run file.nodegraph` still runs a document, as it always has: `run` is the default subcommand.
@main
struct NGRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ng-run",
        abstract: "Runs, checks and summarizes node graph documents without a UI.",
        discussion: """
            With no subcommand, runs the document: ng-run file.nodegraph. Every command exits with \
            status 0 on success, 1 when it found a problem or a node failed, and 2 when the file \
            could not be read.
            """,
        subcommands: [Run.self, Validate.self, Lint.self, Digest.self],
        defaultSubcommand: Run.self)
}

/// Reads a document, turning any failure into a message and exit status 2.
private func load(_ file: URL) throws -> GraphDocument {
    do {
        return try GraphDocument.decode(from: Data(contentsOf: file))
    } catch {
        FileHandle.standardError.write(Data("ng-run: cannot read \(file.path): \(error.localizedDescription)\n".utf8))
        throw ExitCode(2)
    }
}

private func write(_ data: Data, to output: URL?) throws {
    if let output {
        try data.write(to: output, options: .atomic)
    } else {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Runs a document and prints what every node produced as JSON.",
        discussion: "Time is simulated, so the same document gives the same report. Exits with status 1 if any node failed, so scripts can check it.")

    @Argument(help: "A .nodegraph document.", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Option(help: "How many evaluation passes to run.")
    var ticks = 1

    @Option(help: "Simulated time per pass, in milliseconds.")
    var deltaMs = 16

    @Option(name: .customLong("var"), help: "Override a graph variable: name=value (JSON, or plain text for a string). Repeatable.")
    var variables: [String] = []

    @Option(name: .shortAndLong, help: "Write the report here instead of standard output.", transform: { URL(fileURLWithPath: $0) })
    var output: URL?

    mutating func run() async throws {
        guard ticks >= 1 else { throw ValidationError("--ticks must be at least 1") }
        let document = try load(file)
        let report = try await GraphRun.run(
            document, ticks: ticks, delta: .milliseconds(deltaMs),
            variables: GraphRun.parseVariables(variables))
        try write(try report.encoded(), to: output)
        if !report.succeeded { throw ExitCode(1) }
    }
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Checks that a document is valid: node types, property values and every link.",
        discussion: "Looks at the root graph and every subgraph. Exits with status 1 if there is an error. Warnings alone pass, unless --strict.")

    @Argument(help: "A .nodegraph document.", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Flag(help: "Print JSON instead of text.")
    var json = false

    @Flag(help: "Fail on warnings too.")
    var strict = false

    mutating func run() throws {
        let report = GraphCheck.validate(try load(file))
        try write(json ? try report.encoded() : Data(report.text.utf8), to: nil)
        if !report.failing(strict: strict).isEmpty { throw ExitCode(1) }
    }
}

struct Lint: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Finds what is valid but suspicious: isolated nodes, unused outputs, constant expressions.",
        discussion: "Never runs the graph. Exits with status 1 if a lint reports a problem. Hints alone pass, unless --strict.")

    @Argument(help: "A .nodegraph document.", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Flag(help: "Print JSON instead of text.")
    var json = false

    @Flag(help: "Fail on hints too.")
    var strict = false

    mutating func run() throws {
        let report = GraphCheck.lint(try load(file))
        try write(json ? try report.encoded() : Data(report.text.utf8), to: nil)
        if !report.failing(strict: strict).isEmpty { throw ExitCode(1) }
    }
}

struct Digest: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Prints a compact text summary of a document: short names for the nodes, then the links.")

    @Argument(help: "A .nodegraph document.", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Option(help: "How much to say about each node: outline, compact or full.")
    var detail = "compact"

    mutating func run() throws {
        guard let level = GraphDigest.Detail.allCases.first(where: { String(describing: $0) == detail }) else {
            throw ValidationError("--detail must be outline, compact or full")
        }
        try write(Data(GraphCheck.digest(try load(file), detail: level).utf8), to: nil)
    }
}
