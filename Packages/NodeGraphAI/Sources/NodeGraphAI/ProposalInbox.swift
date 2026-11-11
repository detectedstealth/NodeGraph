import NodeGraphAssistant
import Synchronization

/// Where the propose tools leave their result.
///
/// A tool may not edit the document (decision 211), and the model only sees text, so a propose
/// tool describes the change to the model and parks the real `PendingChange` here for the editor
/// to preview. A newer proposal replaces an older one the person has not looked at.
public final class ProposalInbox: Sendable {
    private let latest = Mutex<PendingChange?>(nil)

    public init() {}

    func put(_ change: PendingChange) { latest.withLock { $0 = change } }

    /// The most recent proposal, leaving the inbox empty.
    public func take() -> PendingChange? { latest.withLock { change in defer { change = nil }; return change } }

    /// The most recent proposal, left in place.
    public var current: PendingChange? { latest.withLock { $0 } }
}
