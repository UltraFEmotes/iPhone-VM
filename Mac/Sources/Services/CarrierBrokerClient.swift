import Foundation

enum CarrierBrokerClient {
    @MainActor private static var readyUntil = Date.distantPast

    @MainActor
    static func ensureReady() async -> Bool {
        if readyUntil > Date() {
            return true
        }
        guard await Companion.ensureCarrierBroker() else {
            return false
        }
        readyUntil = Date().addingTimeInterval(10)
        return true
    }

    static func get<Response: Decodable>(_ path: String, as type: Response.Type) async -> Response? {
        guard await ensureReady() else { return nil }
        return await request(path: path, method: "GET", body: Optional<Data>.none, as: type)
    }

    static func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, as type: Response.Type) async -> Response? {
        guard await ensureReady(),
              let data = try? JSONEncoder().encode(body) else { return nil }
        return await request(path: path, method: "POST", body: data, as: type)
    }

    private static func request<Response: Decodable>(path: String, method: String, body: Data?, as type: Response.Type) async -> Response? {
        guard let url = URL(string: path, relativeTo: Companion.carrierBaseURL)?.absoluteURL else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            return try JSONDecoder().decode(type, from: data)
        } catch {
            await MainActor.run { readyUntil = .distantPast }
            return nil
        }
    }
}
