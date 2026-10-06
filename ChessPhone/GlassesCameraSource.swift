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
    private var deviceSelector: AutoDeviceSelector?
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

        // AutoDeviceSelector can exist before the glasses finish reconnecting. Meta's DAT docs
        // recommend waiting for an active device before createSession(); otherwise it can throw
        // DeviceSessionError.noEligibleDevice even though the glasses become available moments later.
        let selector = AutoDeviceSelector(wearables: wearables)
        deviceSelector = selector

        guard await waitUntil(4.0, { selector.activeDevice != nil }) else {
            teardown()
            throw VisionError.glassesNoEligibleDevice
        }

        do {
            var permission = try await wearables.checkPermissionStatus(.camera)
            if permission != .granted {
                permission = try await wearables.requestPermission(.camera)
            }
            guard permission == .granted else {
                throw VisionError.glassesPermissionDenied
            }
        } catch {
            if Self.isNoEligibleDevice(error) {
                teardown()
                throw VisionError.glassesNoEligibleDevice
            }
            throw error
        }

        let newSession: DeviceSession
        do {
            newSession = try await createAndStartSession(selector: selector)
        } catch {
            teardown()
            if Self.isNoEligibleDevice(error) {
                throw VisionError.glassesNoEligibleDevice
            }
            throw error
        }
        session = newSession

        // Medium + low frame rate is enough to keep still capture available while reducing
        // Bluetooth bandwidth/latency compared with a constantly-running high-res preview.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 2)
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
                guard let self else { return }
                if self.photoContinuation != nil {
                    let id = self.captureID
                    self.resolvePhoto(.failure(error), id: id)
                }
                self.streamLive = false
            }
        })

        stopCamera = { camera.stop() }
        requestPhoto = { stream.capturePhoto(format: .jpeg) }
        stream.start()

        guard await waitUntil(6.0, { streamLive }) else {
            teardown()
            throw VisionError.glassesUnavailable
        }
    }

    func captureImage() async throws -> UIImage {
        // The normal path returns immediately because warmUp() has already prepared the stream.
        // If the glasses disconnected/folded, prepare() performs one clean reconnect attempt.
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
                return
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    guard let self, self.photoContinuation != nil else { return }
                    self.resolvePhoto(.failure(VisionError.captureTimeout), id: id)
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

    private func createAndStartSession(selector: AutoDeviceSelector) async throws -> DeviceSession {
        let wearables = Wearables.shared
        var lastError: Error?

        // One quick retry handles the common case where the selector/device becomes eligible
        // during the transition into a session. Do not loop for many seconds.
        for attempt in 0..<2 {
            do {
                let newSession = try wearables.createSession(deviceSelector: selector)
                sessionStarted = false

                let states = newSession.stateStream()
                sessionWatcher?.cancel()
                sessionWatcher = Task { [weak self] in
                    for await state in states {
                        await MainActor.run {
                            self?.sessionStarted = (state == .started)
                        }
                    }
                    await MainActor.run { self?.sessionStarted = false }
                }

                try newSession.start()
                guard await waitUntil(5.0, { sessionStarted }) else {
                    newSession.stop()
                    throw VisionError.glassesUnavailable
                }
                return newSession
            } catch {
                lastError = error
                sessionWatcher?.cancel()
                sessionWatcher = nil
                sessionStarted = false

                guard attempt == 0, Self.isNoEligibleDevice(error) else { throw error }
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard selector.activeDevice != nil else { throw VisionError.glassesNoEligibleDevice }
            }
        }

        throw lastError ?? VisionError.glassesUnavailable
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
        deviceSelector = nil
        sessionStarted = false
        streamLive = false
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return condition()
    }

    private static func isNoEligibleDevice(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased() + " " + error.localizedDescription.lowercased()
        return text.contains("noeligibledevice") || text.contains("no eligible device")
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
