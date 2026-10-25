import Foundation
import Combine

struct SessionEvent: Identifiable, Codable {
    enum Kind: String, Codable {
        case sessionStarted, move, suggestion, problem, frame, paused, resumed
        case undo, gameOver, recovery, info

        var isMove: Bool { self == .move || self == .suggestion }
        var isProblem: Bool { self == .problem || self == .recovery }
    }

    let id: UUID
    let sequence: Int
    let timestamp: Date
    let kind: Kind
    let message: String
    let details: [String: String]
}

/// Current state for observers. Snapshots deliberately never enter the event log.
struct SessionSnapshot {
    let timestamp = Date()
    let status: String
    let paused: Bool
    let playerColor: String
    let sideToMove: String
    let fen: String
    let moves: [String]
    var suggestion: String? = nil
    var evaluation: String? = nil
    var confidence: Double? = nil
    var estimatedCostUSD: Double = 0
    var spendingCapUSD: Double = 10
    var visionModel: String = "Gemini"
    var precheckEnabled: Bool = true
}

/// A native, local event bus. Published values deliver recent history to new
/// observers immediately. Optional run files retain the entire session history.
@MainActor
final class SessionJournal: ObservableObject {
    static let shared = SessionJournal()
    private static let memoryLimit = 300

    @Published private(set) var events: [SessionEvent] = []
    @Published private(set) var latestSnapshot: SessionSnapshot?
    @Published private(set) var sessionFolder: URL?
    @Published private(set) var storageError = ""
    @Published var recordingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(recordingEnabled, forKey: "ChessPhone.session.recording")
            if recordingEnabled && !oldValue && active {
                openRunFolderIfNeeded()
                flushRecentEvents()
                if !latestPGN.isEmpty { writePGN(latestPGN) }
            }
        }
    }
    @Published var saveKeyFrames: Bool {
        didSet { UserDefaults.standard.set(saveKeyFrames, forKey: "ChessPhone.session.frames") }
    }

    private var active = false
    private var metadata: [String: String] = [:]
    private var latestPGN = ""
    private var nextSequence = 0
    private var lastWrittenSequence = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private init() {
        recordingEnabled = UserDefaults.standard.bool(forKey: "ChessPhone.session.recording")
        saveKeyFrames = UserDefaults.standard.bool(forKey: "ChessPhone.session.frames")
    }

    func startSession(playerColor: PieceColor, initialFEN: String) {
        events.removeAll()
        latestSnapshot = nil
        sessionFolder = nil
        storageError = ""
        nextSequence = 0
        lastWrittenSequence = 0
        latestPGN = ""
        active = true
        metadata = [
            "schemaVersion": "1",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "playerColor": playerColor.name,
            "initialFEN": initialFEN
        ]
        if recordingEnabled { openRunFolderIfNeeded() }
        record(.sessionStarted, "New game: you are \(playerColor.name).", details: ["initialFEN": initialFEN])
    }

    func finishSession() {
        guard active else { return }
        record(.info, "Session finished.")
        active = false
    }

    func record(_ kind: SessionEvent.Kind, _ message: String, details: [String: String] = [:]) {
        nextSequence += 1
        let event = SessionEvent(id: UUID(), sequence: nextSequence, timestamp: Date(), kind: kind,
                                 message: redacted(message), details: details.mapValues { redacted($0) })
        events.append(event)
        if events.count > Self.memoryLimit { events.removeFirst(events.count - Self.memoryLimit) }
        if recordingEnabled && active {
            openRunFolderIfNeeded()
            flushRecentEvents()
        }
    }

    func publish(_ snapshot: SessionSnapshot) {
        latestSnapshot = snapshot
    }

    /// Keep the current PGN available even when recording is enabled mid-game.
    func writePGN(_ pgn: String) {
        latestPGN = pgn
        guard recordingEnabled && active else { return }
        openRunFolderIfNeeded()
        guard let folder = sessionFolder else { return }
        do {
            try Data(pgn.utf8).write(to: folder.appendingPathComponent("game.pgn"), options: .atomic)
        } catch { storageError = "Could not save PGN: \(error.localizedDescription)" }
    }

    /// Photos can include people and rooms. They are saved only after an explicit toggle.
    func saveFrame(_ jpeg: Data, label: String) {
        guard recordingEnabled, saveKeyFrames, active, !jpeg.isEmpty else { return }
        openRunFolderIfNeeded()
        guard let folder = sessionFolder else { return }
        do {
            let frames = folder.appendingPathComponent("frames", isDirectory: true)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            let safeLabel = String(label.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-"
            }.prefix(48))
            let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
            let name = "\(stamp)-\(safeLabel)-\(UUID().uuidString.prefix(8)).jpg"
            try jpeg.write(to: frames.appendingPathComponent(name), options: .atomic)
        } catch { storageError = "Could not save frame: \(error.localizedDescription)" }
    }

    /// Share actual files: this works with Files and share targets that reject folders.
    /// No API keys, training images, or app preferences are included.
    func exportURLs() -> [URL] {
        guard let folder = sessionFolder else { return [] }
        var urls = ["session.json", "events.jsonl", "game.pgn"].map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let frames = folder.appendingPathComponent("frames", isDirectory: true)
        if let photos = try? FileManager.default.contentsOfDirectory(at: frames, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: photos.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return urls
    }

    private func openRunFolderIfNeeded() {
        guard sessionFolder == nil, active, recordingEnabled else { return }
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let folder = documents.appendingPathComponent("ChessPhone Sessions", isDirectory: true)
                .appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(metadata).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
            sessionFolder = folder
            flushRecentEvents()
            if !latestPGN.isEmpty {
                try Data(latestPGN.utf8).write(to: folder.appendingPathComponent("game.pgn"), options: .atomic)
            }
        } catch { storageError = "Could not create session folder: \(error.localizedDescription)" }
    }

    private func flushRecentEvents() {
        for event in events where event.sequence > lastWrittenSequence {
            if !append(event) { break }
        }
    }

    @discardableResult
    private func append(_ event: SessionEvent) -> Bool {
        guard let folder = sessionFolder else { return false }
        guard event.sequence > lastWrittenSequence else { return true }
        do {
            let url = folder.appendingPathComponent("events.jsonl")
            var data = try encoder.encode(event)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
            lastWrittenSequence = event.sequence
            return true
        } catch {
            storageError = "Could not append session event: \(error.localizedDescription)"
            return false
        }
    }

    private func redacted(_ text: String) -> String {
        var result = String(text.prefix(12_000))
        for pattern in ["(?i)([?&](?:key|api_key|apikey)=)[^&\\s]+", "(?i)(Bearer\\s+)[A-Za-z0-9_.-]+"] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                        withTemplate: "$1<redacted>")
            }
        }
        return result
    }
}
