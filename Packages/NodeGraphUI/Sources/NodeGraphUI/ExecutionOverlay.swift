import NodeGraphCore

/// What the canvas adds to a node to show how its last run went: a badge on the corner, a
/// progress bar along the bottom and a tinted border. Derived from a ``NodeRunState`` so the
/// mapping is testable without drawing anything.
struct NodeRunDecoration: Equatable {
    enum Badge: Equatable {
        case running, succeeded, failed, cancelled, skipped, cached
    }

    var badge: Badge
    /// 0...1 while a running node has reported progress.
    var progress: Double?
    /// The error for a failed node, or the latest progress message for a running one.
    var message: String?

    /// Nil for a node with nothing to show: it has not been reached, or it was bypassed.
    init?(_ state: NodeRunState) {
        switch state {
        case .idle:
            return nil
        case .running(let progress, let message):
            badge = .running
            self.progress = progress.map { $0.clamped(to: 0...1) }
            self.message = message
        case .finished(let status, _):
            switch status {
            case .succeeded: badge = .succeeded
            case .failed(let message):
                badge = .failed
                self.message = message
            case .cancelled: badge = .cancelled
            case .skipped: badge = .skipped
            case .cached: badge = .cached
            case .bypassed: return nil
            }
        }
    }

    /// Whether the node's border takes the badge's color. Quiet states leave the border alone.
    var tintsBorder: Bool { badge == .running || badge == .failed }
}

extension GraphTheme {
    /// The color of a status badge.
    func color(for badge: NodeRunDecoration.Badge) -> RGBAColor {
        switch badge {
        case .running, .succeeded: running
        case .failed: failed
        case .cancelled: triggerPortColor
        case .skipped, .cached: portLabel
        }
    }
}

extension GraphEditorModel {
    /// Folds one execution event into ``executionState``. The canvas redraws the affected nodes.
    public func apply(_ event: ExecutionEvent) {
        executionState.apply(event)
    }

    /// Forgets every node's run state, so the canvas shows no badges.
    public func clearExecutionState() {
        executionState = ExecutionState()
    }

    /// Feeds a runner's events (``GraphRunner/events(bufferingPolicy:)``) into ``executionState``
    /// until the stream ends or the returned task is cancelled.
    @discardableResult
    public func observeExecution(_ events: AsyncStream<ExecutionEvent>) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    /// The decoration to draw on a node, if any.
    func runDecoration(of node: NodeID) -> NodeRunDecoration? {
        NodeRunDecoration(executionState[node])
    }
}
