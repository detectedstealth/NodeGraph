import NodeGraphCore

/// Sizes that decide how a node is laid out, in graph units. Not part of the theme: the theme
/// says how things look, these say where things are, and hit testing depends on them too.
public struct NodeLayoutMetrics: Hashable, Sendable {
    public var headerHeight: Double
    public var portRowHeight: Double
    /// Space above the first and below the last port row.
    public var portInset: Double
    public var portRadius: Double
    /// How close a pointer must come to a port's center to count as on it.
    public var portHitRadius: Double
    public var minimumWidth: Double
    /// Side of the square resize handle in the bottom-right corner.
    public var resizeHandleSize: Double

    public init(
        headerHeight: Double = 28,
        portRowHeight: Double = 22,
        portInset: Double = 8,
        portRadius: Double = 5,
        portHitRadius: Double = 12,
        minimumWidth: Double = 100,
        resizeHandleSize: Double = 14
    ) {
        self.headerHeight = headerHeight
        self.portRowHeight = portRowHeight
        self.portInset = portInset
        self.portRadius = portRadius
        self.portHitRadius = portHitRadius
        self.minimumWidth = minimumWidth
        self.resizeHandleSize = resizeHandleSize
    }

    public static let standard = NodeLayoutMetrics()
}

/// Where one port sits.
public struct PortLayout: Hashable, Sendable {
    public var address: PortAddress
    public var definition: PortDefinition
    /// The center of the port's dot, on the node's left (inputs) or right (outputs) edge. Links
    /// attach here.
    public var position: GraphPoint
}

/// The geometry of one node in graph space: the single source for drawing, hit testing and
/// link endpoints, so they cannot disagree.
public struct NodeLayout: Hashable, Sendable {
    public var node: NodeID
    /// The whole node. At least as tall as its ports need; a collapsed node is only its header.
    public var frame: GraphRect
    public var header: GraphRect
    /// Below the header: port rows, later in-node widgets. Empty when collapsed.
    public var body: GraphRect
    public var isCollapsed: Bool
    public var inputs: [PortLayout]
    public var outputs: [PortLayout]
    public var resizeHandle: GraphRect
    /// The smallest size the node can be resized to without clipping its ports.
    public var minimumSize: GraphSize

    /// Lays out `node`.
    ///
    /// - Parameter definition: The node's definition as the node sees it, which is
    ///   ``NodeRegistry/definition(for:)-(Node)`` so dynamic ports are included. Nil for a node
    ///   whose type is not registered: it gets a frame and no ports.
    public init(node: Node, definition: NodeDefinition?, metrics: NodeLayoutMetrics = .standard) {
        let inputPorts = definition?.inputs ?? []
        let outputPorts = definition?.outputs ?? []
        let rows = max(inputPorts.count, outputPorts.count)
        let contentHeight = metrics.headerHeight + 2 * metrics.portInset + Double(rows) * metrics.portRowHeight
        let requested = node.size ?? definition?.defaultSize ?? GraphSize(width: 160, height: 80)
        let width = max(requested.width, metrics.minimumWidth)
        let height = node.isCollapsed ? metrics.headerHeight : max(requested.height, contentHeight)

        self.node = node.id
        self.isCollapsed = node.isCollapsed
        self.minimumSize = GraphSize(width: metrics.minimumWidth, height: contentHeight)
        let origin = node.position
        frame = GraphRect(origin: origin, size: GraphSize(width: width, height: height))
        header = GraphRect(x: origin.x, y: origin.y, width: width, height: metrics.headerHeight)
        body = node.isCollapsed
            ? GraphRect(x: origin.x, y: origin.y + metrics.headerHeight, width: width, height: 0)
            : GraphRect(x: origin.x, y: origin.y + metrics.headerHeight, width: width, height: height - metrics.headerHeight)
        let handle = metrics.resizeHandleSize
        resizeHandle = node.isCollapsed
            ? GraphRect(x: origin.x + width, y: origin.y + height, width: 0, height: 0)
            : GraphRect(x: origin.x + width - handle, y: origin.y + height - handle, width: handle, height: handle)

        // Collapsed nodes attach every link at the middle of the header edge.
        func position(row: Int, x: Double) -> GraphPoint {
            node.isCollapsed
                ? GraphPoint(x: x, y: origin.y + metrics.headerHeight / 2)
                : GraphPoint(
                    x: x,
                    y: origin.y + metrics.headerHeight + metrics.portInset
                        + (Double(row) + 0.5) * metrics.portRowHeight)
        }
        inputs = inputPorts.enumerated().map { row, port in
            PortLayout(
                address: PortAddress(node: node.id, port: port.id, direction: .input),
                definition: port, position: position(row: row, x: origin.x))
        }
        outputs = outputPorts.enumerated().map { row, port in
            PortLayout(
                address: PortAddress(node: node.id, port: port.id, direction: .output),
                definition: port, position: position(row: row, x: origin.x + width))
        }
    }

    /// The layout of a port, or nil if the node has no such port.
    public func port(_ address: PortAddress) -> PortLayout? {
        let ports = address.direction == .input ? inputs : outputs
        return ports.first { $0.address == address }
    }

    /// The port whose center is nearest `point` and within `radius`, if any.
    public func port(at point: GraphPoint, radius: Double) -> PortLayout? {
        var best: (port: PortLayout, distance: Double)?
        for port in inputs + outputs {
            let distance = port.position.distance(to: point)
            guard distance <= radius, distance < (best?.distance ?? .infinity) else { continue }
            best = (port, distance)
        }
        return best?.port
    }
}

extension GraphPoint {
    /// Straight-line distance to another point.
    public func distance(to other: GraphPoint) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
