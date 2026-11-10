import Foundation
import Combine

/// A manually selected TV session. Never auto-falls back to a computer or replays
/// input after a disconnect. A WebSocket send completion is not a TV action ACK.
@MainActor
final class WebOSTVController: ObservableObject {
    enum Phase: Equatable { case idle, inspecting, trust, connecting, approving, openingPointer, ready, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var host = ""
    @Published private(set) var certificate: String?
    @Published private(set) var saved: WebOSTVPairing?
    @Published private(set) var savedDevices: [SavedDevice<WebOSTVPairing>] = []
    @Published private(set) var selectedDeviceID: UUID?
    @Published private(set) var managementError: String?
    @Published private(set) var notice = String(localized: "电视遥控预览：先连接 LG webOS 电视。")
    var canControl: Bool { phase == .ready && !paused }
    var busy: Bool { [.inspecting, .connecting, .approving, .openingPointer].contains(phase) }
    var title: String {
        switch phase {
        case .ready: return String(localized: "LG 电视 · 指针遥控")
        case .trust: return String(localized: "确认电视连接")
        case .approving: return String(localized: "请在电视上允许配对")
        case .inspecting, .connecting, .openingPointer: return String(localized: "正在连接电视…")
        case .idle, .failed: return String(localized: "电视未连接")
        }
    }
    private let storage: WebOSTVPairingStorage
    private let enabled: Bool
    private let makeSocket: @MainActor () -> WebOSTVSocket
    private var control: WebOSTVSocket?
    private var pointer: WebOSTVSocket?
    private var endpoint: WebOSTVEndpoint?
    private var expected = WebOSTVExpectedResponse.none
    private var pendingPairing: WebOSTVPairing?
    private var epoch = UUID()
    private var deadline: Task<Void, Never>?
    private var sendDeadline: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private struct QueuedInput { var action: WebOSTVPointerAction; let time: TimeInterval }
    private var queue: [QueuedInput] = []
    private var sending = false
    @Published private var paused = false

    init(enabled: Bool = true, storage: WebOSTVPairingStorage = WebOSTVKeychain(),
         makeSocket: @escaping @MainActor () -> WebOSTVSocket = { WebOSTVNetworkSocket() }) {
        self.enabled = enabled; self.storage = storage; self.makeSocket = makeSocket
        if enabled { refreshSavedDevices() }
    }

    var currentDisplayName: String {
        if !host.isEmpty, host != saved?.host { return host }
        return savedDevices.first { $0.id == selectedDeviceID }?.displayName ?? saved?.deviceAddress ?? host
    }
    @discardableResult private func refreshSavedDevices() -> Bool {
        do {
            let library = try storage.library()
            savedDevices = library.devices; selectedDeviceID = library.selectedID
            saved = library.selected?.credential
            managementError = nil
            return true
        } catch { managementError = error.localizedDescription; return false }
    }
    func selectDevice(_ id: UUID) {
        guard enabled else { return }
        do {
            try storage.select(id); disconnect()
            guard refreshSavedDevices(), selectedDeviceID == id else { return }
            if let saved { connect(host: saved.host) }
        } catch { managementError = error.localizedDescription }
    }
    func renameDevice(_ id: UUID, name: String) {
        guard enabled else { return }
        do { try storage.rename(id, name: name); refreshSavedDevices() }
        catch { managementError = error.localizedDescription }
    }
    func removeDevice(_ id: UUID) {
        guard enabled else { return }
        do {
            try storage.remove(id)
            if selectedDeviceID == id { disconnect(); host = "" }
            refreshSavedDevices()
        } catch { managementError = error.localizedDescription }
    }

    func connect(host rawHost: String) {
        guard enabled else { return }
        disconnect()
        do { endpoint = try WebOSTVEndpoint(host: rawHost.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { fail(String(localized: "请输入电视的家庭网络 IPv4 地址，例如 192.168.1.20。")); return }
        guard let endpoint else { return }
        host = endpoint.host
        if let saved, saved.host == host {
            certificate = saved.fingerprint
            startControl(pin: saved.fingerprint, clientKey: saved.clientKey)
        } else {
            phase = .inspecting
            notice = String(localized: "正在检查电视连接；还未发送配对凭据。")
            let current = epoch
            let probe = makeSocket()
            control = probe
            probe.onCertificate = { [weak self] pin in
                guard let self, self.epoch == current, self.phase == .inspecting else { return }
                self.deadline?.cancel()
                self.control?.close(); self.control = nil
                self.certificate = pin
                self.phase = .trust
                self.notice = String(localized: "仅在信任的家庭网络继续，随后在电视上确认配对。")
            }
            probe.onFailure = { [weak self] in
                guard self?.phase == .inspecting else { return }
                self?.failIfCurrent(current)
            }
            armDeadline(seconds: 12)
            probe.open(endpoint.controlURL, fingerprint: nil)
        }
    }

    func trustAndPair() {
        guard phase == .trust, let certificate else { return }
        startControl(pin: certificate, clientKey: nil)
    }

    private func startControl(pin: String, clientKey: String?) {
        guard let endpoint else { return }
        phase = .connecting
        notice = String(localized: "正在建立电视加密连接…")
        let current = epoch
        let channel = makeSocket()
        control = channel
        channel.onFailure = { [weak self] in self?.failIfCurrent(current) }
        channel.onOpen = { [weak self] in
            guard let self, self.epoch == current, self.phase == .connecting else { return }
            let id = UUID().uuidString
            self.expected = .registration(id: id)
            self.phase = .approving
            self.notice = String(localized: "查看电视上的配对提示并选择允许。")
            self.armDeadline(seconds: 60)
            do {
                let message = try WebOSTVProtocol.registration(id: id, clientKey: clientKey)
                self.control?.send(message) { [weak self] ok in if !ok { self?.failIfCurrent(current) } }
            } catch { self.failIfCurrent(current) }
        }
        channel.onText = { [weak self] message in
            guard let self, self.epoch == current else { return }
            self.receive(message, pin: pin)
        }
        armDeadline(seconds: 12)
        channel.open(endpoint.controlURL, fingerprint: pin)
    }

    private func receive(_ text: String, pin: String) {
        guard let endpoint else { return }
        do {
            switch try WebOSTVProtocol.parse(text, endpoint: endpoint, expecting: expected) {
            case .registered(let key):
                guard phase == .approving else { return }
                pendingPairing = WebOSTVPairing(host: host, fingerprint: pin, clientKey: key)
                let id = UUID().uuidString
                expected = .pointerSocket(id: id)
                phase = .openingPointer
                let current = epoch
                armDeadline(seconds: 12)
                control?.send(try WebOSTVProtocol.pointerRequest(id: id)) { [weak self] ok in
                    if !ok { self?.failIfCurrent(current) }
                }
            case .pointerSocket(let url):
                guard phase == .openingPointer else { return }
                expected = .none
                openPointer(url, pin: pin)
            case .error:
                fail(String(localized: "电视未允许这次请求。请检查电视上的配对提示或移除配对后重试。"))
            case .other: break
            }
        } catch {
            fail(String(localized: "电视返回了不兼容的响应或连接地址。此机型还需要适配。"))
        }
    }

    private func openPointer(_ url: URL, pin: String) {
        let current = epoch
        let channel = makeSocket()
        pointer = channel
        channel.onFailure = { [weak self] in self?.failIfCurrent(current) }
        channel.onOpen = { [weak self] in
            guard let self, self.epoch == current, self.phase == .openingPointer,
                  let pairing = self.pendingPairing else { return }
            do { try self.storage.write(pairing) }
            catch { self.fail(String(localized: "无法安全保存电视配对，请重试。")); return }
            self.saved = pairing
            try? self.storage.metadata(SavedDevice(credential: pairing).id, name: nil, platform: "webos")
            guard self.refreshSavedDevices(), self.saved?.deviceIdentity == pairing.deviceIdentity else {
                self.fail(String(localized: "无法安全保存电视配对，请重试。")); return
            }
            self.pendingPairing = nil
            self.deadline?.cancel()
            self.phase = .ready
            self.notice = String(localized: "滑动移动电视光标，单击选择，双指滚动。请在电视上确认操作结果。")
            self.startHeartbeat()
        }
        // The pointer channel has no command receipts. Do not interpret arbitrary
        // incoming messages as acceptance or render them in the phone UI.
        channel.onText = { _ in }
        armDeadline(seconds: 12)
        channel.open(url, fingerprint: pin)
    }

    func move(dx: Double, dy: Double) { enqueue(.move(dx: dx, dy: dy)) }
    func click() { enqueue(.click) }
    func scroll(dy: Double) { enqueue(.scroll(dx: 0, dy: dy)) }
    func button(_ button: WebOSTVButton) { enqueue(.button(button)) }

    private func enqueue(_ action: WebOSTVPointerAction) {
        guard canControl, (try? WebOSTVProtocol.encode(action)) != nil else { return }
        // Preserve movement-before-click ordering. Coalesce only adjacent motion;
        // cap the backlog and stop rather than executing stale taps much later.
        if let last = queue.last {
            switch (last.action, action) {
            case (.move(let x, let y), .move(let dx, let dy)):
                queue[queue.count - 1].action = .move(dx: Self.clamp(x + dx, 500), dy: Self.clamp(y + dy, 500))
                return
            case (.scroll(let x, let y), .scroll(let dx, let dy)):
                queue[queue.count - 1].action = .scroll(dx: Self.clamp(x + dx, 1200), dy: Self.clamp(y + dy, 1200))
                return
            default: break
            }
        }
        guard queue.count < 24 else {
            fail(String(localized: "电视响应较慢，已停止遥控。请检查电视后重新连接。")); return
        }
        queue.append(QueuedInput(action: action, time: ProcessInfo.processInfo.systemUptime))
        drain()
    }
    private static func clamp(_ value: Double, _ bound: Double) -> Double { max(-bound, min(bound, value)) }
    private func drain() {
        guard canControl, !sending, !queue.isEmpty, let pointer else { return }
        let input = queue.removeFirst()
        guard ProcessInfo.processInfo.systemUptime - input.time <= 0.5 else {
            fail(String(localized: "电视响应较慢，已停止遥控。请检查电视后重新连接。")); return
        }
        guard let text = try? WebOSTVProtocol.encode(input.action) else { return }
        sending = true
        let current = epoch
        sendDeadline?.cancel()
        sendDeadline = Task { [weak self] in
            try? await SofaClock.sleep(seconds: 3)
            guard !Task.isCancelled else { return }
            self?.failIfCurrent(current)
        }
        pointer.send(text) { [weak self] ok in
            guard let self, self.epoch == current else { return }
            self.sendDeadline?.cancel()
            self.sending = false
            if !ok { self.failIfCurrent(current); return }
            self.drain()
        }
    }
    /// Stop pending touches when a sheet or system prompt obscures the surface.
    func pauseInput() { paused = true; queue.removeAll() }
    func resumeInput() { paused = false }

    func disconnect() {
        epoch = UUID()
        deadline?.cancel(); sendDeadline?.cancel(); heartbeat?.cancel()
        control?.close(); pointer?.close()
        control = nil; pointer = nil; pendingPairing = nil
        queue.removeAll(); sending = false; paused = false
        expected = .none; endpoint = nil; certificate = nil
        phase = .idle
        notice = String(localized: "电视已断开。未完成的操作不会重发。")
    }
    func forget() {
        guard enabled else { return }
        disconnect()
        do { try storage.delete(); refreshSavedDevices(); host = "" }
        catch { fail(String(localized: "无法移除电视配对，请在解锁手机后重试。")) }
    }
    private func fail(_ message: String) { disconnect(); phase = .failed; notice = message }
    private func failIfCurrent(_ current: UUID) {
        guard epoch == current else { return }
        fail(String(localized: "电视连接中断或证书不匹配。检查电视、家庭网络和本地网络权限后重试。"))
    }
    private func armDeadline(seconds: Double) {
        deadline?.cancel()
        let current = epoch
        deadline = Task { [weak self] in
            try? await SofaClock.sleep(seconds: seconds)
            guard !Task.isCancelled else { return }
            self?.failIfCurrent(current)
        }
    }
    private func startHeartbeat() {
        let current = epoch
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await SofaClock.sleep(seconds: 15)
                guard !Task.isCancelled, let self, self.epoch == current else { return }
                self.armDeadline(seconds: 5)
                self.control?.ping { [weak self] ok in
                    guard let self, self.epoch == current else { return }
                    self.deadline?.cancel()
                    if !ok { self.failIfCurrent(current) }
                }
            }
        }
    }
}
