import SwiftUI

/// Orchestrates: capture -> compress -> Gemini -> oriented board. Pure "photo to board";
/// all chess decisions stay in ChessPhoneViewModel.
@MainActor
final class VisionCoordinator: ObservableObject {
    static let shared = VisionCoordinator()

    enum SourceKind: String, CaseIterable, Identifiable {
        case glasses, phone
        var id: String { rawValue }
        var title: String { self == .glasses ? "Ray-Ban Meta glasses" : "iPhone camera (testing)" }
    }

    enum Stage: Equatable {
        case idle, capturing, reading, done
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Ready."
            case .capturing: return "Taking photo..."
            case .reading: return "Reading board..."
            case .done: return "Board read."
            case .failed(let why): return "Failed: \(why)"
            }
        }
    }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "ChessPhone.vision.enabled")
            enabled ? warmUp() : shutdown()
        }
    }
    @Published var sourceKind: SourceKind {
        didSet {
            UserDefaults.standard.set(sourceKind.rawValue, forKey: "ChessPhone.vision.source")
            shutdown()
            if enabled { warmUp() }
        }
    }
    @Published private(set) var stage: Stage = .idle

    private let glasses = GlassesCameraSource()
    private let phone = PhoneCameraSource()
    private let reader = GeminiBoardReader()

    private var source: BoardImageSource { sourceKind == .glasses ? glasses : phone }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "ChessPhone.vision.enabled")
        sourceKind = SourceKind(rawValue: d.string(forKey: "ChessPhone.vision.source") ?? "") ?? .glasses
    }

    /// Start the camera/session ahead of time so the button press only has to take the photo.
    func warmUp() {
        guard enabled else { return }
        Task { try? await source.prepare() }
    }

    func shutdown() {
        glasses.shutdown()
        phone.shutdown()
    }

    func captureAndRead(playerColor: PieceColor) async throws -> ScannedBoard {
        do {
            stage = .capturing
            let image = try await source.captureImage()

            stage = .reading
            let jpeg = try ImagePreprocessor.jpegData(from: image)       // <= 1024 px longest edge
            let reading = try await reader.readBoard(jpeg: jpeg)
            let board = try BoardOrienter.orient(reading, playerColor: playerColor)

            stage = .done
            return board
        } catch {
            stage = .failed(error.localizedDescription)
            throw error
        }
    }
}

/// Drop this inside the Form in HapticSettingsView.
struct VisionSettingsSection: View {
    @ObservedObject private var vision = VisionCoordinator.shared
    @State private var keyDraft = ""
    @State private var keyStatus = GeminiKeyProvider.hasKey ? "A Gemini key is available." : "No Gemini key yet."
    @State private var glassesStatus = ""

    var body: some View {
        Section(header: Text("Board scanning"),
                footer: Text("When on, Volume Up photographs the board (while it's the opponent's turn and you haven't started typing a move) and works out their move for you.")) {
            Toggle("Volume Up scans the board", isOn: $vision.enabled)
            Picker("Camera", selection: $vision.sourceKind) {
                ForEach(VisionCoordinator.SourceKind.allCases) { Text($0.title).tag($0) }
            }
            if vision.sourceKind == .glasses {
                Button("Connect Ray-Ban Meta glasses") {
                    Task {
                        do {
                            try await GlassesSetup.startRegistration()
                            glassesStatus = "Meta AI opened for registration/approval."
                        } catch {
                            glassesStatus = "Could not start registration: \(error.localizedDescription)"
                        }
                    }
                }
                if !glassesStatus.isEmpty {
                    Text(glassesStatus).font(.caption).foregroundColor(.secondary)
                }
            }
            SecureField("Gemini API key", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save key to Keychain") {
                GeminiKeyProvider.save(keyDraft)
                keyDraft = ""
                keyStatus = GeminiKeyProvider.hasKey ? "Key saved." : "Could not save the key."
            }
            Text(keyStatus).font(.caption).foregroundColor(.secondary)
            Text(vision.stage.text).font(.caption).foregroundColor(.secondary)
        }
    }
}
