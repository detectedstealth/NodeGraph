import CoreGraphics
import NodeGraphCore
import SwiftUI

/// Draws a custom widget (see ``WidgetKind/custom(_:)``) into `rect`, in graph space, with the
/// property's current value if it has one. Runs for every visible node each frame, so keep it
/// cheap.
public typealias WidgetRenderer = @MainActor (inout GraphicsContext, CGRect, GraphValue?, GraphTheme) -> Void
