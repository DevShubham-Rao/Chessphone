import SwiftUI

/// Vibration + audio settings. The vibration sequence is a list of steps you can
/// reorder, delete, add to and edit (pause lengths, gaps between pulses, buzz lengths, strength).
struct HapticSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = HapticEngine.shared.pattern
    @ObservedObject private var speech = SpeechEngine.shared

    var body: some View {
        NavigationStack {
            List {
                sequenceSection
                Section("Presets") {
                    Button("Load Easy preset (slow, default)") { pattern = .easy }
                    Button("Load Fast preset") { pattern = .fast }
                }
                testSection
                audioSection
                VisionSettingsSection()
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Vibration & Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        HapticEngine.shared.cancel()
                        SpeechEngine.shared.stop()
                        dismiss()
                    }
                }
            }
            .onChange(of: pattern) { newValue in
                HapticEngine.shared.pattern = newValue
            }
        }
    }

    // MARK: - Sequence editor

    private var sequenceSection: some View {
        Section {
            ForEach($pattern.steps) { $step in
                StepEditor(step: $step)
            }
            .onMove { pattern.steps.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { pattern.steps.remove(atOffsets: $0) }

            Menu {
                ForEach(PatternStep.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) { pattern.steps.append(PatternStep.fresh(kind)) }
                }
            } label: {
                Label("Add step at the end", systemImage: "plus.circle")
            }
        } header: {
            Text("Vibration sequence")
        } footer: {
            Text("Plays top to bottom. Example: Pause 1.0 s, then FROM column pulses with 0.5 s between them, then Pause 1.0 s, then an Extra buzz of 0.1 s. Tap Edit (top left) to reorder or delete steps. A Pause right after a skipped step (for example Promotion on a normal move) is skipped too.")
        }
    }

    private var testSection: some View {
        Section("Try it") {
            Button("Test vibration (e2 to e4)") { HapticEngine.shared.testPattern() }
            Button("Test with promotion") { HapticEngine.shared.testPattern(withPromotion: true) }
            Button("Stop") { HapticEngine.shared.cancel(); SpeechEngine.shared.stop() }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section {
            Toggle("Speak the moves", isOn: $speech.enabled)
            if speech.enabled {
                Picker("When", selection: $speech.timing) {
                    ForEach(SpeechEngine.Timing.allCases) { Text($0.title).tag($0) }
                }
                Picker("Wording", selection: $speech.style) {
                    ForEach(SpeechEngine.Style.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Say the piece name", isOn: $speech.includePieceName)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech speed").font(.subheadline)
                    Slider(value: $speech.rate, in: 0.2...0.7, step: 0.01)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech loudness").font(.subheadline)
                    Slider(value: $speech.volume, in: 0.1...1.0, step: 0.05)
                }
                Button("Test voice") { SpeechEngine.shared.speakSample() }
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Spoken moves play through the phone speaker or headphones, even with the silent switch on. The volume buttons are used for tapping in moves, so the app keeps system volume at a fixed middle level - use \"Speech loudness\" to go quieter, or headphones for more.")
        }
    }
}

// MARK: - One step

private struct StepEditor: View {
    @Binding var step: PatternStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step.kind.title).font(.headline)

            switch step.kind {
            case .wait:
                NumberRow(label: "Pause length", value: $step.seconds, range: 0...10, step: 0.05, unit: "s")
            case .startBuzz, .switchBuzz, .doneBuzz, .buzz:
                NumberRow(label: "Vibration length", value: $step.seconds, range: 0.05...3, step: 0.05, unit: "s")
                NumberRow(label: "Strength", value: $step.intensity, range: 0.1...1, step: 0.05, unit: "")
            case .fromFile, .fromRank, .toFile, .toRank, .promotion:
                NumberRow(label: "Gap between pulses", value: $step.seconds, range: 0...5, step: 0.05, unit: "s")
                NumberRow(label: "Each pulse lasts (0 = tap)", value: $step.pulseLength, range: 0...1, step: 0.05, unit: "s")
                NumberRow(label: "Strength", value: $step.intensity, range: 0.1...1, step: 0.05, unit: "")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NumberRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    private var clamped: Binding<Double> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                TextField("0", value: clamped, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .textFieldStyle(.roundedBorder)
                if !unit.isEmpty { Text(unit).foregroundColor(.secondary) }
            }
            Slider(value: clamped, in: range, step: step)
        }
    }
}
