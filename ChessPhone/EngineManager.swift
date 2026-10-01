import Foundation
import ChessKitEngine

/// Wraps chesskit-engine's Stockfish: starts it once, verifies it actually
/// answers a search, and exposes a simple async "best move for this FEN" call.
///
/// Why FEN instead of "startpos + move list": the app's own rules engine
/// (ChessRules.swift) is the single source of truth for the position, and we
/// hand Stockfish that exact position every time. Stockfish and the app can
/// therefore never drift out of sync, and we only rely on `.position(.fen(_))`,
/// which the library documents.
///
/// Only these library calls are used (all confirmed by earlier builds):
/// `Engine(type:)`, `start()`, `isRunning`, `responseStream`,
/// `send(command:)` with `.setoption`, `.position(.fen)`, `.go(depth:)`, `.stop`,
/// and the `.bestmove(move:ponder:)` response.
@MainActor
final class EngineManager {
    static let shared = EngineManager()

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    /// Human-readable reason for the most recent failure ("" if none).
    private(set) var lastError: String = ""
    private(set) var isReady = false

    private var engine: Engine?
    private var responseTask: Task<Void, Never>?
    private var startTask: Task<Bool, Never>?
    private var stopTask: Task<Void, Never>?

    // Search bookkeeping
    private var pending: CheckedContinuation<String?, Never>?
    private var pendingToken = 0
    private var tokenCounter = 0
    /// Number of `bestmove` lines still owed by searches we abandoned (timeout /
    /// cancel). They are swallowed so they can't be mistaken for the next search's answer.
    private var staleBestmoves = 0

    // MARK: - Start-up

    /// Starts Stockfish if needed and confirms it can search. Safe to call many
    /// times; concurrent callers share one start-up. Returns true when ready.
    func ensureStarted() async -> Bool {
        if isReady { return true }
        if let running = startTask { return await running.value }
        let task = Task { await self.performStart() }
        startTask = task
        let ok = await task.value
        startTask = nil
        return ok
    }

    private func performStart() async -> Bool {
        lastError = ""

        if engine == nil {
            // Stockfish 17 cannot finish starting without its two NNUE nets, so
            // check the bundle first and report a precise reason on screen.
            let hasBig = Bundle.main.url(forResource: "nn-1111cefa1111", withExtension: "nnue") != nil
            let hasSmall = Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue") != nil
            guard hasBig && hasSmall else {
                return fail("NNUE files missing from the app bundle (big: \(hasBig), small: \(hasSmall)). Put both in Resources/ before building.")
            }

            let newEngine = Engine(type: .stockfish)
            await newEngine.start()

            // start() can return before Stockfish finishes its uci/isready
            // handshake (loading the ~75 MB net takes a moment). Wait up to 30 s.
            var attempts = 0
            while !(await newEngine.isRunning) && attempts < 300 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                attempts += 1
            }

            guard await newEngine.isRunning else {
                return fail("Stockfish did not start (no ready signal after 30 s).")
            }
            guard let stream = await newEngine.responseStream else {
                return fail("Stockfish started but has no response stream.")
            }

            engine = newEngine
            responseTask = Task { [weak self] in
                for await response in stream {
                    self?.handle(response)
                }
            }

            // Point Stockfish at the NNUE nets we bundled. If they aren't in the
            // app bundle we carry on anyway (the engine package may ship its own)
            // and let the test search below decide whether Stockfish really works.
            if let bigNet = Bundle.main.url(forResource: "nn-1111cefa1111", withExtension: "nnue"),
               let smallNet = Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue") {
                await newEngine.send(command: .setoption(id: "EvalFile", value: bigNet.path))
                await newEngine.send(command: .setoption(id: "EvalFileSmall", value: smallNet.path))
            } else {
                print("ChessPhone: NNUE files not found in the app bundle (see README). Trying the engine's built-in nets.")
            }
        }

        // Prove it works: ask for a depth-1 move from the start position.
        let probe = await search(fen: EngineManager.startFEN, depth: 1, timeout: 30)
        guard let move = probe, move.count >= 4, move != "(none)" else {
            return fail("Stockfish started but did not answer a test search. The NNUE files are probably missing - see README.")
        }

        isReady = true
        print("ChessPhone: Stockfish ready (test move \(move)).")
        return true
    }

    private func fail(_ message: String) -> Bool {
        lastError = message
        isReady = false
        print("ChessPhone: \(message)")
        return false
    }

    // MARK: - Searching

    /// Best move (UCI, e.g. "e7e5" or "e7e8q") for the given position, or nil on
    /// failure - in which case `lastError` explains why. There is deliberately no
    /// made-up fallback move: a broken engine is reported, not hidden.
    func bestMove(fen: String, depth: Int = 30, skillLevel: Int = 20) async -> String? {
        lastError = ""
        guard await ensureStarted() else { return nil }
        let clampedSkill = max(0, min(skillLevel, 20))
        if let engine = engine {
            // Stockfish's built-in Skill Level is 0...20. The app searches up to depth 30; the skill setting controls move quality.
            await engine.send(command: .setoption(id: "Skill Level", value: String(clampedSkill)))
        }
        let result = await search(fen: fen, depth: max(1, min(depth, 30)), timeout: 60)
        if result == nil && lastError.isEmpty {
            lastError = "Stockfish did not return a move in time."
        }
        if let move = result, move == "(none)" {
            lastError = "Stockfish says there is no legal move."
            return nil
        }
        if result != nil { lastError = "" }
        return result
    }

    /// Abandons any search in progress (e.g. when a new game starts).
    func cancelSearch() {
        guard let continuation = pending else { return }
        pending = nil
        staleBestmoves += 1
        continuation.resume(returning: nil)
        if let engine = engine {
            stopTask = Task { await engine.send(command: .stop) }
        }
    }

    private func search(fen: String, depth: Int, timeout: TimeInterval) async -> String? {
        guard let engine = engine else { return nil }

        // Make sure any earlier cancel's `stop` has been delivered first, so it
        // can't land after (and kill) the search we're about to start.
        await stopTask?.value
        stopTask = nil

        if let continuation = pending {
            // Shouldn't happen, but never leave a caller hanging.
            pending = nil
            staleBestmoves += 1
            continuation.resume(returning: nil)
            await engine.send(command: .stop)
        }

        tokenCounter += 1
        let token = tokenCounter

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // Register the continuation BEFORE sending `go`, so a fast bestmove
            // can never arrive while nobody is waiting for it.
            self.pending = continuation
            self.pendingToken = token

            Task {
                await engine.send(command: .position(.fen(fen)))
                await engine.send(command: .go(depth: depth))
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.timeoutSearch(token: token)
            }
        }
    }

    /// Soft time limit: ask Stockfish to stop. It answers with the best move found
    /// so far, which then resolves the search normally (deep searches on a phone can be slow).
    /// If it still hasn't answered 5 s later, give up and report a timeout.
    private func timeoutSearch(token: Int) {
        guard pendingToken == token, pending != nil, let engine = engine else { return }
        stopTask = Task { await engine.send(command: .stop) }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.hardTimeoutSearch(token: token)
        }
    }

    private func hardTimeoutSearch(token: Int) {
        guard pendingToken == token, let continuation = pending else { return }
        pending = nil
        staleBestmoves += 1
        lastError = "Stockfish timed out."
        isReady = false // re-verify the engine before trusting it again
        continuation.resume(returning: nil)
        if let engine = engine {
            stopTask = Task { await engine.send(command: .stop) }
        }
    }

    private func handle(_ response: EngineResponse) {
        switch response {
        case .bestmove(move: let move, ponder: _):
            if staleBestmoves > 0 {
                staleBestmoves -= 1
                return
            }
            guard let continuation = pending else { return }
            pending = nil
            continuation.resume(returning: move)
        default:
            break
        }
    }
}
