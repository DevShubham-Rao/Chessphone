import Foundation

/// Every way the scan pipeline can fail, with a short phrase that is safe to speak aloud.
enum VisionError: LocalizedError {
    case missingAPIKey
    case cameraDenied
    case glassesPermissionDenied
    case glassesUnavailable
    case sdkNotLinked
    case captureTimeout
    case captureBusy
    case imageEncodingFailed
    case http(Int, String)
    case emptyResponse
    case malformedReading(String)
    case boardNotVisible
    case lowConfidence
    case invalidPosition(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Gemini API key found (Keychain, Secrets.plist or GEMINI_API_KEY)."
        case .cameraDenied: return "Camera permission was denied."
        case .glassesPermissionDenied: return "The glasses camera permission was not granted in the Meta AI app."
        case .glassesUnavailable: return "Could not start a session with the glasses (are they on, connected and unfolded?)."
        case .sdkNotLinked: return "Meta Wearables SDK is not linked into this build."
        case .captureTimeout: return "The camera did not deliver a photo in time."
        case .captureBusy: return "The glasses camera is already handling another capture."
        case .imageEncodingFailed: return "Could not encode the photo."
        case .http(let code, let msg): return "Gemini returned HTTP \(code): \(msg)"
        case .emptyResponse: return "Gemini returned no answer."
        case .malformedReading(let why): return "Gemini's board reading was malformed: \(why)"
        case .boardNotVisible: return "No complete chessboard was visible in the photo."
        case .lowConfidence: return "The board could not be read clearly."
        case .invalidPosition(let why): return "The scanned position is not valid chess: \(why)"
        }
    }

    /// Short text for speech output.
    var spoken: String {
        switch self {
        case .missingAPIKey: return "No API key."
        case .cameraDenied, .glassesPermissionDenied: return "Camera permission needed."
        case .glassesUnavailable, .sdkNotLinked: return "Glasses not available."
        case .captureTimeout, .captureBusy, .imageEncodingFailed: return "Photo failed. Try again."
        case .http, .emptyResponse: return "Vision service failed. Try again."
        case .boardNotVisible: return "I can't see the whole board."
        case .lowConfidence, .malformedReading: return "Couldn't read the board. Try again."
        case .invalidPosition: return "That position doesn't look right. Try again."
        }
    }
}
