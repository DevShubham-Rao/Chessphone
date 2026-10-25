import SwiftUI

struct VisionSafetySettingsView: View {
    @ObservedObject private var vision = VisionCoordinator.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Estimated this game", value: vision.estimatedCostUSD.formatted(.currency(code: "USD")))
                LabeledContent("Authorized allowance", value: vision.authorizedCostLimitUSD.formatted(.currency(code: "USD")))
                LabeledContent("HTTP attempts", value: String(vision.requestCount))
                if vision.isBudgetPaused {
                    Label("Allowance reached. Use Resume in the Command Center to authorize another block.", systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Current game")
            } footer: {
                Text("This is a local estimate, not an invoice or a provider billing limit. Each HTTP attempt counts, including retries and failed requests. Actual charges depend on the provider and may differ.")
            }

            Section {
                TextField("Allowance block (USD)", value: $vision.maxCostUSD, format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad)
                TextField("Estimate per HTTP attempt (USD)", value: $vision.estimatedRequestCostUSD, format: .number.precision(.fractionLength(3)))
                    .keyboardType(.decimalPad)
            } header: {
                Text("Estimated spending guard")
            } footer: {
                Text("The default allowance is $10 per game. Resume adds one more block without erasing the tally. A new block size applies to the next game or Resume. Set the per-attempt estimate conservatively for your chosen Gemini model; $0.01 is a starting estimate, not a quoted price. Training-photo reads share the same allowance.")
            }

            Section {
                Toggle("Local motion pre-check", isOn: $vision.localGateEnabled)
            } header: {
                Text("Reduce requests")
            } footer: {
                Text("On: wait for motion followed by a steady view before asking Gemini. This local image check costs no API calls and does not identify pieces or hands. Off: read approximately every three seconds while watching. Check board now always requests a fresh read.")
            }

            Section("Request limits") {
                Text("Each board read makes at most two HTTP attempts, with a 20-second resource timeout per attempt and a 45-second scan deadline. Only transient failures are retried; an unavailable primary model may use the fallback for the second attempt. Authentication and invalid-board responses stop immediately.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Vision allowance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
