import Foundation

/// What we ask Gemini to return. The model only reports what it SEES; the app does all chess logic.
struct GeminiBoardReading: Decodable {
    let boardVisible: Bool
    let handOverBoard: Bool?
    /// 8 strings of 8 characters in canonical coordinates: rank 8 to rank 1, file a to h.
    /// "PNBRQK" = white, "pnbrqk" = black, "." = empty.
    let rows: [String]
    let confidence: String       // "high" | "medium" | "low"
    let notes: String?
}

struct GeminiBoardReader {
    /// Keep the fallback list deliberately short so a scan does not wait through many models.
    /// Gemini 3.5 Flash-Lite is the fast primary model; 3.5 Flash is the fallback.
    private static let models = [
        "gemini-3.5-flash-lite",
        "gemini-3.5-flash"
    ]

    /// Gemini 3.x uses thinkingLevel instead of the legacy numeric thinkingBudget.
    /// Minimal keeps this visual transcription request as fast as possible.
    private static let thinkingLevel = "minimal"

    /// A scan makes at most two HTTP requests: one request and one transient
    /// retry (or one fallback for an unavailable model), never a retry per model.
    private static let maximumAttempts = 2

    private static let prompt = """
    Read only the physical chessboard in this photo. Ignore any phone screen, app interface, reflection,
    or text that may be visible; never use a displayed chessboard as a substitute for the physical board.
    The photo has already been normalized to look from White's seat: White is nearest the camera,
    Black is farthest, and file a is on the image-left. Return the board from farthest rank to nearest:
    rank 8 first, then rank 7 down to rank 1. Within each row, return files a through h from image-left
    to image-right. Do not infer a different orientation. Each row must contain exactly 8 characters.
    Use PNBRQK for white pieces, pnbrqk for black pieces, and . for empty squares.
    Report only pieces you can actually see on the physical squares. Do not guess, reconstruct, or assume a
    standard setup or legal move. If hands, objects, blur, or framing hide any part of the board, set confidence=low
    and explain which area is unclear. If the full 8x8 board is not visible, set boardVisible=false and return eight rows of ........
    Set handOverBoard=true when a visible hand covers any part of the physical board, otherwise false.
    """

    private static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "boardVisible": ["type": "BOOLEAN"],
            "handOverBoard": ["type": "BOOLEAN"],
            "rows": ["type": "ARRAY", "items": ["type": "STRING"], "minItems": 8, "maxItems": 8],
            "confidence": ["type": "STRING", "enum": ["high", "medium", "low"]],
            "notes": ["type": "STRING"]
        ],
        "required": ["boardVisible", "rows", "confidence"],
        "propertyOrdering": ["boardVisible", "handOverBoard", "rows", "confidence", "notes"]
    ]

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    func readBoard(jpeg: Data, beforeRequest: @MainActor () throws -> Void = {}) async throws -> GeminiBoardReading {
        let key = try GeminiKeyProvider.apiKey()
        try Task.checkCancellation()
        await ChessDebugLog.shared.recordRequestImage(jpeg)
        await ChessDebugLog.shared.record("REQUEST", "Board scan started", details: "Image: JPEG, \(jpeg.count) bytes. API key value hidden. At most two HTTP attempts; each attempt is counted against the estimated allowance.")
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        var modelIndex = 0

        for attempt in 0..<Self.maximumAttempts {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw VisionError.requestTimeout }
            let model = Self.models[modelIndex]
            do {
                // Reserve immediately before each network attempt, including retries.
                try await beforeRequest()
                await ChessDebugLog.shared.record("REQUEST", "Sending Gemini request", details: "Model: \(model)\nAttempt: \(attempt + 1)/\(Self.maximumAttempts)\nPrompt:\n\(Self.prompt)\nImage: JPEG inlineData (\(jpeg.count) bytes; base64 omitted)")
                return try await requestBoard(jpeg: jpeg, apiKey: key, model: model, timeout: min(20, remaining))
            } catch let error as VisionError {
                await ChessDebugLog.shared.record("ERROR", "Gemini request failed", details: "Model: \(model)\nAttempt: \(attempt + 1)\n\(error.localizedDescription)")
                guard case let .http(status, message) = error,
                      attempt + 1 < Self.maximumAttempts else { throw error }
                if Self.isAuthenticationFailure(status: status) { throw error }
                if Self.isUnavailableModel(status: status, message: message), modelIndex + 1 < Self.models.count {
                    modelIndex += 1
                    continue
                }
                guard Self.isTransient(status: status) else { throw error }
                try await Self.backoff()
            } catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
                await ChessDebugLog.shared.record("ERROR", "Gemini network request failed", details: "Model: \(model); attempt \(attempt + 1); network code \(error.code.rawValue).")
                guard attempt + 1 < Self.maximumAttempts, Self.isTransientNetwork(error) else { throw error }
                try await Self.backoff()
            }
        }
        throw VisionError.requestTimeout
    }

    private func requestBoard(jpeg: Data, apiKey: String, model: String, timeout: TimeInterval) async throws -> GeminiBoardReading {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw VisionError.emptyResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
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
                "maxOutputTokens": 2048,
                "responseMimeType": "application/json",
                "responseSchema": Self.schema,
                "thinkingConfig": ["thinkingLevel": Self.thinkingLevel]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var debugBody = "<could not format request JSON>"
        if let requestData = request.httpBody,
           var root = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
           var contents = root["contents"] as? [[String: Any]],
           !contents.isEmpty,
           var parts = contents[0]["parts"] as? [[String: Any]],
           !parts.isEmpty {
            parts[0]["inlineData"] = [
                "mimeType": "image/jpeg",
                "data": "<base64 image omitted; \(jpeg.count) bytes>"
            ]
            contents[0]["parts"] = parts
            root["contents"] = contents
            if let safeData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
               let safeText = String(data: safeData, encoding: .utf8) {
                debugBody = safeText
            }
        }

        await ChessDebugLog.shared.record("REQUEST", "Gemini HTTP request prepared", details: "POST \(url.absoluteString)\nContent-Type: application/json\nx-goog-api-key: [REDACTED]\nBody size: \(request.httpBody?.count ?? 0) bytes including image data.\nSanitized request JSON (image bytes omitted):\n\(debugBody)")

        try Task.checkCancellation()
        let (data, response) = try await urlSession.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            await ChessDebugLog.shared.record("RESPONSE", "Invalid HTTP response", details: "URLSession returned a non-HTTP response.")
            throw VisionError.emptyResponse
        }
        let rawResponse = String(data: data, encoding: .utf8) ?? "<response was not UTF-8>"
        let visibleResponse = String(rawResponse.replacingOccurrences(of: apiKey, with: "[REDACTED]").prefix(24000))
        await ChessDebugLog.shared.record("RESPONSE", "Gemini returned HTTP \(http.statusCode)", details: "Body (\(data.count) bytes; clipped at 24,000 characters):\n\(visibleResponse)")
        guard http.statusCode == 200 else {
            throw VisionError.http(http.statusCode, Self.apiMessage(from: data).replacingOccurrences(of: apiKey, with: "[REDACTED]"))
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
            let reading = try JSONDecoder().decode(GeminiBoardReading.self, from: Data(text.utf8))
            await ChessDebugLog.shared.record("PARSE", "Gemini board reading decoded", details: "boardVisible: \(reading.boardVisible)\nconfidence: \(reading.confidence)\nrows (far to near; left to right):\n\(reading.rows.joined(separator: "\n"))\nnotes: \(reading.notes ?? "<none>")")
            return reading
        } catch {
            await ChessDebugLog.shared.record("ERROR", "Could not decode Gemini board JSON", details: "Decode error: \(error.localizedDescription)\nCandidate text:\n\(text)")
            throw VisionError.malformedReading("could not decode JSON")
        }
    }

    private static func isTransientNetwork(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
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
