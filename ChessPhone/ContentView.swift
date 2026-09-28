import SwiftUI
import MediaPlayer

struct ContentView: View {
    @StateObject private var vm = ChessPhoneViewModel()
    @State private var showingSettings = false

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
            Text("White: the engine recommends your move with vibration. You then enter your opponent's move.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button { showingSettings = true } label: {
                Label("Vibration Settings", systemImage: "iphone.radiowaves.left.and.right")
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
                    }.accessibilityLabel("Vibration Settings")
                    Button("New Game") { vm.newGame() }.font(.subheadline)
                }.padding(.horizontal)

                BoardView(board: vm.game.board, bottomColor: vm.playerColor,
                          lastMove: vm.lastMove, selected: vm.selectedSquare,
                          targets: vm.legalTargets, checkSquare: vm.game.checkedKingSquare)
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

private struct HapticSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var clarity = HapticEngine.shared.clarity

    var body: some View {
        NavigationStack {
            Form {
                Section("Move vibration") {
                    Picker("Clarity", selection: $clarity) {
                        ForEach(HapticEngine.Clarity.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }.pickerStyle(.segmented)
                    .onChange(of: clarity) { newValue in
                        HapticEngine.shared.setClarity(newValue)
                    }
                    Button("Test vibration pattern") { HapticEngine.shared.testPattern() }
                }
                Section("Easy pattern") {
                    Text("A strong buzz marks the start of each coordinate. Count the medium buzzes. Two strong buzzes separate FROM from TO.")
                    Text("Easy mode deliberately uses longer pauses so each number is easier to count.")
                        .foregroundColor(.secondary)
                }
                Section {
                    Text("Recommended: Easy").font(.headline)
                    Text("Use Fast only after you are comfortable reading the pattern.").foregroundColor(.secondary)
                }
            }
            .navigationTitle("Vibration Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { HapticEngine.shared.cancel(); dismiss() }
                }
            }
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
