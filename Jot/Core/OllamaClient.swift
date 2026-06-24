import Foundation

struct OllamaOptions {
    var temperature: Double = 0.15
    var topP: Double = 0.9
    var numPredict: Int = 30
    var numCtx: Int = 1024
    var stop: [String] = ["\n\n", "```", " ---"]
}

enum OllamaError: Error {
    case unreachable
    case timeout
    case invalidResponse
    case modelNotFound(String)
    case httpError(Int)
}

actor OllamaClient {
    static let shared = OllamaClient()

    private let session: URLSession
    private(set) var isReachable: Bool = false

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 60.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    // MARK: - Streaming generate (primary path)

    func generateStream(
        model: String,
        systemPrompt: String,
        userMessage: String,
        options: OllamaOptions
    ) -> AsyncThrowingStream<String, Error> {
        let capturedSession = self.session
        let baseURL = AppSettings.shared.ollamaURL

        return AsyncThrowingStream { continuation in
            let innerTask = Task {
                do {
                    guard let url = URL(string: "\(baseURL)/api/generate") else {
                        continuation.finish(throwing: OllamaError.unreachable)
                        return
                    }

                    let body: [String: Any] = [
                        "model": model,
                        "prompt": userMessage,
                        "system": systemPrompt,
                        "stream": true,
                        "options": [
                            "temperature": options.temperature,
                            "top_p": options.topP,
                            "num_predict": options.numPredict,
                            "num_ctx": options.numCtx,
                            "stop": options.stop
                        ]
                    ]

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 8.0
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    DebugLogger.log("→ stream request: \(model) prompt=\(userMessage.prefix(80))")

                    let (bytes, response) = try await capturedSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: OllamaError.invalidResponse)
                        return
                    }
                    if httpResponse.statusCode == 404 {
                        continuation.finish(throwing: OllamaError.modelNotFound(model))
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: OllamaError.httpError(httpResponse.statusCode))
                        return
                    }

                    var accumulated = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        let token = json["response"] as? String ?? ""
                        let done  = json["done"] as? Bool ?? false

                        accumulated += token
                        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            continuation.yield(accumulated)
                        }
                        if done { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in innerTask.cancel() }
        }
    }

    // MARK: - Non-streaming (used for retries / ping)

    func availableModels() async throws -> [String] {
        let baseURL = AppSettings.shared.ollamaURL
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            throw OllamaError.unreachable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    func ping() async -> Bool {
        let baseURL = AppSettings.shared.ollamaURL
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        do {
            let (_, response) = try await session.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            isReachable = ok
            return ok
        } catch {
            isReachable = false
            return false
        }
    }
}
