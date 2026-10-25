import XCTest
@testable import ChessPhone

final class SessionJournalTests: XCTestCase {
    @MainActor
    func testRecentHistoryHasExactlyTheLast300Events() throws {
        try withJournal { journal in
            for number in 0..<340 { journal.record(.info, "event \(number)") }
            XCTAssertEqual(journal.events.count, 300)
            XCTAssertEqual(journal.events.first?.message, "event 40")
            XCTAssertEqual(journal.events.last?.message, "event 339")
            XCTAssertNil(journal.sessionFolder, "Recording is opt-in.")
            XCTAssertTrue(journal.exportURLs().isEmpty)
        }
    }

    @MainActor
    func testDiskLogRetainsFullHistoryAndDoesNotDuplicateOnResume() throws {
        try withJournal(recording: true) { journal in
            let folder = try XCTUnwrap(journal.sessionFolder)
            for number in 0..<340 { journal.record(.move, "move \(number)") }
            XCTAssertEqual(journal.events.count, 300)
            journal.recordingEnabled = false
            journal.record(.info, "while recording off 1")
            journal.record(.info, "while recording off 2")
            journal.recordingEnabled = true
            journal.record(.info, "after recording resumed")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let bytes = try Data(contentsOf: folder.appendingPathComponent("events.jsonl"))
            let events = try bytes.split(separator: 0x0A).map { try decoder.decode(SessionEvent.self, from: Data($0)) }
            XCTAssertEqual(events.count, 344, "Starting event + 340 moves + three later events.")
            XCTAssertEqual(Set(events.map(\.sequence)).count, events.count)
            XCTAssertEqual(events.first?.kind, .sessionStarted)
            XCTAssertEqual(events.last?.message, "after recording resumed")
            XCTAssertTrue(journal.storageError.isEmpty)
        }
    }

    @MainActor
    func testSnapshotDoesNotEnterEventFileAndPGNIsReplaced() throws {
        try withJournal(recording: true) { journal in
            let folder = try XCTUnwrap(journal.sessionFolder)
            let eventURL = folder.appendingPathComponent("events.jsonl")
            let before = try Data(contentsOf: eventURL)
            let count = journal.events.count
            journal.publish(SessionSnapshot(status: "SNAPSHOT_ONLY", paused: false,
                                            playerColor: "White", sideToMove: "White",
                                            fen: Position.start.fen, moves: []))
            XCTAssertEqual(journal.latestSnapshot?.status, "SNAPSHOT_ONLY")
            XCTAssertEqual(journal.events.count, count)
            XCTAssertEqual(try Data(contentsOf: eventURL), before)
            journal.writePGN("[Result \"*\"]\n\n1. e4 *")
            journal.writePGN("[Result \"*\"]\n\n1. e4 e5 *")
            let pgnURL = folder.appendingPathComponent("game.pgn")
            XCTAssertEqual(try String(contentsOf: pgnURL, encoding: .utf8), "[Result \"*\"]\n\n1. e4 e5 *")
            XCTAssertTrue(journal.exportURLs().contains(pgnURL))
        }
    }

    @MainActor
    func testFramesRequireExplicitOptInAndLabelsCannotEscapeFramesDirectory() throws {
        try withJournal(recording: true) { journal in
            let folder = try XCTUnwrap(journal.sessionFolder)
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
            journal.saveFrame(jpeg, label: "move")
            XCTAssertFalse(journal.exportURLs().contains { $0.pathExtension == "jpg" })
            journal.saveKeyFrames = true
            journal.saveFrame(jpeg, label: "../../outside/board")
            let photos = journal.exportURLs().filter { $0.pathExtension == "jpg" }
            XCTAssertEqual(photos.count, 1)
            XCTAssertEqual(photos.first?.deletingLastPathComponent().path, folder.appendingPathComponent("frames", isDirectory: true).path)
            journal.recordingEnabled = false
            journal.saveFrame(jpeg, label: "must-not-save")
            XCTAssertEqual(journal.exportURLs().filter { $0.pathExtension == "jpg" }.count, 1)
        }
    }

    @MainActor
    func testEventDetailsRedactQueryKeysAndBearerTokens() throws {
        try withJournal { journal in
            journal.record(.problem, "GET https://example.invalid/read?key=private-token&mode=board",
                           details: ["authorization": "Bearer private-access-token",
                                     "url": "https://example.invalid/?api_key=private-key"])
            let event = try XCTUnwrap(journal.events.last)
            XCTAssertFalse(event.message.contains("private-token"))
            XCTAssertTrue(event.message.contains("&mode=board"))
            XCTAssertEqual(event.details["authorization"], "Bearer <redacted>")
            XCTAssertFalse(try XCTUnwrap(event.details["url"]).contains("private-key"))
        }
    }

    @MainActor
    private func withJournal(recording: Bool = false, _ body: (SessionJournal) throws -> Void) throws {
        let journal = SessionJournal.shared
        let oldRecording = journal.recordingEnabled
        let oldFrames = journal.saveKeyFrames
        journal.finishSession()
        journal.recordingEnabled = false
        journal.saveKeyFrames = false
        journal.startSession(playerColor: .white, initialFEN: Position.start.fen)
        journal.recordingEnabled = recording
        defer {
            let generatedFolder = journal.sessionFolder
            journal.finishSession()
            journal.recordingEnabled = false
            journal.saveKeyFrames = oldFrames
            if let generatedFolder {
                // Only the unique folder generated for this test is removed.
                try? FileManager.default.removeItem(at: generatedFolder)
            }
            journal.recordingEnabled = oldRecording
        }
        try body(journal)
    }
}
