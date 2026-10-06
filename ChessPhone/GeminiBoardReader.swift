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
    /// Keep the fallback list deliberately short. A long chain made one scan wait through
    /// many overloaded/unavailable models. The user's key targets Gemini 2.5 Flash.
    private static let models = [
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite"
    ]

    /// Gemini 2.5 Flash supports thinkingBudget=0, which is ideal for fast visual transcription.
    private static let thinkingBudget = 0

    /// One retry total per transiently failing model, then move on quickly.
    private static let retriesPerModel = 1

    private static let prompt = """
    Read this physical chessboard photo. Return exactly 8 rows from FARTHEST to NEAREST to the camera,
    and within each row LEFT to RIGHT in the image. Each row must contain exactly 8 characters.
    Use PNBRQK for white pieces, pnbrqk for black pieces, and . for empty squares.
    Use each piece's actual light/dark color; do not assume a legal or starting position.
    If the full 8x8 board is not visible, set boardVisible=false and return eight rows of ........
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
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
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

                    guard case let .http(status, message) = error else { throw error }
                    if Self.isAuthenticationFailure(status: status) { throw error }

                    if Self.isUnavailableModel(status: status, message: message) {
                        break
                    }

                    if Self.isTransient(status: status) {
                        if attempt < Self.retriesPerModel {
                            try await Self.backoff()
                            continue
                        }
                        break
                    }

                    throw error
                } catch is URLError {
                    // Network timeouts should not make a scan sit for nearly a minute.
                    lastFailure = .emptyResponse
                    if attempt < Self.retriesPerModel {
                        try await Self.backoff()
                        continue
                    }
                    break
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
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

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
                "thinkingConfig": ["thinkingBudget": Self.thinkingBudget]
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
        guard !text.isEmpty else { throw VisionError.emptyResponse }

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
        guard status == 403 else { return false }
        let lower = message.lowercased()
        return lower.contains("model") &&
               (lower.contains("access") || lower.contains("available") || lower.contains("permission"))
    }

    private static func backoff() async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
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
