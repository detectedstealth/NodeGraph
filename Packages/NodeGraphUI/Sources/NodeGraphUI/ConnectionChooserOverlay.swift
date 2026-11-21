#if !os(tvOS) && !os(watchOS)
import NodeGraphCore
import SwiftUI

/// The accessible way to draw a link: a list of the ports one can reach, opened by a VoiceOver
/// action. It dims the canvas, so a tap outside cancels.
struct ConnectionChooserOverlay: View {
    let model: GraphEditorModel

    var body: some View {
        if let request = model.connectionRequest {
            ZStack {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancelConnection() }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect \(request.nodeTitle), \(request.portName)").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(request.candidates) { candidate in
                                Button { model.completeConnection(to: candidate.address) } label: {
                                    HStack {
                                        Text("\(candidate.nodeTitle), \(candidate.portName)")
                                        Spacer()
                                        Text(candidate.typeName).foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { model.cancelConnection() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(18)
                .frame(maxWidth: 380)
                .foregroundStyle(Color(model.theme.nodeTitle))
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(model.theme.nodeHeader)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(model.theme.nodeBorder), lineWidth: 1))
                .shadow(radius: 20, y: 6)
                .accessibilityAddTraits(.isModal)
            }
        }
    }
}
#endif
