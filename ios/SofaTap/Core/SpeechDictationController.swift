import AVFoundation
import Combine
import Speech
import UIKit

/// Recognition may finish without a new transcription. An empty result is not
/// a user edit and must not erase the usable partial result already displayed.
struct DictationTranscript {
    private(set) var text = ""

    mutating func receive(_ candidate: String?) -> Bool {
        guard let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              candidate != text else { return false }
        text = candidate
        return true
    }

    static func draft(base: String, transcript: String, ownsDraft: Bool, sessionIsActive: Bool) -> String? {
        guard ownsDraft, sessionIsActive,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let separator = base.isEmpty || base.last?.isWhitespace == true ? "" : "\n"
        return base + separator + transcript
    }
}

/// Explicit, foreground dictation. Audio stays on this iPhone; RemoteView sends
/// partial transcripts through live editing, or keeps a draft for unsupported fields.
@MainActor
final class SpeechDictationController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private var generation = UUID()
    private var recognizer: SFSpeechRecognizer?
    private var capture: DictationAudioCapture?
    private var finishTimeout: Task<Void, Never>?
    private var durationLimit: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var recognizedTranscript = DictationTranscript()

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Permission sheets also resign active. They never have an
                // audio capture, and should not invalidate their own request.
                if self.state == .recording || self.state == .finishing { self.cancel() }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard value == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording || self.state == .finishing else { return }
                self.fail(String(localized: "语音输入已中断。已识别的文字仍在草稿中，可重新点击麦克风。"))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state != .idle else { return }
                self.fail(String(localized: "麦克风暂时不可用。请重试，或使用键盘 / Typeless 输入。"))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.fail(String(localized: "麦克风已断开。已识别的文字仍在草稿中，可重新点击麦克风。"))
            }
        })
    }

    deinit {
        finishTimeout?.cancel()
        durationLimit?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        // DictationAudioCapture owns teardown even when a view drops its last
        // reference without delivering an onDisappear callback.
        capture?.tearDown()
    }

    /// Invoke only from an explicit microphone tap. No automatic retry or
    /// server-based recognition is performed when local speech is unavailable.
    func start(locale: Locale = .current) async {
        guard !Task.isCancelled, state == .idle,
              UIApplication.shared.applicationState == .active else { return }
        let token = UUID()
        generation = token
        errorMessage = nil
        recognizedTranscript = DictationTranscript()
        transcript = ""
        state = .requestingPermission

        guard let speech = SFSpeechRecognizer(locale: locale), speech.supportsOnDeviceRecognition else {
            fail(String(localized: "此语言或设备暂不支持本机语音识别。请使用键盘 / Typeless 输入。"))
            return
        }
        let authorization = await Self.speechAuthorization()
        guard isCurrent(token) else { return }
        guard authorization == .authorized else {
            fail(String(localized: "请在 iPhone 设置中允许 Sofatap 使用语音识别，或使用键盘 / Typeless 输入。"))
            return
        }
        let microphoneAllowed = await Self.microphoneAuthorization()
        guard isCurrent(token) else { return }
        guard microphoneAllowed else {
            fail(String(localized: "请在 iPhone 设置中允许 Sofatap 使用麦克风，或使用键盘 / Typeless 输入。"))
            return
        }
        // A permission completion can arrive just before its sheet disappears.
        // Never activate the microphone while the application is inactive.
        for _ in 0..<20 {
            guard isCurrent(token) else { return }
            if UIApplication.shared.applicationState != .inactive { break }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { cancel(); return }
        }
        guard isCurrent(token) else { return }
        guard UIApplication.shared.applicationState == .active else { cancel(); return }
        guard speech.isAvailable, speech.supportsOnDeviceRecognition else {
            fail(String(localized: "本机语音识别暂不可用。请使用键盘 / Typeless 输入，稍后重试。"))
            return
        }

        let audio = DictationAudioCapture()
        capture = audio
        recognizer = speech
        speech.delegate = self
        audio.request.shouldReportPartialResults = true
        audio.request.requiresOnDeviceRecognition = true
        audio.request.taskHint = .dictation
        do {
            try audio.prepare()
            audio.task = speech.recognitionTask(with: audio.request) { [weak self] result, error in
                // Move values, not framework result objects, to the main actor.
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if self.recognizedTranscript.receive(text) {
                        self.transcript = self.recognizedTranscript.text
                    }
                    if final {
                        self.complete()
                    } else if failed {
                        if self.state == .finishing { self.complete() }
                        else { self.fail(String(localized: "本机语音识别已停止。已识别的文字仍在草稿中，可重试或使用键盘 / Typeless。")) }
                    }
                }
            }
            try audio.start()
            state = .recording
            isRecording = true
            durationLimit = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
                guard let self, self.generation == token, self.state == .recording else { return }
                self.stop()
            }
        } catch {
            fail(String(localized: "无法启动麦克风。请重试，或使用键盘 / Typeless 输入。"))
        }
    }

    /// Stop microphone capture immediately, retaining partial text while the
    /// recognizer settles its final result. This never sends text to the desktop.
    func stop() {
        guard state == .recording else {
            if state == .requestingPermission { cancel() }
            return
        }
        state = .finishing
        isRecording = false
        durationLimit?.cancel()
        durationLimit = nil
        capture?.stopMicrophone()
        capture?.request.endAudio()
        let token = generation
        finishTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            guard let self, self.generation == token else { return }
            self.complete()
        }
    }

    /// Cancel permission/startup/capture and ignore any late callbacks. Preserve
    /// the partial transcript so leaving the app or disconnecting loses no draft.
    func cancel() {
        complete()
    }

    private func isCurrent(_ token: UUID) -> Bool {
        guard generation == token else { return false }
        if Task.isCancelled { cancel(); return false }
        return state == .requestingPermission
    }

    private func fail(_ message: String) {
        complete()
        errorMessage = message
    }

    private func complete() {
        generation = UUID()
        finishTimeout?.cancel()
        finishTimeout = nil
        durationLimit?.cancel()
        durationLimit = nil
        recognizer?.delegate = nil
        recognizer = nil
        capture?.tearDown()
        capture = nil
        isRecording = false
        state = .idle
    }

    private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func microphoneAuthorization() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }
}

extension SpeechDictationController: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard !available else { return }
        Task { @MainActor [weak self] in
            guard let self, self.recognizer === speechRecognizer,
                  self.state == .recording || self.state == .finishing else { return }
            self.fail(String(localized: "本机语音识别暂不可用。已识别的文字仍在草稿中，可使用键盘 / Typeless。"))
        }
    }
}

/// Audio ownership is independent from the view/controller lifetime, including
/// its deinitializer. Only the engine's tap writes buffers into the request.
private final class DictationAudioCapture {
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    var task: SFSpeechRecognitionTask?
    private var hasTap = false
    private var sessionIsActive = false

    func prepare() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        sessionIsActive = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "SofatapDictation", code: 1)
        }
        let destination = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            destination.append(buffer)
        }
        hasTap = true
        engine.prepare()
    }

    func start() throws { try engine.start() }

    func stopMicrophone() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        if sessionIsActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionIsActive = false
        }
    }

    func tearDown() {
        stopMicrophone()
        request.endAudio()
        task?.cancel()
        task = nil
    }

    deinit { tearDown() }
}
