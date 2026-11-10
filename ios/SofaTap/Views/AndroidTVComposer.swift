import SwiftUI
import UIKit

/// The TV draft contains unsent insertions only. It is never presented as a copy
/// of the TV's field; editing and clearing it cannot silently replace remote text.
struct AndroidTVComposer: View {
    @ObservedObject var tv: AndroidTVController
    @Binding var keyboardFocused: Bool
    @Binding var wantsDictation: Bool
    var active: Bool
    var height: Double
    @StateObject private var dictation = SpeechDictationController()
    @State private var composing = false
    @State private var editor = NativeDraftEditor.Control()
    @State private var speechBase = ""
    @State private var speechEditor: UUID?
    @State private var speechOwnsDraft = false
    @State private var speechStart: Task<Void, Never>?
    @State private var showUncertain = false
    private var busy: Bool { dictation.state != .idle }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if tv.textDraft.text.isEmpty {
                        Text(String(localized: "输入或听写，发送到电视当前输入框"))
                            .foregroundStyle(Palette.muted).font(.system(size: 15)).padding(14).allowsHitTesting(false)
                    }
                    NativeDraftEditor(text: $tv.textDraft.text, composing: $composing, isFocused: $keyboardFocused,
                                      disabled: busy || tv.textCommandPending,
                                      preservesFocusWhileLoading: tv.textCommandPending,
                                      control: editor,
                                      onEmptyBackspace: { if !busy && active { _ = tv.textBackspace() } },
                                      accessibilityLabelOverride: String(localized: "要发送到电视的文字草稿"))
                }
                Button {
                    guard editor.flushForSend(), !composing else { return }
                    _ = tv.sendTextDraft()
                } label: {
                    Group {
                        if tv.textCommandPending { ProgressView().tint(Palette.background) }
                        else { Image(systemName: "arrow.up").font(.system(size: 19, weight: .semibold)) }
                    }
                    .frame(width: 44, height: 44).background(Palette.mint, in: Circle()).foregroundStyle(Palette.background)
                }
                .disabled(!tv.canSendText || busy || composing || !active)
                .buttonStyle(RemoteIconButtonStyle())
                .accessibilityLabel(String(localized: "发送"))
                .accessibilityIdentifier("tvSendText")
                .padding(.trailing, 10).padding(.bottom, 10)
            }
            .frame(height: height).background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 2) {
                icon("trash", String(localized: "清空草稿"), "tvClearDraft") { tv.textDraft.clear() }
                    .disabled(tv.textCommandPending || composing || busy)
                icon(keyboardFocused ? "arrow.down" : "arrow.up", keyboardFocused ? String(localized: "收起键盘") : String(localized: "打开键盘输入"), "tvHideKeyboard") {
                    wantsDictation = false
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.easeInOut(duration: 0.2)) { keyboardFocused.toggle() }
                }
                icon("delete.left", String(localized: "电视退格"), "tvRemoteBackspace") {
                    guard editor.flushForSend(), !composing else { return }; _ = tv.textBackspace()
                }.disabled(!tv.canEditTVText || busy || composing || !active)
                icon("return", String(localized: "执行电视输入框操作"), "tvTextAction") {
                    guard editor.flushForSend(), !composing else { return }; _ = tv.performTextAction()
                }.disabled(!tv.canEditTVText || busy || composing || !active || !tv.textDraft.text.isEmpty)
                if tv.textDraft.delivery == .uncertain {
                    icon("arrow.clockwise", String(localized: "检查电视后继续"), "tvResolveText") { showUncertain = true }
                }
                Spacer(minLength: 0)
                Text(statusText).font(.system(size: 11)).foregroundStyle(tv.textDraft.delivery == .uncertain ? .orange : Palette.muted)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tvTextStatus")
            }
        }
        .onAppear { DispatchQueue.main.async { if wantsDictation { startSpeech() } } }
        .onDisappear { cancelSpeech() }
        .onChangeCompat(of: wantsDictation) { _, wanted in
            if wanted { startSpeech() }
            else if dictation.isRecording { dictation.stop() }
            else if dictation.state == .requestingPermission { cancelSpeech() }
        }
        .onChangeCompat(of: active) { _, isActive in
            if !isActive {
                keyboardFocused = false
                // Speech and microphone authorization temporarily make the app
                // inactive. Let the explicit request finish; the speech controller
                // itself waits for foreground before opening the microphone.
                if dictation.state != .requestingPermission || UIApplication.shared.applicationState != .inactive { cancelSpeech() }
            }
        }
        .onChangeCompat(of: tv.status?.tvControls?.editorEpoch) { _, _ in cancelSpeech() }
        .onReceive(dictation.$transcript) { transcript in
            guard active, speechEditor == tv.status?.tvControls?.editorEpoch,
                  let value = DictationTranscript.draft(base: speechBase, transcript: transcript,
                                                       ownsDraft: speechOwnsDraft, sessionIsActive: dictation.state != .idle) else { return }
            tv.textDraft.text = value
        }
        .onChangeCompat(of: dictation.state) { _, state in
            if state == .idle { speechOwnsDraft = false; wantsDictation = false }
        }
        .alert(String(localized: "检查电视后继续"), isPresented: $showUncertain) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "已查看电视")) { tv.textDraft.resolve() }
        } message: {
            Text(String(localized: "上次操作可能已执行。请检查电视，删除草稿中已经输入的内容，再继续发送。不会自动重发。"))
        }
    }
    private var statusText: String {
        if let error = dictation.errorMessage { return error }
        if tv.textDraft.delivery == .uncertain { return String(localized: "上次输入结果未确认，请先检查电视。") }
        if tv.textDraft.text.utf8.count > 4096 { return String(localized: "文字过长，请分段发送。") }
        if busy { return String(localized: "正在听写，结束后确认文字再发送。") }
        switch tv.status?.tvControls?.textStatus {
        case .imeRequired: return String(localized: "请在电视的键盘设置中启用并选择 Sofatap 输入法。")
        case .noEditor: return String(localized: "请先在电视上选中输入框。")
        case .sensitive: return String(localized: "安全输入框不接受手机输入。")
        case .ready: return tv.textCommandPending ? String(localized: "正在发送…") : ""
        case nil: return String(localized: "当前接收器暂不支持电视文字输入。")
        }
    }
    private func icon(_ symbol: String, _ label: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15)).frame(width: 40, height: 44).foregroundStyle(Palette.muted) }
            .buttonStyle(RemoteIconButtonStyle()).accessibilityLabel(label).accessibilityIdentifier(id)
    }
    private func startSpeech() {
        guard active, tv.canEditTVText, !composing, dictation.state == .idle else { wantsDictation = false; return }
        guard editor.flushForSend() else { wantsDictation = false; return }
        speechBase = tv.textDraft.text; speechEditor = tv.status?.tvControls?.editorEpoch; speechOwnsDraft = true
        keyboardFocused = false
        speechStart?.cancel()
        speechStart = Task { await dictation.start() }
    }
    private func cancelSpeech() {
        speechStart?.cancel(); speechStart = nil; speechOwnsDraft = false; speechEditor = nil
        dictation.cancel(); wantsDictation = false
    }
}
