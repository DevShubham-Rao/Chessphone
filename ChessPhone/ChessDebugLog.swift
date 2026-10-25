import Foundation
import SwiftUI
import UIKit

struct ChessDebugEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let category: String
    let title: String
    let details: String
}

/// In-memory diagnostics for board reads and move reconciliation. API keys and
/// image base64 are deliberately never written into the textual log.
@MainActor
final class ChessDebugLog: ObservableObject {
    static let shared = ChessDebugLog()

    @Published private(set) var events: [ChessDebugEvent] = []
    @Published private(set) var latestRequestImage: UIImage?
    private let maxEvents = 160

    private init() {}

    func record(_ category: String, _ title: String, details: String = "") {
        events.append(ChessDebugEvent(category: category, title: title, details: details))
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
    }

    func recordRequestImage(_ jpeg: Data) {
        latestRequestImage = UIImage(data: jpeg)
    }

    func clear() {
        events.removeAll()
        latestRequestImage = nil
    }

    var exportText: String {
        events.map { event in
            let date = DateFormatter.localizedString(from: event.date, dateStyle: .short, timeStyle: .medium)
            return "[\(date)] [\(event.category)] \(event.title)\n\(event.details)"
        }.joined(separator: "\n\n")
    }
}

enum ChessDebugFormat {
    static func board(_ squares: [Piece?]) -> String {
        guard squares.count == 64 else { return "<invalid board: \(squares.count) squares>" }
        return (0..<8).map { row in
            let rank = 7 - row
            let cells = (0..<8).map { file -> String in
                squares[Square.index(file: file, rank: rank)].map { String($0.fenChar) } ?? "."
            }
            return "\(rank + 1)  \(cells.joined(separator: " "))"
        }.joined(separator: "\n") + "\n   a b c d e f g h"
    }

    static func differences(from old: [Piece?], to new: [Piece?]) -> String {
        guard old.count == 64, new.count == 64 else { return "<invalid board data>" }
        let changed = (0..<64).compactMap { square -> String? in
            guard old[square] != new[square] else { return nil }
            return "\(Square.name(square)): \(old[square].map { String($0.fenChar) } ?? ".") -> \(new[square].map { String($0.fenChar) } ?? ".")"
        }
        return changed.isEmpty ? "<none>" : changed.joined(separator: ", ")
    }
}

struct ChessDebugView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var debug = ChessDebugLog.shared
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Latest image sent") {
                        if let image = debug.latestRequestImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text("No scan image yet.").foregroundStyle(.secondary)
                        }
                    }

                    if debug.events.isEmpty {
                        ContentUnavailableView("No debug events", systemImage: "ladybug",
                                               description: Text("Run a board scan or enter a move to capture diagnostics."))
                    } else {
                        ForEach(debug.events.reversed()) { event in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(event.category.uppercased())
                                        .font(.caption2.bold()).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(event.date, style: .time)
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text(event.title).font(.subheadline.bold())
                                if !event.details.isEmpty {
                                    Text(event.details)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Chess Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { debug.clear() }.disabled(debug.events.isEmpty)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(copied ? "Copied" : "Copy log") {
                        UIPasteboard.general.string = debug.exportText
                        copied = true
                    }.disabled(debug.events.isEmpty)
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
