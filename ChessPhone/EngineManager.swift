
import Foundation
import ChessKitEngine

/// A score from the side-to-move's point of view at the position searched.
/// `confidence` is an evaluation bar, not the probability that a move is correct.
struct EngineEvaluation: Equatable {
    let centipawns: Int?
    let mate: Int?
    let depth: Int?
    let principalVariation: [String]

    var displayText: String {
        if let mate { return mate > 0 ? "Mate in \(mate)" : "Facing mate in \(abs(mate))" }
        guard let centipawns else { return "No evaluation" }
        return String(format: "%+.2f", Double(centipawns) / 100)
    }

    var confidence: Double {
        if let mate { return mate > 0 ? 1 : 0 }
        guard let centipawns else { return 0.5 }
        let pawns = Double(max(-4000, min(4000, centipawns))) / 100
        return 1 / (1 + exp(-pawns / 3))
    }

    /// Accept ordinary UCI as well as ChessKitEngine's angle-bracket diagnostic
    /// representation. The SDK formats centipawns as a Double (e.g. 25.0).
    static func parse(uci: String) -> EngineEvaluation? {
        let plain = uci.replacingOccurrences(of: "<", with: " ").replacingOccurrences(of: ">", with: " ")
        let words = plain.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.first == "info", !words.contains("lowerbound"), !words.contains("upperbound") else { return nil }
        func value(after name: String) -> String? {
            guard let i = words.firstIndex(of: name), i + 1 < words.count else { return nil }
            return words[i + 1]
        }
        if let multi = value(after: "multipv"), multi != "1" { return nil }
        guard let scoreIndex = words.firstIndex(of: "score"), scoreIndex + 2 < words.count,
              let number = Double(words[scoreIndex + 2]), number.isFinite,
              number > -1_000_000, number < 1_000_000 else { return nil }
        let score = Int(number.rounded())
        let kind = words[scoreIndex + 1]
        guard kind == "cp" || kind == "mate" else { return nil }
        let pv: [String]
        if let i = words.firstIndex(of: "pv"), i + 1 < words.count {
            pv = Array(words[(i + 1)...]).filter { Move(uci: $0) != nil }
        } else { pv = [] }
        return EngineEvaluation(centipawns: kind == "cp" ? score : nil,
                                mate: kind == "mate" ? score : nil,
                                depth: value(after: "depth").flatMap(Int.init),
                                principalVariation: pv)
    }
}

/// The bundled iOS Stockfish engine. Every abandoned search retires its engine
/// and response stream; a late bestmove can never satisfy a later request.
@MainActor
final class EngineManager {
    static let shared = EngineManager()
    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    private(set) var lastError = ""
    private(set) var isReady = false
    private(set) var lastEvaluation: EngineEvaluation?
    private(set) var restartCount = 0

    private var engine: Engine?
    private var responseTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var startTask: Task<Bool, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupToken = 0
    private var completedCleanupToken = 0
    private var commandTask: Task<Void, Never>?
    private var softDeadlineTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var pending: CheckedContinuation<String?, Never>?
    private var engineEpoch = 0
    private var searchToken = 0
    private var requestToken = 0

    /// Concurrent callers share startup. Ready check and probe have deadlines.
    func ensureStarted() async -> Bool {
        if isReady { return true }
        if let task = startTask { return await task.value }
        let task = Task { await self.performStart() }
        startTask = task
        let result = await task.value
        startTask = nil
        return result
    }

    private func performStart() async -> Bool {
        // Do not let a broken SDK shutdown leave the UI awaiting forever, and
        // never start another native engine until the previous one has stopped.
        let cleanupExpires = Date().addingTimeInterval(5)
        while completedCleanupToken < cleanupToken, Date() < cleanupExpires {
            guard !Task.isCancelled else { return false }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        guard completedCleanupToken == cleanupToken else {
            lastError = "The previous Stockfish engine has not shut down. Pause and try again."
            return false
        }
        cleanupTask = nil
        guard !Task.isCancelled else { return false }
        let hasBig = Bundle.main.url(forResource: "nn-1111cefa1111", withExtension: "nnue") != nil
        let hasSmall = Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue") != nil
        guard hasBig && hasSmall else {
            lastError = "NNUE files missing from the app bundle (big: \(hasBig), small: \(hasSmall)). Include both Resources/ networks when building."
            return false
        }
        engineEpoch += 1
        let epoch = engineEpoch
        let newEngine = Engine(type: .stockfish)
        engine = newEngine
        launchTask = Task { await newEngine.start() }
        let expires = Date().addingTimeInterval(10)
        while !(await newEngine.isRunning), Date() < expires {
            guard !Task.isCancelled, epoch == engineEpoch else { return false }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        guard epoch == engineEpoch, !Task.isCancelled else { return false }
        guard await newEngine.isRunning, let stream = await newEngine.responseStream else {
            retireEngine(reason: "Stockfish did not become ready within 10 seconds.")
            return false
        }
        responseTask = Task { [weak self] in
            for await response in stream {
                guard !Task.isCancelled else { return }
                self?.handle(response, epoch: epoch)
            }
            guard !Task.isCancelled, let self, self.engineEpoch == epoch else { return }
            self.retireEngine(reason: "Stockfish's response stream closed unexpectedly.")
        }
        if let big = Bundle.main.url(forResource: "nn-1111cefa1111", withExtension: "nnue"),
           let small = Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue") {
            await newEngine.send(command: .setoption(id: "EvalFile", value: big.path))
            await newEngine.send(command: .setoption(id: "EvalFileSmall", value: small.path))
        }
        guard epoch == engineEpoch, !Task.isCancelled else { return false }
        let probe = await search(fen: Self.startFEN, depth: 1, softLimit: 2, hardLimit: 10)
        guard epoch == engineEpoch, !Task.isCancelled else { return false }
        guard let probe, let move = Move(uci: probe), Position.start.legalMoves().contains(move) else {
            retireEngine(reason: lastError.isEmpty ? "Stockfish failed its startup test search." : lastError)
            return false
        }
        lastEvaluation = nil
        lastError = ""
        isReady = true
        return true
    }

    /// Search up to the chosen depth with a half-second time budget, then stop
    /// and return the best completed line. A hung engine is replaced once.
    func bestMove(fen: String, depth: Int = 30, skillLevel: Int = 20) async -> String? {
        requestToken += 1
        let request = requestToken
        lastError = ""
        lastEvaluation = nil
        for attempt in 0..<2 {
            guard !Task.isCancelled, request == requestToken else { return nil }
            guard await ensureStarted() else {
                if Task.isCancelled || request != requestToken { return nil }
                if attempt == 0, !lastError.contains("NNUE files missing") {
                    restartCount += 1
                    retireEngine(reason: lastError)
                    continue
                }
                return nil
            }
            guard !Task.isCancelled, request == requestToken, let current = engine else { return nil }
            let epoch = engineEpoch
            await current.send(command: .setoption(id: "Skill Level", value: String(max(0, min(skillLevel, 20)))))
            guard !Task.isCancelled, request == requestToken, epoch == engineEpoch else { return nil }
            let reply = await search(fen: fen, depth: max(1, min(depth, 30)), softLimit: 0.5, hardLimit: 5)
            guard !Task.isCancelled, request == requestToken else { return nil }
            if let reply {
                guard reply != "(none)", reply != "0000" else {
                    lastError = "The position has no legal move (the game may be over)."
                    lastEvaluation = nil
                    return nil
                }
                guard Move(uci: reply) != nil else {
                    retireEngine(reason: "Stockfish returned a malformed move.")
                    return nil
                }
                lastError = ""
                return reply
            }
            if attempt == 0 {
                restartCount += 1
                retireEngine(reason: lastError.isEmpty ? "Stockfish did not return a move." : lastError)
            }
        }
        return nil
    }

    /// Used on pause, takeback, or a new game. Cancellation never retries.
    func cancelSearch() {
        requestToken += 1
        startTask?.cancel()
        guard pending != nil || startTask != nil else { return }
        retireEngine(reason: "Search cancelled.")
    }

    private func search(fen: String, depth: Int, softLimit: TimeInterval, hardLimit: TimeInterval) async -> String? {
        guard !Task.isCancelled, let current = engine else { return nil }
        guard pending == nil else {
            retireEngine(reason: "A new search arrived before the previous search completed.")
            return nil
        }
        searchToken += 1
        let token = searchToken
        let epoch = engineEpoch
        lastEvaluation = nil
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                pending = continuation
                commandTask = Task { [weak self] in
                    guard let self, self.engineEpoch == epoch, self.searchToken == token else { return }
                    await current.send(command: .position(.fen(fen)))
                    guard !Task.isCancelled, self.engineEpoch == epoch, self.searchToken == token else { return }
                    await current.send(command: .go(depth: depth))
                }
                softDeadlineTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(softLimit * 1_000_000_000)) } catch { return }
                    guard let self, self.engineEpoch == epoch, self.searchToken == token, self.pending != nil else { return }
                    await current.send(command: .stop)
                }
                deadlineTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(hardLimit * 1_000_000_000)) } catch { return }
                    guard let self else { return }
                    guard self.engineEpoch == epoch, self.searchToken == token, self.pending != nil else { return }
                    self.retireEngine(reason: "Stockfish timed out. Restarting the engine is required.")
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.engineEpoch == epoch, self.searchToken == token, self.pending != nil else { return }
                self.retireEngine(reason: "Search cancelled.")
            }
        })
    }

    private func retireEngine(reason: String) {
        engineEpoch += 1
        isReady = false
        lastEvaluation = nil
        lastError = reason
        commandTask?.cancel()
        commandTask = nil
        softDeadlineTask?.cancel()
        softDeadlineTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        launchTask?.cancel()
        launchTask = nil
        responseTask?.cancel()
        responseTask = nil
        let abandoned = pending
        pending = nil
        let old = engine
        engine = nil
        if let old {
            let previousCleanup = cleanupTask
            cleanupToken += 1
            let token = cleanupToken
            cleanupTask = Task { [weak self] in
                await previousCleanup?.value
                await old.stop()
                self?.completedCleanupToken = token
            }
        }
        abandoned?.resume(returning: nil)
    }

    private func handle(_ response: EngineResponse, epoch: Int) {
        guard epoch == engineEpoch, pending != nil else { return }
        switch response {
        case .info:
            if let evaluation = EngineEvaluation.parse(uci: response.rawValue) { lastEvaluation = evaluation }
        case .bestmove(move: let move, ponder: _):
            let completion = pending
            pending = nil
            softDeadlineTask?.cancel()
            softDeadlineTask = nil
            deadlineTask?.cancel()
            deadlineTask = nil
            commandTask = nil
            completion?.resume(returning: move)
        default:
            break
        }
    }
}
