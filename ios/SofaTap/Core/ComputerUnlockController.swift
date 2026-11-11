import Foundation
import Combine
import Security

@MainActor
final class ComputerUnlockController: ObservableObject {
    // Retired account-password experiment. A future Windows Hello PIN feature
    // needs its own verified capability and transport; never enable this path
    // by relabeling its password field. Only legacy-record deletion is exposed.
    private static let accountPasswordFlowEnabled = false
    @Published private(set) var state: ComputerUnlockState = .idle
    @Published private(set) var capability: UnlockCapability?
    @Published private(set) var savedBinding: UnlockCredentialBinding?
    @Published private(set) var pairing: Pairing?
    @Published private(set) var serviceState: String?
    private let vault = UnlockCredentialVault()
    private var operation: Task<Void, Never>?
    private var session: URLSession?
    private var generation = UUID()
    private var challenge: UnlockChallenge?
    private var passwordSubmitted = false
    private var foreground = true

    var supported: Bool { Self.accountPasswordFlowEnabled && capability != nil }
    var canUnlock: Bool { supported && savedBinding != nil && !state.busy && state != .uncertain && foreground }
    var canEnroll: Bool { supported && !state.busy && state != .uncertain && foreground }
    var explanation: String {
        supported ? "用于 Windows 本地账户或带密码的个人 Microsoft 账户登录和解锁。设备启动到 Windows 登录界面后可连接。"
        : "这台电脑尚未提供受支持的 Windows 登录组件。普通接收器不能输入锁屏密码。"
    }

    func setPairing(_ newPairing: Pairing?) {
        cancel()
        pairing = newPairing
        capability = Self.accountPasswordFlowEnabled ? newPairing.flatMap { UnlockCapabilityStore.read(for: $0) } : nil
        savedBinding = newPairing.flatMap { vault.binding(for: $0) }
        if Self.accountPasswordFlowEnabled, let pairing = newPairing, let capability,
           savedBinding != capability.binding(pairing) { savedBinding = nil }
        state = .idle; serviceState = nil
    }

    /// Called only for an authenticated, certificate-pinned Windows hello from
    /// a real, unlocked receiver. An old/malformed capability never enables auth.
    func receiveCapability(_ object: Any?, pairing: Pairing) {
        guard Self.accountPasswordFlowEnabled, self.pairing == pairing, let object = object as? [String: Any],
              let candidate = UnlockCapability.parse(object) else { return }
        if let existing = capability, existing != candidate, savedBinding != nil {
            cancel()
            state = .failed("电脑的登录组件身份已改变。请先移除保存的密码，再重新设置 Face ID 解锁。")
            vault.remove(for: pairing)
            UnlockCapabilityStore.delete(for: pairing)
            savedBinding = nil
            capability = nil
            return
        }
        capability = candidate
    }

    func savePassword(_ password: Data) {
        guard Self.accountPasswordFlowEnabled, canEnroll, let pairing, let capability else { return }
        let binding = capability.binding(pairing)
        beginOperation()
        let current = generation
        state = .saving
        operation = Task { [weak self] in
            guard let self else { return }
            var secret = password
            defer { secret.resetBytes(in: 0..<secret.count) }
            do {
                // A password is not stored merely because an old hello advertised
                // a service: verify the enrolled certificate and exact account first.
                let response = try await self.request("GET", path: "/v1/status", pairing: pairing, capability: capability)
                try self.validateStatus(response, capability: capability)
                guard self.generation == current, self.foreground else { throw CancellationError() }
                try await self.vault.save(&secret, binding: binding, pairing: pairing)
                guard self.generation == current, self.foreground else { throw CancellationError() }
                do { try UnlockCapabilityStore.write(capability, for: pairing) }
                catch { self.vault.remove(for: pairing); throw error }
                self.savedBinding = binding
                self.state = .idle
            } catch { self.finish(error, generation: current) }
            if self.generation == current { self.closeTransport() }
        }
    }

    func unlock() {
        guard Self.accountPasswordFlowEnabled, canUnlock, let pairing, let capability, let binding = savedBinding,
              binding == capability.binding(pairing) else { return }
        beginOperation()
        let current = generation
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            var secret = Data()
            defer { secret.resetBytes(in: 0..<secret.count) }
            do {
                let status = try await self.request("GET", path: "/v1/status", pairing: pairing, capability: capability)
                try self.validateStatus(status, capability: capability)
                guard self.serviceState == "locked" else {
                    self.state = .failed(self.serviceState == "ready" ? "电脑已经解锁，无需发送密码。" : "Windows 登录组件暂时不可用。")
                    self.closeTransport(); return
                }
                let reply = try await self.request("POST", path: "/v1/challenge", body: Data("{}".utf8), pairing: pairing, capability: capability)
                guard let challenge = UnlockChallenge.parse(reply, capability: capability, now: Date()) else { throw UnlockTransportError.invalidResponse }
                self.challenge = challenge
                guard self.generation == current, self.foreground else { throw CancellationError() }
                self.state = .authenticating
                secret = try await self.vault.read(binding)
                guard self.generation == current, self.foreground, Date() < challenge.expiresAt else {
                    throw UnlockTransportError.expired
                }
                self.state = .submitting
                var body = try self.encodeSubmission(secret, challenge: challenge)
                secret.resetBytes(in: 0..<secret.count); secret.removeAll(keepingCapacity: false)
                defer { body.resetBytes(in: 0..<body.count) }
                // Once submission begins, every ambiguous failure is unknown. No
                // reconnect, challenge renewal, or retry may resend this body.
                self.passwordSubmitted = true
                let submitted = try await self.request("POST", path: "/v1/unlock", body: body, pairing: pairing, capability: capability)
                body.resetBytes(in: 0..<body.count); body.removeAll(keepingCapacity: false)
                guard capability.validates(submitted), submitted["attemptId"] as? String == challenge.attemptID,
                      submitted["status"] as? String == "waiting_for_windows" else {
                    throw UnlockTransportError.invalidResponse
                }
                self.state = .waiting
                for _ in 0..<20 {
                    try await SofaClock.sleep(seconds: 1)
                    guard self.generation == current, self.foreground else { throw CancellationError() }
                    let reply = try await self.request("GET", path: "/v1/attempt/\(challenge.attemptID)", pairing: pairing, capability: capability)
                    guard capability.validates(reply), reply["attemptId"] as? String == challenge.attemptID,
                          let result = reply["status"] as? String else { throw UnlockTransportError.invalidResponse }
                    switch result {
                    case "unlocked": self.state = .unlocked
                    case "rejected": self.state = .rejected
                    case "expired", "unavailable", "cancelled", "unknown": self.state = .uncertain
                    case "waiting_for_windows": continue
                    default: throw UnlockTransportError.invalidResponse
                    }
                    self.passwordSubmitted = false
                    self.challenge = nil
                    self.closeTransport(); return
                }
                self.state = .uncertain
            } catch { self.finish(error, generation: current) }
            if self.generation == current { self.closeTransport() }
        }
    }

    func acknowledgeUnknownOutcome() {
        guard state == .uncertain else { return }
        state = .idle
    }

    func removePassword() {
        cancel()
        if let pairing {
            guard UnlockCapabilityStore.delete(for: pairing),
                  vault.remove(for: pairing, knownBinding: savedBinding) else {
                state = .failed(String(localized: "旧版解锁记录尚未删除。请解锁 iPhone 后重试。"))
                return
            }
        }
        savedBinding = nil; state = .idle
    }

    func forget(_ pairing: Pairing) {
        cancel(); vault.remove(for: pairing); UnlockCapabilityStore.delete(for: pairing)
    }
    func becameActive() { foreground = true }
    func becameInactive() { foreground = false; cancel() }

    func cancel() {
        let mayHaveSubmitted = passwordSubmitted
        generation = UUID()
        operation?.cancel(); operation = nil
        vault.cancel()
        // Ask the service to discard an unused challenge. An ambiguous/consumed
        // cancellation never turns into permission to retry the password.
        discardPendingChallenge()
        challenge = nil; passwordSubmitted = false
        closeTransport()
        if mayHaveSubmitted { state = .uncertain }
        else if state.busy { state = .idle }
    }

    private func discardPendingChallenge() {
        guard Self.accountPasswordFlowEnabled, let challenge, let pairing, let capability else { return }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = pairing.host
        parts.port = capability.port; parts.path = "/v1/attempt/\(challenge.attemptID)"
        guard let url = parts.url else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2; configuration.timeoutIntervalForResource = 2
        configuration.waitsForConnectivity = false; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        // Cancellation has its own short-lived transport: it cannot keep a
        // password POST alive or invalidate the next explicit operation.
        let cleanup = URLSession(configuration: configuration,
            delegate: PinnedSessionDelegate(pairing: capability.servicePairing(pairing)), delegateQueue: nil)
        var request = URLRequest(url: url); request.httpMethod = "DELETE"
        request.setValue("Bearer \(capability.token)", forHTTPHeaderField: "Authorization")
        cleanup.dataTask(with: request) { _, _, _ in cleanup.finishTasksAndInvalidate() }.resume()
    }

    private func beginOperation() {
        cancel(); generation = UUID(); passwordSubmitted = false
    }
    private func closeTransport() { session?.invalidateAndCancel(); session = nil }
    private func finish(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        vault.cancel()
        discardPendingChallenge(); challenge = nil
        if passwordSubmitted { state = .uncertain }
        else if error is CancellationError { state = .idle }
        else if let error = error as? UnlockVaultError { state = .failed(error.localizedDescription) }
        else if let error = error as? UnlockTransportError { state = .failed(error.localizedDescription) }
        else { state = .failed("无法安全连接电脑的 Windows 登录组件，密码没有发送。") }
    }
    private func encodeSubmission(_ secret: Data, challenge: UnlockChallenge) throws -> Data {
        // Keep the unavoidable JSON String copy outside the async operation's
        // scope, so it is released before waiting for Windows authentication.
        guard let password = String(data: secret, encoding: .utf8), !password.isEmpty else { throw UnlockVaultError.missing }
        return try JSONSerialization.data(withJSONObject: ["attemptId": challenge.attemptID,
            "nonce": challenge.nonce, "password": password])
    }

    private func validateStatus(_ response: [String: Any], capability: UnlockCapability) throws {
        guard capability.validates(response), UnlockCapability.integer(response["version"]) == 1,
              let state = response["state"] as? String, ["ready", "locked", "unavailable"].contains(state) else {
            throw UnlockTransportError.invalidResponse
        }
        serviceState = state
        guard state != "unavailable" else { throw UnlockTransportError.unavailable }
    }
    private func request(_ method: String, path: String, body: Data? = nil,
                         pairing: Pairing, capability: UnlockCapability) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard Self.accountPasswordFlowEnabled, foreground, self.pairing == pairing,
              self.capability == capability else { throw CancellationError() }
        if session == nil {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
            config.waitsForConnectivity = false; config.httpCookieStorage = nil; config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: config, delegate: PinnedSessionDelegate(pairing: capability.servicePairing(pairing)), delegateQueue: nil)
        }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = pairing.host; parts.port = capability.port; parts.path = path
        guard let url = parts.url, let session else { throw UnlockTransportError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(capability.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), data.count <= 16_384,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UnlockTransportError.invalidResponse
        }
        return result
    }
}

private enum UnlockTransportError: LocalizedError {
    case invalidResponse, unavailable, expired
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Windows 登录组件的身份或响应无法验证，已停止解锁。"
        case .unavailable: return "Windows 登录组件暂时不可用。请在电脑上完成安装和账户设置。"
        case .expired: return "本次解锁确认已过期，密码没有发送。请重新点击 Face ID。"
        }
    }
}

private enum UnlockCapabilityStore {
    private struct Record: Codable { let pairing: Pairing; let capability: UnlockCapability }
    private static func query(_ pairing: Pairing) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.chekusu.sofatap.windows-unlock.capability.v1",
         kSecAttrAccount as String: UnlockCredentialBinding(pairing: pairing, accountID: "", accountName: "").storageKey]
    }
    static func read(for pairing: Pairing) -> UnlockCapability? {
        var query = query(pairing); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let record = try? JSONDecoder().decode(Record.self, from: data),
              record.pairing == pairing,
              let fields = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(record.capability)) as? [String: Any]
        else { return nil }
        return UnlockCapability.parse(fields)
    }
    static func write(_ capability: UnlockCapability, for pairing: Pairing) throws {
        var query = query(pairing)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(Record(pairing: pairing, capability: capability)),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecAttrSynchronizable as String: false]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            attributes.forEach { query[$0.key] = $0.value }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw UnlockVaultError.saveFailed }
        } else if updated != errSecSuccess { throw UnlockVaultError.saveFailed }
    }
    @discardableResult
    static func delete(for pairing: Pairing) -> Bool {
        let result = SecItemDelete(query(pairing) as CFDictionary)
        return result == errSecSuccess || result == errSecItemNotFound
    }
}
