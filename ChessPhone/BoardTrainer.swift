import SwiftUI
import PhotosUI

/// A portable, versioned collection of photos paired with corrected board labels.
struct BoardTrainingExample: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var imageBase64: String
    var rows: [String] // rank 8 to rank 1, file a to file h
}

@MainActor
final class BoardTrainingStore: ObservableObject {
    static let shared = BoardTrainingStore()
    @Published private(set) var examples: [BoardTrainingExample] = []
    private let fileURL: URL

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("chess-training-data.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([BoardTrainingExample].self, from: data) {
            examples = decoded
        }
    }

    func add(image: Data, rows: [String]) throws {
        guard rows.count == 8, rows.allSatisfy({ $0.count == 8 }) else {
            throw VisionError.malformedReading("training board must have 8 rows of 8 squares")
        }
        examples.append(BoardTrainingExample(id: UUID(), createdAt: Date(), imageBase64: image.base64EncodedString(), rows: rows))
        try persist()
    }

    func exportURL() throws -> URL {
        let export = fileURL.deletingLastPathComponent().appendingPathComponent("ChessPhone-Training-Data.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(examples).write(to: export, options: .atomic)
        return export
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(examples).write(to: fileURL, options: .atomic)
    }
}

/// Trainer workflow: import a board photo, ask Gemini for a first draft, correct it square by square,
/// then save the photo and labels for export and future model training.
struct BoardTrainerView: View {
    @State private var photo: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var rows = Array(repeating: "........", count: 8)
    @State private var selectedSymbol = "."
    @State private var status = "Choose a clear photo of the whole physical board."
    @State private var busy = false
    @State private var exportURL: URL?
    @ObservedObject private var store = BoardTrainingStore.shared
    private let symbols = [".", "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]

    var body: some View {
        Form {
            Section("1. Choose a board photo") {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Choose Photo", systemImage: "photo")
                }
                Button("Read draft with Gemini") { readDraft() }
                    .disabled(imageData == nil || busy)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Section("2. Correct the labels") {
                Picker("Piece to place", selection: $selectedSymbol) {
                    ForEach(symbols, id: \.self) { Text(symbolName($0)).tag($0) }
                }
                VStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<8, id: \.self) { col in
                                Button {
                                    setSquare(row: row, col: col, symbol: selectedSymbol)
                                } label: {
                                    Text(String(Array(rows[row])[col]))
                                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                                        .background((row + col).isMultiple(of: 2) ? Color.brown.opacity(0.15) : Color.brown.opacity(0.35))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("Rows are rank 8 at the top through rank 1 at the bottom; files a to h go left to right.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save corrected example") { saveExample() }
                    .disabled(imageData == nil || busy)
            }
            Section("Saved training data") {
                Text("\(store.examples.count) labeled photo(s) saved on this device.")
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Export training data", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Prepare export") {
                        do { exportURL = try store.exportURL() }
                        catch { status = "Export failed: \(error.localizedDescription)" }
                    }
                    .disabled(store.examples.isEmpty)
                }
                Text("The export contains each photo and its corrected 8×8 labels. It preserves your examples for future app versions; it does not itself train a local model yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Board Trainer")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photo) { item in loadPhoto(item) }
    }

    private func symbolName(_ symbol: String) -> String {
        [".": "Empty", "P": "White pawn", "N": "White knight", "B": "White bishop", "R": "White rook", "Q": "White queen", "K": "White king", "p": "Black pawn", "n": "Black knight", "b": "Black bishop", "r": "Black rook", "q": "Black queen", "k": "Black king"][symbol] ?? symbol
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self), UIImage(data: data) != nil else {
                    status = "Could not load that photo."; return
                }
                imageData = data
                rows = Array(repeating: "........", count: 8)
                status = "Photo loaded. Read a draft, then correct every square that is wrong."
            } catch { status = "Photo load failed: \(error.localizedDescription)" }
        }
    }

    private func readDraft() {
        guard let imageData, let image = UIImage(data: imageData) else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let scan = try await VisionCoordinator.shared.readBoard(from: image, playerColor: .white)
                rows = (0..<8).map { row in
                    String((0..<8).map { col -> Character in
                        guard let piece = scan.squares[Square.index(file: col, rank: 7 - row)] else { return "." }
                        let letter: String
                        switch piece.type { case .pawn: letter = "p"; case .knight: letter = "n"; case .bishop: letter = "b"; case .rook: letter = "r"; case .queen: letter = "q"; case .king: letter = "k" }
                        return piece.color == .white ? Character(letter.uppercased()) : Character(letter)
                    })
                }
                status = "Draft read. Review and correct the board before saving."
            } catch { status = "Draft failed: \(error.localizedDescription). You can still label the board manually." }
        }
    }

    private func setSquare(row: Int, col: Int, symbol: String) {
        var chars = Array(rows[row]); chars[col] = Character(symbol); rows[row] = String(chars)
    }

    private func saveExample() {
        guard let imageData else { return }
        do {
            let normalized = try ImagePreprocessor.jpegData(from: UIImage(data: imageData)!)
            try store.add(image: normalized, rows: rows)
            status = "Saved. Check every square before adding more examples."
            exportURL = nil
        } catch { status = "Could not save example: \(error.localizedDescription)" }
    }
}

enum ChessRecognitionMode: String, CaseIterable, Identifiable {
    case gemini
    case local
    var id: String { rawValue }
    var title: String { self == .gemini ? "Gemini" : "My local model" }
    static var localModelInstalled: Bool { Bundle.main.url(forResource: "ChessBoardClassifier", withExtension: "mlmodelc") != nil }
}
