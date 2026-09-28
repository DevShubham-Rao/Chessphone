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

private struct HapticSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var clarity = HapticEngine.shared.clarity
    @State private var pulseGap = HapticEngine.shared.customPulseGap
    @State private var pulseGapText = String(format: "%.2f", HapticEngine.shared.customPulseGap)

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
                Section("Pulse speed") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Seconds between pulses")
                            Spacer()
                            TextField("0.80", text: $pulseGapText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 75)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { savePulseGap() }
                        }
                        Slider(value: $pulseGap, in: 0.10...5.00, step: 0.05)
                            .onChange(of: pulseGap) { newValue in
                                pulseGapText = String(format: "%.2f", newValue)
                                HapticEngine.shared.customPulseGap = newValue
                            }
                        HStack {
                            Text("0.10 = fastest").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("5.00 = slowest").font(.caption).foregroundColor(.secondary)
                        }
                        Text("Set this much higher if you need more time to count each vibration. Example: 2.00 means two seconds between pulses.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Section("Easy pattern") {
                    Text("LONG START → count the highlighted file → pause → count the highlighted rank → LONG SWITCH → count the destination file → pause → count the destination rank → TWO LONG DONE.")
                    Text("The board highlights the same file or rank as each vibration. The current one is bright; completed ones stay lightly highlighted.")
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

    private func savePulseGap() {
        let cleaned = pulseGapText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned) else {
            pulseGapText = String(format: "%.2f", pulseGap)
            return
        }
        let clamped = min(max(value, 0.10), 5.00)
        pulseGap = clamped
        pulseGapText = String(format: "%.2f", clamped)
        HapticEngine.shared.customPulseGap = clamped
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
