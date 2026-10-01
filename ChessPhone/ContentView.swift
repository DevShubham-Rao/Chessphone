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

            VStack(spacing: 6) {
                Text("Engine strength: \(vm.skillLevel)/20")
                    .font(.subheadline.bold())
                Slider(
                    value: Binding(
                        get: { Double(vm.skillLevel) },
                        set: { vm.skillLevel = max(1, min(20, Int($0.rounded()))) }
                    ),
                    in: 1...20,
                    step: 1
                )
                Text("Level 20 = full Stockfish strength")
                    .font(.caption).foregroundColor(.secondary)

                Text("Search depth: \(vm.searchDepth)")
                    .font(.subheadline.bold())
                    .padding(.top, 6)
                Slider(
                    value: Binding(
                        get: { Double(vm.searchDepth) },
                        set: { vm.searchDepth = max(1, min(30, Int($0.rounded()))) }
                    ),
                    in: 1...30,
                    step: 1
                )
                Text("Higher = stronger but slower (1-30)")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Black: number the board from my seat", isOn: $vm.blackSeatNumbering)
                    .font(.subheadline)
                    .padding(.top, 6)
            }
            .padding(.horizontal)

            if vm.hasSavedGame {
                Button { vm.resumeSavedGame() } label: {
                    Label("Resume Saved Game", systemImage: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.borderedProminent)
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
                    Button("Save") { vm.saveCurrentGame() }.font(.subheadline)
                    Button("Takeback") { vm.undo() }.font(.subheadline)
                    Button("New Game") { vm.newGame() }.font(.subheadline)
                }.padding(.horizontal)

                // Show the board from your side. Black is rotated like a real
                // opponent sitting across from White.
                BoardView(board: vm.game.board, bottomColor: vm.playerColor,
                          lastMove: vm.lastMove, selected: vm.selectedSquare,
                          targets: vm.legalTargets, checkSquare: vm.game.checkedKingSquare,
                          hapticStage: vm.hapticVisualStage,
                          seatFlipped: vm.seatFlipped)
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
