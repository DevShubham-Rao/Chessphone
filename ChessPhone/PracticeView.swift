import SwiftUI

/// Practice mode: the phone vibrates a random move (using your current vibration
/// settings), you work out the squares in your head, then reveal the answer on screen.
///
/// Volume UP   = replay the vibration
/// Volume DOWN = show the answer, then the next random move
@MainActor
final class PracticeViewModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case realistic, anySquares
        var id: String { rawValue }
        var title: String { self == .realistic ? "Real chess moves" : "Any squares" }
    }

    enum Stage { case ready, guessing, revealed }

    @Published private(set) var stage: Stage = .ready
    @Published private(set) var move: Move?
    @Published private(set) var board: [Piece?] = ChessGame().board
    @Published private(set) var practiced = 0
    @Published private(set) var isPlaying = false
    @Published var source: Source = .realistic

    private var savedUp: (() -> Void)?
    private var savedDown: (() -> Void)?

    // MARK: - Volume buttons

    func attach() {
        let handler = VolumeButtonHandler.shared
        savedUp = handler.onVolumeUp
        savedDown = handler.onVolumeDown
        handler.onVolumeUp = { [weak self] in
            Task { @MainActor in self?.replay() }
        }
        handler.onVolumeDown = { [weak self] in
            Task { @MainActor in self?.advance() }
        }
    }

    func detach() {
        let handler = VolumeButtonHandler.shared
        handler.onVolumeUp = savedUp
        handler.onVolumeDown = savedDown
        HapticEngine.shared.cancel()
        SpeechEngine.shared.stop()
    }

    // MARK: - Flow

    /// Volume down: ready -> play, guessing -> reveal, revealed -> next move.
    func advance() {
        switch stage {
        case .ready, .revealed: newMove()
        case .guessing: reveal()
        }
    }

    func newMove() {
        let picked = randomMove()
        move = picked.move
        board = picked.board
        stage = .guessing
        practiced += 1
        playCurrent()
    }

    func replay() {
        if move == nil { newMove() } else { playCurrent() }
    }

    func reveal() {
        guard let move = move else { return }
        stage = .revealed
        let speech = SpeechEngine.shared
        if speech.enabled {
            HapticEngine.shared.cancel()
            speech.speak(speech.phrase(for: move, piece: board[move.from]?.type, captured: board[move.to]?.type))
        }
    }

    private func playCurrent() {
        guard let move = move else { return }
        SpeechEngine.shared.stop()
        isPlaying = true
        HapticEngine.shared.playMove(
            fromFile: Square.file(move.from) + 1,
            fromRank: Square.rank(move.from) + 1,
            toFile: Square.file(move.to) + 1,
            toRank: Square.rank(move.to) + 1,
            promotion: move.promotion?.promotionCode ?? 0,
            suffix: .none
        ) { [weak self] in
            self?.isPlaying = false
        }
    }

    // MARK: - Random moves

    private func randomMove() -> (move: Move, board: [Piece?]) {
        switch source {
        case .anySquares:
            let from = Int.random(in: 0..<64)
            var to = Int.random(in: 0..<64)
            while to == from { to = Int.random(in: 0..<64) }
            // Now and then include a promotion so the promotion signal gets practice too.
            let promotion: PieceType? = Int.random(in: 0..<7) == 0
                ? [PieceType.queen, .rook, .bishop, .knight].randomElement()
                : nil
            return (Move(from: from, to: to, promotion: promotion),
                    Array(repeating: nil, count: 64))

        case .realistic:
            var game = ChessGame()
            let plies = Int.random(in: 0...40)
            for _ in 0..<plies {
                guard game.outcome == nil, let m = game.legalMoves().randomElement() else { break }
                game.play(m)
            }
            if let m = game.legalMoves().randomElement() {
                return (m, game.board)
            }
            let start = ChessGame()
            return (Move(from: 12, to: 28, promotion: nil), start.board)   // e2e4
        }
    }
}

struct PracticeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = PracticeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text("Feel the vibration, work out the move in your head, then reveal the answer.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)

                    Picker("Moves", selection: $vm.source) {
                        ForEach(PracticeViewModel.Source.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    content

                    controls

                    if vm.practiced > 0 {
                        Text("Moves practiced: \(vm.practiced)")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    Text("Vol up = replay vibration • Vol down = show answer, then next move")
                        .font(.caption2).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Practice vibrations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { vm.attach() }
        .onDisappear { vm.detach() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.stage {
        case .ready:
            Text("Tap \"Play a random move\" to start.")
                .font(.headline).padding(.top, 30)

        case .guessing:
            VStack(spacing: 8) {
                Text(vm.isPlaying ? "Vibrating..." : "What was the move?")
                    .font(.title2.bold())
                Text("FROM column, FROM row, then TO column, TO row.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            .padding(.vertical, 30)

        case .revealed:
            if let move = vm.move {
                VStack(spacing: 6) {
                    Text("\(Square.name(move.from)) → \(Square.name(move.to))")
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                    Text("Numbers: \(Square.file(move.from) + 1),\(Square.rank(move.from) + 1) → \(Square.file(move.to) + 1),\(Square.rank(move.to) + 1)")
                        .font(.title3.monospacedDigit())
                    if let promotion = move.promotion {
                        Text("Promotes to \(promotionName(promotion)) (\(promotion.promotionCode) pulses)")
                            .font(.subheadline)
                    }
                }
                BoardView(board: vm.board, bottomColor: .white,
                          lastMove: move, selected: nil, targets: [],
                          checkSquare: nil, hapticStage: .idle)
                    .padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch vm.stage {
        case .ready:
            Button("Play a random move") { vm.newMove() }
                .buttonStyle(.borderedProminent).controlSize(.large)

        case .guessing:
            HStack(spacing: 12) {
                Button("Replay vibration") { vm.replay() }.buttonStyle(.bordered)
                Button("Show answer") { vm.reveal() }.buttonStyle(.borderedProminent)
            }.controlSize(.large)

        case .revealed:
            HStack(spacing: 12) {
                Button("Replay vibration") { vm.replay() }.buttonStyle(.bordered)
                Button("Next random move") { vm.newMove() }.buttonStyle(.borderedProminent)
            }.controlSize(.large)
        }
    }

    private func promotionName(_ type: PieceType) -> String {
        switch type {
        case .queen: return "Queen"
        case .rook: return "Rook"
        case .bishop: return "Bishop"
        case .knight: return "Knight"
        default: return "?"
        }
    }
}
