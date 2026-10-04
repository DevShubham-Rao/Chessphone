import Foundation

/// What we ask Gemini to return. The model only reports what it SEES; the app does all chess logic.
struct GeminiBoardReading: Decodable {
    let boardVisible: Bool
    /// 8 strings of 8 characters, FARTHEST row first, LEFT of the image first.
    /// "PNBRQK" = white, "pnbrqk" = black, "." = empty.
    let rows: [String]
    let confidence: String       // "high" | "medium" | "low"
    let notes: String?
}

struct GeminiBoardReader {
    /// One API key can be used with multiple Gemini models, as long as the Google AI project
    /// behind that key has access to them. We prefer 2.5 Flash for this chess-board workload,
    /// then automatically fall back to other current Flash models if a model is unavailable,
    /// rate-limited, or temporarily overloaded.
    private static let models = [
        "gemini-2.5-flash",
        "gemini-3.8-flash",
        "gemini-3.7-flash",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite"
    ]

    /// Low thinking keeps board recognition responsive. Current Gemini 2.5/3.x Flash models
    /// support thinking levels, so the same request shape can be reused across the fallback list.
    private static let thinkingLevel = "low"

    /// Number of retries on a single model after transient errors such as 429 or 503.
    /// After these retries, the reader moves to the next model automatically.
    private static let retriesPerModel = 2

    private static let prompt = """
    This is a photo of a physical chessboard with pieces on it, taken by a player looking at the board; \
    it may be at an angle. Report the position as exactly 8 strings, one per board row, listed from the row \
    FARTHEST from the camera to the row NEAREST the camera. Inside each row go from the LEFT of the image to the RIGHT. \
    Use exactly 8 characters per row: P N B R Q K for white pieces, p n b r q k for black pieces, and . for an empty square. \
    Decide white vs black by the piece's own colour (light vs dark), never by where it stands. \
    Report exactly what is on the board; do not assume a starting or legal position. \
    If a hand or object hides a square, give your best guess and lower the confidence. \
    If a complete 8x8 board is not visible, set boardVisible to false and return eight rows of "........".
    """

    private static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "boardVisible": ["type": "BOOLEAN"],
            "rows": ["type": "ARRAY", "items": ["type": "STRING"], "minItems": 8, "maxItems": 8],
            "confidence": ["type": "STRING", "enum": ["high", "medium", "low"]],
            "notes": ["type": "STRING"]
        ],
        "required": ["boardVisible", "rows", "confidence"],
        "propertyOrdering": ["boardVisible", "rows", "confidence", "notes"]
    ]

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral  // no on-disk cache of photos
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config)
    }()

    func readBoard(jpeg: Data) async throws -> GeminiBoardReading {
        let key = try GeminiKeyProvider.apiKey()
        var lastFailure: VisionError = .emptyResponse

        for model in Self.models {
            for attempt in 0...Self.retriesPerModel {
                do {
                    return try await requestBoard(jpeg: jpeg, apiKey: key, model: model)
                } catch let error as VisionError {
                    lastFailure = error

                    guard case let .http(status, message) = error else {
                        // A valid Gemini response that we could not decode is unlikely to be fixed
                        // by hammering other models. Return the useful error immediately.
                        throw error
                    }

                    if Self.isAuthenticationFailure(status: status) {
                        // Bad/disabled key or project-level permission problem. Another model will
                        // not fix this, so fail immediately with the real server message.
                        throw error
                    }

                    if Self.isUnavailableModel(status: status, message: message) {
                        // This model is not available to this API key/project. Try the next one.
                        break
                    }

                    if Self.isTransient(status: status) {
                        if attempt < Self.retriesPerModel {
                            try await Self.backoff(afterAttempt: attempt)
                            continue
                        }

                        // This model stayed busy/rate-limited after retries. Try another Flash model.
                        break
                    }

                    // 400 and other non-transient request errors usually indicate a real request
                    // problem rather than temporary model load, so don't hide them with fallbacks.
                    throw error
                }
            }
        }

        throw lastFailure
    }

    private func requestBoard(jpeg: Data, apiKey: String, model: String) async throws -> GeminiBoardReading {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw VisionError.emptyResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") // header keeps key out of URLs/logs

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["text": Self.prompt]
                ]
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": Self.schema,
                "thinkingConfig": ["thinkingLevel": Self.thinkingLevel]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VisionError.emptyResponse
        }
        guard http.statusCode == 200 else {
            throw VisionError.http(http.statusCode, Self.apiMessage(from: data))
        }

        struct Envelope: Decodable {
            struct Part: Decodable { let text: String? }
            struct Content: Decodable { let parts: [Part]? }
            struct Candidate: Decodable { let content: Content? }
            let candidates: [Candidate]?
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let text = envelope.candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
        guard !text.isEmpty else {
            throw VisionError.emptyResponse
        }

        do {
            return try JSONDecoder().decode(GeminiBoardReading.self, from: Data(text.utf8))
        } catch {
            throw VisionError.malformedReading("could not decode JSON")
        }
    }

    private static func isTransient(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private static func isAuthenticationFailure(status: Int) -> Bool {
        status == 401
    }

    private static func isUnavailableModel(status: Int, message: String) -> Bool {
        if status == 404 { return true }

        // A 403 can sometimes be model-specific rather than a bad key. Only fall back when the
        // server message clearly talks about model access/availability. Other 403s are surfaced.
        guard status == 403 else { return false }
        let lower = message.lowercased()
        return lower.contains("model") &&
               (lower.contains("access") || lower.contains("available") || lower.contains("permission"))
    }

    private static func backoff(afterAttempt attempt: Int) async throws {
        // About 0.8s, then 1.6s, with a small random jitter so retries do not all land together.
        let baseMilliseconds = 800 * (1 << attempt)
        let jitterMilliseconds = Int.random(in: 0...250)
        let total = baseMilliseconds + jitterMilliseconds
        try await Task.sleep(nanoseconds: UInt64(total) * 1_000_000)
    }

    private static func apiMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? "no details"
    }
}
