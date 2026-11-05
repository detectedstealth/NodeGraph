import Foundation
import Synchronization

/// Fans values out to any number of independent `AsyncStream`s.
///
/// Thread-safe, so values can be sent from any isolation and streams can end anywhere. Streams
/// only see values sent after they were created. When the broadcaster goes away, its streams
/// finish.
final class Broadcaster<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    /// A new stream of everything sent from now on.
    func stream(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        continuations.withLock { $0[id] = continuation }
        return stream
    }

    /// Whether anyone is listening. Lets callers skip building events nobody will read.
    var hasSubscribers: Bool {
        continuations.withLock { !$0.isEmpty }
    }

    func send(_ element: Element) {
        let current = continuations.withLock { Array($0.values) }
        for continuation in current { continuation.yield(element) }
    }

    deinit {
        for continuation in continuations.withLock({ Array($0.values) }) { continuation.finish() }
    }
}
