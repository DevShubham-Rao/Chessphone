import SwiftUI
import MediaPlayer

struct ContentView: View {
    @StateObject private var vm = ChessPhoneViewModel()
    @ObservedObject private var vision = VisionCoordinator.shared
    @State private var showingSettings = false
    @State private var showingPractice = false
    @State private var showingDebug = false
    @State private var showingDashboard = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            VolumeViewContainer()
                .frame(width: 1, height: 1)
                .position(x: -100, y: -100)

            if vm.phase == .selectSide { sideSelection } else { gameScreen }
        }
        .onAppear { vm.startInputs(); vision.warmUp() }
        .onDisappear { vm.stopInputs(); vision.shutdown() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                vm.pauseSession()
                vm.stopInputs()
                vision.shutdown()
            } else if newPhase == .active {
                vm.startInputs()
                if !vm.sessionPaused { vision.warmUp() }
            }
        }
        .sheet(isPresented: $showingSettings) { HapticSettingsView() }
        .fullScreenCover(isPresented: $showingPractice) { PracticeView() }
        .sheet(isPresented: $showingDebug) { ChessDebugView() }
        .sheet(isPresented: $showingDashboard) { SessionDashboardView(vm: vm) }
    }

    private var sideSelection: some View {
        ScrollView { VStack(spacing: 24) {
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
                Text("Maximum depth 1–30; searches use a 0.5-second thinking budget")
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
            Button { showingDashboard = true } label: {
                Label("Command Center / Load FEN", systemImage: "slider.horizontal.3")
            }.buttonStyle(.bordered)
            Text(vm.engineStatus)
                .font(.caption)
                .foregroundColor(vm.engineStatus.contains("FAILED") ? .red : .secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }.padding() }
    }

    private var gameScreen: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack {
                    Text(vm.sessionStatus).font(.subheadline.bold())
                    Spacer()
                    Button(vm.sessionPaused || vision.isBudgetPaused ? "Resume" : "Pause") {
                        if vm.sessionPaused || vision.isBudgetPaused { vm.resumeSession() } else { vm.pauseSession() }
                    }.buttonStyle(.bordered)
                    Button { showingDashboard = true } label: {
                        Label("Command Center", systemImage: "slider.horizontal.3")
                    }
                }.padding(.horizontal)
                HStack {
                    Text("You: \(vm.playerColor.name)").font(.subheadline.bold())
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }.accessibilityLabel("Vibration and Audio Settings")
                    Button { showingDebug = true } label: {
                        Image(systemName: "ladybug")
                    }.accessibilityLabel("Chess Debug Log")
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
                    if vm.suggestionMove != nil {
                        Text(vm.suggestionEvaluationText).font(.caption)
                        Button("I played this move") { vm.confirmSuggestedMove() }
                            .buttonStyle(.bordered)
                    }
                }

                VStack(spacing: 4) {
                    Text(vm.phasePrompt).font(.subheadline).foregroundColor(.secondary)
                    Text("Taps: \(vm.tapCount)   (\(vm.inputPreview))")
                        .font(.title3.monospacedDigit().bold())
                }

                if vm.phase == .engineFailed {
                    Button("Retry engine") { vm.retryEngine() }.buttonStyle(.borderedProminent)
                }

                HStack(spacing: 12) {
                    Button("Count") { vm.handleVolumeUp(manual: true) }
                    Button("Confirm") { vm.handleVolumeDown() }
                    Button("Replay") { vm.handleShakeRepeat() }
                }
                .buttonStyle(.bordered)
                .disabled(vm.sessionPaused)
                .accessibilityElement(children: .contain)

                if vision.enabled && vm.phase == .opponentSourceColumn {
                    Button("Check board now") { vm.requestBoardScan() }
                        .buttonStyle(.borderedProminent)
                }

                Text(vm.engineStatus)
                    .font(.caption)
                    .foregroundColor(vm.engineStatus.contains("FAILED") ? .red : .secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)

                if vision.enabled && !vm.scanStatus.isEmpty {
                    Text(vm.scanStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Text(vision.enabled
                     ? (vision.sourceKind == .glasses
                        ? "Board watch ON: move the pieces on the board • Shake = replay recommendation"
                        : "Camera test mode: tap Check board now • Shake = replay recommendation")
                     : "Vol up = count • Vol down = confirm • Shake = replay the engine recommendation")
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
        DispatchQueue.main.async { VolumeButtonHandler.shared.reconnect() }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        MPVolumeSetter.volumeView = uiView
    }
}
