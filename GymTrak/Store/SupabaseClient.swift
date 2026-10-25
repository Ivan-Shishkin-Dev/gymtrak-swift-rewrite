import Foundation

/// Minimal REST client for the one `gt_state` row the PWA also syncs to.
/// Reads use the public key; writes go through the `save_state(password, data)` RPC,
/// which checks the edit code server-side.
struct SupabaseClient: Sendable {
    let baseURL: URL
    let key: String

    /// Reads `SupabaseHost` / `SupabaseKey` from Info.plist (filled from Secrets.xcconfig).
    static func fromBundle() -> SupabaseClient? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let host = info["SupabaseHost"] as? String, !host.isEmpty, !host.contains("$("),
              let key = info["SupabaseKey"] as? String, !key.isEmpty, !key.contains("$("),
              let url = URL(string: "https://\(host)") else { return nil }
        return SupabaseClient(baseURL: url, key: key)
    }

    struct Remote: Sendable {
        var data: Snapshot
        var updatedAt: Double
    }

    enum SyncError: LocalizedError {
        case http(Int, String)
        case invalidCode
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "Server error \(code): \(body.prefix(160))"
            case .invalidCode: "Edit code is no longer valid."
            }
        }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: baseURL.appending(path: path))
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 20
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let text = String(decoding: data, as: UTF8.self)
            if text.range(of: "invalid password", options: .caseInsensitive) != nil { throw SyncError.invalidCode }
            throw SyncError.http(code, text)
        }
        return data
    }

    /// `updated_at` may come back as a number or a numeric string.
    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// The cloud row, or nil when none exists yet.
    func fetch() async throws -> Remote? {
        var r = request("rest/v1/gt_state")
        r.url = URL(string: r.url!.absoluteString + "?id=eq.1&select=data,updated_at")
        let data = try await send(r)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first, let blob = row["data"] else { return nil }
        let snap = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: blob))
        return Remote(data: snap, updatedAt: Self.number(row["updated_at"]) ?? 0)
    }

    /// Just the cloud row's `updated_at`, for the pre-push conflict check.
    func fetchUpdatedAt() async throws -> Double? {
        var r = request("rest/v1/gt_state")
        r.url = URL(string: r.url!.absoluteString + "?id=eq.1&select=updated_at")
        let data = try await send(r)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return Self.number(rows?.first?["updated_at"])
    }

    /// Write the whole snapshot. Returns the server's new `updated_at`.
    func save(_ snapshot: Snapshot, code: String) async throws -> Double {
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let body = try JSONSerialization.data(withJSONObject: ["p_password": code, "p_data": payload])
        let data = try await send(request("rest/v1/rpc/save_state", method: "POST", body: body))
        let any = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return Self.number(any) ?? nowMs()
    }
}
