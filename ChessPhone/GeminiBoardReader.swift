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
    /// Required model for this feature. As of October 2026 the stable 2.5 Flash model
    /// is still served, although Google limits new-project access to some 2.5 models.
    static var model = "gemini-2.5-flash"
    /// 0 = no "thinking" (fastest, ~1-2 s). If misreads are common, try 512-1024 (slower but more careful).
    static var thinkingBudget = 0

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
        let config = URLSessionConfiguration.ephemeral          // no on-disk cache of the photos
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    func readBoard(jpeg: Data) async throws -> GeminiBoardReading {
        let key = try GeminiKeyProvider.apiKey()
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):generateContent") else {
            throw VisionError.emptyResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")   // header, not URL: keeps the key out of logs

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["text": Self.prompt]
                ]
            ]],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
                "responseSchema": Self.schema,
                "thinkingConfig": ["thinkingBudget": Self.thinkingBudget]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VisionError.emptyResponse }
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

    private static func apiMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String { return message }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? "no details"
    }
}
