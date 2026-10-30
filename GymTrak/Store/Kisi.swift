import Foundation
import Security

/// Opens the gym door through Kisi's API (api.kisi.io), the same calls Kisi's own sample app makes.
/// Signing in trades the Kisi email and password for a login secret; only that secret is kept, in the Keychain.
@Observable @MainActor
final class Kisi {
    static let shared = Kisi()

    struct Door: Codable, Identifiable, Hashable {
        var id: Int
        var name: String
    }

    enum Phase: Equatable { case idle, working, open }

    private(set) var signedIn = false
    private(set) var door: Door?
    private(set) var doors: [Door] = []
    private(set) var phase = Phase.idle
    /// Last failure, worded for the screen.
    var error: String?
    /// Kisi asked for a two-factor code on the last sign-in.
    private(set) var needsCode = false

    private static let base = URL(string: "https://api.kisi.io")!
    private static let doorKey = "gt_kisi_door"
    private static let accountKey = "gt_kisi_email"

    /// The email you signed in with, shown as "Signed in as …".
    private(set) var account: String? = UserDefaults.standard.string(forKey: "gt_kisi_email")

    private init() {
        signedIn = Keychain.read() != nil
        if let data = UserDefaults.standard.data(forKey: Self.doorKey) {
            door = try? JSONDecoder().decode(Door.self, from: data)
        }
    }

    // MARK: Account

    func signIn(email: String, password: String, code: String) async {
        error = nil
        var user = ["email": email.trimmingCharacters(in: .whitespaces), "password": password]
        if !code.isEmpty { user["otp_attempt"] = code }
        do {
            let data = try await send("POST", "/logins", body: ["user": user], secret: nil)
            struct Login: Decodable { var secret: String }
            let login = try JSONDecoder().decode(Login.self, from: data)
            Keychain.save(login.secret)
            signedIn = true
            account = email.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(account, forKey: Self.accountKey)
            needsCode = false
            await loadDoors()
        } catch let e as KisiError {
            if case .server(_, let message) = e, message.range(of: "otp|two.factor|2fa|verification", options: [.regularExpression, .caseInsensitive]) != nil {
                needsCode = true
            }
            error = e.text
        } catch {
            self.error = "Couldn't reach Kisi."
        }
    }

    func signOut() {
        Keychain.delete()
        UserDefaults.standard.removeObject(forKey: Self.doorKey)
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        account = nil
        signedIn = false
        door = nil
        doors = []
        phase = .idle
        error = nil
    }

    /// Every door this account can open. Picks the only one automatically.
    func loadDoors() async {
        guard let secret = Keychain.read() else { return }
        do {
            let data = try await send("GET", "/locks", body: nil, secret: secret)
            doors = try JSONDecoder().decode([Door].self, from: data).sorted { $0.name < $1.name }
            if door == nil || !doors.contains(where: { $0.id == door?.id }) {
                choose(doors.count == 1 ? doors[0] : nil)
            }
        } catch {
            self.error = (error as? KisiError)?.text ?? "Couldn't load doors."
        }
    }

    func choose(_ door: Door?) {
        self.door = door
        if let door, let data = try? JSONEncoder().encode(door) {
            UserDefaults.standard.set(data, forKey: Self.doorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.doorKey)
        }
    }

    // MARK: Unlock

    /// True when it worked. The button shows "Open" for a few seconds, like the door itself.
    @discardableResult
    func unlock() async -> Bool {
        guard let secret = Keychain.read(), let door, phase != .working else { return false }
        error = nil
        phase = .working
        do {
            _ = try await send("POST", "/locks/\(door.id)/unlock", body: ["lock": ["proximity_proof": 0]], secret: secret)
            phase = .open
            Task {
                try? await Task.sleep(for: .seconds(4))
                if phase == .open { phase = .idle }
            }
            return true
        } catch {
            phase = .idle
            self.error = (error as? KisiError)?.text ?? "Couldn't reach Kisi."
            return false
        }
    }

    // MARK: Network

    private func send(_ method: String, _ path: String, body: [String: Any]?, secret: String?) async throws -> Data {
        var request = URLRequest(url: Self.base.appending(path: path), timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret { request.setValue("KISI-LOGIN \(secret)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401, secret != nil { signOut() }
            throw KisiError.server(status, Self.message(in: data))
        }
        return data
    }

    /// Kisi's error text, wherever it is in the reply.
    nonisolated static func message(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return "" }
        func find(_ any: Any) -> String? {
            if let s = any as? String { return s }
            if let a = any as? [Any] { return a.lazy.compactMap(find).first }
            if let d = any as? [String: Any] {
                for key in ["message", "error", "errors", "reason"] { if let v = d[key], let s = find(v) { return s } }
                return d.values.lazy.compactMap(find).first
            }
            return nil
        }
        return find(json) ?? ""
    }
}

enum KisiError: Error {
    case server(Int, String)

    var text: String {
        switch self {
        case .server(let status, let message):
            if !message.isEmpty { return message }
            switch status {
            case 401: return "Wrong email or password."
            case 403: return "Kisi won't open this door from the app."
            case 404: return "Door not found."
            default: return "Kisi error \(status)."
            }
        }
    }
}

/// One Keychain item: the Kisi login secret.
private enum Keychain {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: "dev.ivanshishkin.gymtrak.kisi",
                                       kSecAttrAccount as String: "login"] }

    static func save(_ secret: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
