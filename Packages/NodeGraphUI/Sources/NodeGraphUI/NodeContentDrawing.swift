import CoreGraphics
import NodeGraphCore
import SwiftUI

/// What a node's custom drawing is given.
public struct NodeContentContext {
    public var node: Node
    /// The node's definition including dynamic ports; nil for an unregistered type.
    public var definition: NodeDefinition?
    /// The area to draw in, in graph space. Drawing outside it is clipped.
    public var rect: CGRect
    public var theme: GraphTheme
    /// Screen points per graph unit, for choosing how much detail to draw.
    public var zoom: Double
    /// What the node published in the latest run, by output port. Empty before a run, or when
    /// the node has nothing current (see ``RunValues``).
    public var values: [PortID: GraphValue] = [:]
}

/// Draws into an area of a node's body, below its widgets, for domain visuals such as timeline
/// thumbnails or scopes. Register one per node type with
/// ``GraphEditorModel/registerContentDrawing(for:_:)``.
///
/// The area is reserved in the node's layout, so it counts toward the node's minimum height and
/// hit testing sees it as part of the node. It is drawn only at full detail. `draw` runs for
/// every visible node of the type each frame, so keep it cheap.
public struct NodeContentDrawing {
    /// Height of the area, in graph units. Its width is the node's width less the side insets.
    public var height: Double
    public var draw: @MainActor (inout GraphicsContext, NodeContentContext) -> Void

    public init(height: Double, draw: @escaping @MainActor (inout GraphicsContext, NodeContentContext) -> Void) {
        self.height = height
        self.draw = draw
    }
}

extension NodeContentDrawing {
    /// Shows the latest value of an output port as text, such as the Watch node's. Without a
    /// value it shows a dash. Long values are cut to fit the area.
    public static func readout(of port: PortID, height: Double = 24) -> NodeContentDrawing {
        NodeContentDrawing(height: height) { context, content in
            let theme = content.theme
            let value = content.values[port]
            let text = value?.summary(limit: 200) ?? "–"
            let color = Color(value == nil ? theme.portLabel.withAlpha(0.5) : theme.nodeTitle)
            let resolved = context.resolve(
                Text(text).font(.system(size: theme.portFontSize, design: .monospaced)).foregroundColor(color))
            context.draw(resolved, at: CGPoint(x: content.rect.minX, y: content.rect.midY), anchor: .leading)
        }
    }
}
