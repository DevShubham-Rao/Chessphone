import UIKit

// Ray-Ban Meta camera via Meta's Wearables Device Access Toolkit (DAT) 1.0.
// Kept behind canImport so the source still parses in environments where the
// package is not available yet. project.yml links MWDATCore + MWDATCamera.

#if canImport(MWDATCore) && canImport(MWDATCamera)
import MWDATCore
import MWDATCamera

enum GlassesSetup {
    /// Call once at app launch.
    static func configure() {
        do {
            try Wearables.configure()
        } catch {
            print("ChessPhone: Wearables.configure failed: \(error)")
        }
    }

    /// Opens Meta AI so the user can approve/register this app.
    static func startRegistration() async throws {
        try await Wearables.shared.startRegistration()
    }

    /// Meta AI calls the app back on our URL scheme. Only forward DAT callbacks.
    static func handle(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else {
            return
        }
        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                print("ChessPhone: Wearables callback failed: \(error)")
            }
        }
    }
}

@MainActor
final class GlassesCameraSource: BoardImageSource {
    private var session: DeviceSession?
    private var stopCamera: (() -> Void)?
    private var requestPhoto: (() -> Bool)?
    private var tokens: [Any] = []
    private var sessionWatcher: Task<Void, Never>?

    private var sessionStarted = false
    private var streamLive = false
    private var captureID = 0
    private var photoContinuation: CheckedContinuation<Data, Error>?

    func prepare() async throws {
        if sessionStarted, streamLive, requestPhoto != nil { return }
        teardown()

        let wearables = Wearables.shared
        var permission = try await wearables.checkPermissionStatus(.camera)
        if permission != .granted {
            permission = try await wearables.requestPermission(.camera)
        }
        guard permission == .granted else {
            throw VisionError.glassesPermissionDenied
        }

        let newSession = try wearables.createSession(
            deviceSelector: AutoDeviceSelector(wearables: wearables)
        )

        let states = newSession.stateStream()
        sessionWatcher = Task { [weak self] in
            for await state in states {
                await MainActor.run {
                    self?.sessionStarted = (state == .started)
                }
            }
            await MainActor.run { self?.sessionStarted = false }
        }

        try newSession.start()
        guard await waitUntil(8, { sessionStarted }) else {
            teardown()
            throw VisionError.glassesUnavailable
        }
        session = newSession

        // The preview exists only to keep a camera stream available for still capture.
        // A low frame rate leaves bandwidth for the JPEG transfer while high resolution
        // keeps enough detail for small chess pieces.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 2)
        guard let camera = try newSession.addCamera(config: config) else {
            teardown()
            throw VisionError.glassesUnavailable
        }
        let stream = camera.stream

        tokens.append(stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                self?.streamLive = (state == .streaming)
            }
        })

        tokens.append(stream.photoDataPublisher.listen { [weak self] photo in
            let data = photo.data
            Task { @MainActor in
                guard let self else { return }
                self.resolvePhoto(.success(data), id: self.captureID)
            }
        })

        tokens.append(stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                guard let self, self.photoContinuation != nil else { return }
                let id = self.captureID
                self.resolvePhoto(.failure(error), id: id)
                self.teardown()
            }
        })

        stopCamera = { camera.stop() }
        requestPhoto = { stream.capturePhoto(format: .jpeg) }
        stream.start()

        guard await waitUntil(10, { streamLive }) else {
            teardown()
            throw VisionError.glassesUnavailable
        }
    }

    func captureImage() async throws -> UIImage {
        try await prepare()
        guard let requestPhoto else { throw VisionError.glassesUnavailable }
        guard photoContinuation == nil else { throw VisionError.captureBusy }

        captureID += 1
        let id = captureID
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            photoContinuation = continuation

            guard requestPhoto() else {
                photoContinuation = nil
                continuation.resume(throwing: VisionError.captureBusy)
                teardown()
                return
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run {
                    guard let self, self.photoContinuation != nil else { return }
                    self.resolvePhoto(.failure(VisionError.captureTimeout), id: id)
                    // Reset the stream so a very late photo from the timed-out capture
                    // cannot be mistaken for a future capture.
                    self.teardown()
                }
            }
        }

        guard let image = UIImage(data: data) else {
            throw VisionError.imageEncodingFailed
        }
        return image
    }

    func shutdown() {
        teardown()
    }

    private func resolvePhoto(_ result: Result<Data, Error>, id: Int) {
        guard id == captureID, let continuation = photoContinuation else { return }
        photoContinuation = nil
        continuation.resume(with: result)
    }

    private func teardown() {
        if let continuation = photoContinuation {
            photoContinuation = nil
            continuation.resume(throwing: VisionError.glassesUnavailable)
        }
        stopCamera?()
        session?.stop()
        sessionWatcher?.cancel()
        sessionWatcher = nil
        tokens.removeAll()
        stopCamera = nil
        requestPhoto = nil
        session = nil
        sessionStarted = false
        streamLive = false
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}

#else

enum GlassesSetup {
    static func configure() {}
    static func startRegistration() async throws { throw VisionError.sdkNotLinked }
    static func handle(url: URL) {}
}

@MainActor
final class GlassesCameraSource: BoardImageSource {
    func prepare() async throws { throw VisionError.sdkNotLinked }
    func captureImage() async throws -> UIImage { throw VisionError.sdkNotLinked }
    func shutdown() {}
}

#endif
