import SwiftUI
import MediaPlayer

struct ContentView: View {
    @StateObject private var vm = ChessPhoneViewModel()
    @State private var showingSettings = false
    @State private var showingPractice = false

    var body: some View {
        ZStack {
            VolumeViewContainer()
                .frame(width: 1, height: 1)
                .position(x: -100, y: -100)

            if vm.phase == .selectSide { sideSelection } else { gameScreen }
        }
        .onAppear { vm.startInputs() }
        .onDisappear { vm.stopInputs() }
        .sheet(isPresented: $showingSettings) { HapticSettingsView() }
        .fullScreenCover(isPresented: $showingPractice) { PracticeView() }
    }

    private var sideSelection: some View {
        VStack(spacing: 24) {
            Text("Choose your side").font(.title2.bold())
            HStack(spacing: 20) {
                Button("WHITE") { vm.selectColor(.white) }
                    .padding(.horizontal, 28).padding(.vertical, 16)
                    .background(Color.white).foregroundColor(.black)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black, lineWidth: 1))
                Button("BLACK") { vm.selectColor(.black) }
                    .padding(.horizontal, 28).padding(.vertical, 16)
                    .background(Color.black).foregroundColor(.white).cornerRadius(8)
            }
            Text("The engine tells you your moves with vibration. You only enter your opponent's moves. White: the engine recommends your first move right away. Black: enter White's first move, then the engine recommends your reply.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button { showingSettings = true } label: {
                Label("Vibration & Audio Settings", systemImage: "iphone.radiowaves.left.and.right")
            }.buttonStyle(.bordered)
            Button { showingPractice = true } label: {
                Label("Practice vibrations", systemImage: "graduationcap")
            }.buttonStyle(.bordered)
            Text(vm.engineStatus)
                .font(.caption)
                .foregroundColor(vm.engineStatus.contains("FAILED") ? .red : .secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }.padding()
    }

    private var gameScreen: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack {
                    Text("You: \(vm.playerColor.name)").font(.subheadline.bold())
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }.accessibilityLabel("Vibration and Audio Settings")
                    Button("New Game") { vm.newGame() }.font(.subheadline)
                }.padding(.horizontal)

                // Always draw the board from White's side (a-h left to right, rank 1 at the bottom),
                // even when playing Black, so it matches the numbers you enter.
                BoardView(board: vm.game.board, bottomColor: .white,
                          lastMove: vm.lastMove, selected: vm.selectedSquare,
                          targets: vm.legalTargets, checkSquare: vm.game.checkedKingSquare,
                          hapticStage: vm.hapticVisualStage)
                    .padding(.horizontal, 8)

                Text(vm.status).font(.headline).multilineTextAlignment(.center).padding(.horizontal)

                if !vm.recommendedMoveText.isEmpty {
                    Text("ENGINE RECOMMENDS: \(vm.recommendedMoveText)")
                        .font(.title3.monospaced().bold()).multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 4) {
                    Text(vm.phasePrompt).font(.subheadline).foregroundColor(.secondary)
                    Text("Taps: \(vm.tapCount)   (\(vm.inputPreview))")
                        .font(.title3.monospacedDigit().bold())
                }

                if vm.phase == .engineFailed {
                    Button("Retry engine") { vm.retryEngine() }.buttonStyle(.borderedProminent)
                }

                Text(vm.engineStatus)
                    .font(.caption)
                    .foregroundColor(vm.engineStatus.contains("FAILED") ? .red : .secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)

                Text("Vol up = count • Vol down = confirm • Shake = replay the engine recommendation")
                    .font(.caption2).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }.padding(.vertical, 8)
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
