import ArgumentParser
import Foundation
import NodeGraphCore
import NodeGraphRunKit

@main
struct NGRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ng-run",
        abstract: "Runs a node graph document without a UI and prints what every node produced as JSON.",
        discussion: "Exits with status 1 if any node failed, so scripts can check it.")

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
        let document = try GraphDocument.decode(from: Data(contentsOf: file))
        let report = try await GraphRun.run(
            document, ticks: ticks, delta: .milliseconds(deltaMs),
            variables: GraphRun.parseVariables(variables))
        let data = try report.encoded()
        if let output {
            try data.write(to: output, options: .atomic)
        } else {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        if !report.succeeded { throw ExitCode(1) }
    }
}
