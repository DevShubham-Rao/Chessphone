import SwiftUI
import MediaPlayer

struct ContentView: View {
    @StateObject private var vm = ChessPhoneViewModel()

    var body: some View {
        ZStack {
            // Hidden MPVolumeView, required so the app is allowed to
            // read/drive system volume at all. Placed off-screen.
            VolumeViewContainer()
                .frame(width: 1, height: 1)
                .position(x: -100, y: -100)

            if vm.phase == .selectSide {
                sideSelection
            } else {
                gameScreen
            }
        }
        .onAppear { vm.startInputs() }
        .onDisappear { vm.stopInputs() }
    }

    // MARK: - Side selection

    private var sideSelection: some View {
        VStack(spacing: 24) {
            Text("Choose your side")
                .font(.title2.bold())
            HStack(spacing: 20) {
                Button("WHITE") { vm.selectColor(.white) }
                    .padding(.horizontal, 28).padding(.vertical, 16)
                    .background(Color.white)
                    .foregroundColor(.black)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black, lineWidth: 1))
                Button("BLACK") { vm.selectColor(.black) }
                    .padding(.horizontal, 28).padding(.vertical, 16)
                    .background(Color.black)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            Text("White moves first. If you pick Black, the engine opens.")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(vm.engineStatus)
                .font(.caption)
                .foregroundColor(vm.engineStatus.contains("FAILED") ? .red : .secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - Game screen

    private var gameScreen: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack {
                    Text("You: \(vm.playerColor.name)")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("New Game") { vm.newGame() }
                        .font(.subheadline)
                }
                .padding(.horizontal)

                BoardView(
                    board: vm.game.board,
                    bottomColor: vm.playerColor,
                    lastMove: vm.lastMove,
                    selected: vm.selectedSquare,
                    targets: vm.legalTargets,
                    checkSquare: vm.game.checkedKingSquare
                )
                .padding(.horizontal, 8)

                Text(vm.status)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(spacing: 4) {
                    Text(vm.phasePrompt)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Taps: \(vm.tapCount)   (\(vm.inputPreview))")
                        .font(.title3.monospacedDigit().bold())
                }

                if vm.phase == .engineFailed {
                    Button("Retry engine") { vm.retryEngine() }
                        .buttonStyle(.borderedProminent)
                }

                Text(vm.engineStatus)
                    .font(.caption)
                    .foregroundColor(vm.engineStatus.contains("FAILED") ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text("Vol up = count, vol down = confirm (0 taps = cancel), shake = repeat engine move")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
    }
}

struct VolumeViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        MPVolumeSetter.volumeView = view
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
