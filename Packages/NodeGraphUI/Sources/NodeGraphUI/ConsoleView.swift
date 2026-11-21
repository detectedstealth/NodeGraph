#if !os(tvOS) && !os(watchOS)
import NodeGraphCore
import SwiftUI

/// The console panel: lines from nodes, runs and checks, with a level filter. Selecting a line
/// that is about a node selects that node on the canvas and scrolls to it.
public struct ConsoleView: View {
    let console: ConsoleModel
    let model: GraphEditorModel

    public init(console: ConsoleModel, model: GraphEditorModel) {
        self.console = console
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(ConsoleLevel.allCases, id: \.self) { level in
                    let count = console.count(of: level)
                    Toggle(isOn: Binding(
                        get: { console.visibleLevels.contains(level) },
                        set: { if $0 { console.visibleLevels.insert(level) } else { console.visibleLevels.remove(level) } }
                    )) {
                        Text(count > 0 ? "\(level.title) (\(count))" : level.title)
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel("Show \(level.title.lowercased()) lines")
                    .accessibilityValue(count == 1 ? "1 line" : "\(count) lines")
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copy() }
                    .disabled(console.visibleEntries.isEmpty)
                Button("Clear", systemImage: "trash") { console.clear() }
                    .disabled(console.entries.isEmpty)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(console.visibleEntries) { entry in
                            ConsoleRow(entry: entry, isSelected: entry.node.map { model.selection.nodes.contains($0) } ?? false)
                                .id(entry.id)
                                .onTapGesture { if let node = entry.node { model.reveal(node: node) } }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: console.entries.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
                .overlay {
                    if console.visibleEntries.isEmpty {
                        Text(console.entries.isEmpty ? "Nothing logged yet. Run the graph." : "No lines at this level.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Console")
    }

    private func copy() {
        let text = console.visibleEntries.map { ConsoleRow.line(for: $0) }.joined(separator: "\n")
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

private struct ConsoleRow: View {
    let entry: ConsoleEntry
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityLabel(entry.level.title)
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
            Text(entry.text)
                .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if entry.node != nil {
                Image(systemName: "scope").foregroundStyle(.secondary).accessibilityLabel("Select node")
            }
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch entry.level {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    static func line(for entry: ConsoleEntry) -> String {
        "\(entry.date.formatted(.iso8601.time(includingFractionalSeconds: false))) [\(entry.level.title)] \(entry.text)"
    }
}

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Resizable panel

/// The console with a grab bar on its top edge: drag it up to show more lines, down to show
/// fewer, or double-click it to jump between the default height and most of the space. The
/// owner keeps `height` (so it can be saved) and says how tall the panel may get.
public struct ConsolePanel: View {
    let console: ConsoleModel
    let model: GraphEditorModel
    @Binding var height: Double
    /// The most the panel may take, normally most of the window's height.
    let maximumHeight: Double
    @State private var heightAtDragStart: Double?
    @State private var isHovering = false

    public static let minimumHeight = 90.0
    public static let defaultHeight = 200.0

    public init(console: ConsoleModel, model: GraphEditorModel, height: Binding<Double>, maximumHeight: Double) {
        self.console = console
        self.model = model
        _height = height
        self.maximumHeight = maximumHeight
    }

    /// The height after a drag of `translation` points (negative is upward) that began at `start`,
    /// kept between ``minimumHeight`` and `maximum`.
    static func height(from start: Double, dragged translation: Double, maximum: Double) -> Double {
        min(max(start - translation, minimumHeight), max(maximum, minimumHeight))
    }

    private var clamped: Double { min(max(height, Self.minimumHeight), max(maximumHeight, Self.minimumHeight)) }
    private var isExpanded: Bool { clamped > (Self.defaultHeight + maximumHeight) / 2 }

    public var body: some View {
        VStack(spacing: 0) {
            grabBar
            ConsoleView(console: console, model: model)
        }
        .frame(height: clamped)
    }

    private var grabBar: some View {
        ZStack {
            Rectangle().fill(.bar)
            Capsule()
                .fill(.secondary.opacity(isHovering || heightAtDragStart != nil ? 0.9 : 0.5))
                .frame(width: 36, height: 4)
        }
        .frame(height: 14)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = heightAtDragStart ?? clamped
                    heightAtDragStart = start
                    height = Self.height(from: start, dragged: value.translation.height, maximum: maximumHeight)
                }
                .onEnded { _ in heightAtDragStart = nil })
        .onTapGesture(count: 2) {
            height = isExpanded ? Self.defaultHeight : max(maximumHeight, Self.minimumHeight)
        }
        .onHover { hovering in
            isHovering = hovering
            #if canImport(AppKit)
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            #endif
        }
        .accessibilityElement()
        .accessibilityLabel("Resize console")
        .accessibilityValue("\(Int(clamped)) points tall")
        .accessibilityAdjustableAction { direction in
            let step = 40.0
            height = Self.height(from: clamped, dragged: direction == .increment ? -step : step, maximum: maximumHeight)
        }
    }
}
#endif
