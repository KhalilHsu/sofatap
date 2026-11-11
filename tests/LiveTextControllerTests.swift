import Foundation
import SwiftUI
import UIKit

@MainActor
private final class LiveFixture {
    struct Frame {
        let type: String
        let fields: [String: Any]
        var completion: (([String: Any]) -> Void)?
    }
    let session = UUID().uuidString
    var frames: [Frame] = []
    lazy var model = ControllerModel(testLiveSend: { [unowned self] type, fields, completion in
        frames.append(Frame(type: type, fields: fields, completion: completion))
    })
    func reply(_ index: Int, text: String? = nil, selection: NSRange? = nil, revision: Int? = nil, session: String? = nil, error: String? = nil) {
        let frame = frames[index]
        guard let callback = frame.completion else { fatalError("Duplicate test ACK") }
        frames[index].completion = nil
        if let error { callback(["ok": false, "error": error]); return }
        let text = text ?? (frame.fields["text"] as? String ?? "")
        let selection = selection ?? NSRange(location: frame.fields["selectionStart"] as? Int ?? text.utf16.count, length: frame.fields["selectionLength"] as? Int ?? 0)
        var snapshot = LiveTextSnapshot(text: text, selection: selection).fields
        snapshot["session"] = session ?? self.session
        snapshot["revision"] = revision ?? (frame.type == "textBegin" ? 0 : frame.fields["revision"] as? Int ?? 0)
        callback(["ok": true, "liveText": snapshot])
    }
    func begin(_ text: String = "", selection: NSRange? = nil) {
        model.openTextEditor()
        reply(0, text: text, selection: selection)
    }
}

@MainActor
private final class LiveEditorFixture {
    let transport = LiveFixture()
    let view = NativeDraftEditor.TextView()
    var coordinator: NativeDraftEditor.Coordinator!
    init(_ text: String) {
        transport.begin(text)
        let model = transport.model
        let editor = NativeDraftEditor(text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                                       composing: Binding(get: { model.composing }, set: { model.composing = $0 }),
                                       isFocused: .constant(false), disabled: false,
                                       selection: Binding(get: { model.draftSelection }, set: { model.draftSelection = $0 }),
                                       onEdit: { model.editText($0, selection: $1, marked: $2) },
                                       liveEditing: true,
                                       onEmptyBackspace: { model.keyboardBackspaceFromEmptyDraft() })
        coordinator = editor.makeCoordinator(); coordinator.textView = view
        coordinator.synchronizeText(view); view.delegate = coordinator
    }
    func ackAll() {
        var i = 1
        while i < transport.frames.count {
            if transport.frames[i].completion != nil { transport.reply(i) }
            i += 1
        }
        coordinator.synchronizeText(view)
    }
}

@main
struct LiveTextControllerTests {
    @MainActor static func main() {
        var passed = 0
        func check(_ label: String, _ assertion: @autoclosure () -> Bool) {
            guard assertion() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            passed += 1
        }
        let f = LiveFixture()
        f.model.openTextEditor()
        check("editor is gated until initial field snapshot", f.model.editorLoading && !f.model.liveTextReady && !f.model.canSendText)
        f.model.openTextEditor()
        check("duplicate opens share one begin", f.frames.count == 1)
        f.reply(0, text: "电脑原文 🛋️", selection: NSRange(location: 0, length: 4))
        check("begin mirrors full field and UTF16 selected range", f.model.draft == "电脑原文 🛋️" && f.model.draftSelection == NSRange(location: 0, length: 4))
        f.model.editText("第一次", selection: NSRange(location: 3, length: 0), marked: false)
        f.model.editText("第二次", selection: NSRange(location: 3, length: 0), marked: false)
        f.model.editText("最终 🛋️", selection: NSRange(location: 6, length: 0), marked: false)
        check("typing coalesces while a single sync is in flight", f.frames.count == 2 && f.frames[1].fields["revision"] as? Int == 1)
        f.reply(1)
        check("ACK schedules only latest desired snapshot", f.frames.count == 3 && f.frames[2].fields["text"] as? String == "最终 🛋️" && f.frames[2].fields["revision"] as? Int == 2)
        check("old ACK never overwrites newer local input", f.model.draft == "最终 🛋️")
        f.reply(2)
        f.model.selectAll()
        check("select all synchronizes without text change", f.frames.count == 4 && f.frames[3].fields["selectionLength"] as? Int == 6 && f.frames[3].fields["text"] as? String == "最终 🛋️")
        f.reply(3)
        f.model.clearDraft()
        check("empty snapshot is a valid whole-field deletion", f.frames[4].fields["text"] as? String == "" && f.frames[4].fields["selectionStart"] as? Int == 0)
        f.reply(4)
        check("empty input reaches acknowledged active state", f.model.liveTextStatus == .active && f.model.draft.isEmpty)

        let openingRace = LiveFixture(); openingRace.model.openTextEditor()
        openingRace.model.editText("刚输入的内容", selection: NSRange(location: 6, length: 0), marked: false)
        openingRace.reply(0, text: "电脑旧内容")
        check("native callback racing initial snapshot is retained and never overwritten", openingRace.model.liveTextPaused && openingRace.model.draft == "刚输入的内容")

        let ime = LiveFixture(); ime.begin("前缀 ")
        ime.model.editText("前缀 shice", selection: NSRange(location: 8, length: 0), marked: true)
        check("IME provisional syllables do not leave phone", ime.frames.count == 1)
        ime.model.selectAll()
        check("auxiliary select-all cannot finalize provisional IME text", ime.frames.count == 1 && ime.model.composing)
        ime.model.editText("前缀 实测", selection: NSRange(location: 5, length: 0), marked: false)
        check("IME committed candidate immediately synchronizes", ime.frames.count == 2 && ime.frames[1].fields["text"] as? String == "前缀 实测")
        ime.model.editText("前缀 实测ce", selection: NSRange(location: 7, length: 0), marked: true)
        ime.reply(1)
        check("ACK during marked input preserves composition and queues nothing", ime.model.draft == "前缀 实测ce" && ime.frames.count == 2)
        ime.model.editText("前缀 实测测", selection: NSRange(location: 6, length: 0), marked: false)
        check("subsequent commit follows acknowledged revision", ime.frames.count == 3 && ime.frames[2].fields["revision"] as? Int == 2)

        let conflict = LiveFixture(); conflict.begin("电脑已有内容")
        conflict.model.editText("本地修改", selection: NSRange(location: 4, length: 0), marked: false)
        conflict.reply(1, error: "live_text_conflict")
        check("external conflict pauses and retains edited text", conflict.model.liveTextPaused && conflict.model.draft == "本地修改")
        let count = conflict.frames.count
        conflict.model.openTextEditor(); conflict.model.editText("本地保留", selection: NSRange(location: 4, length: 0), marked: false)
        check("conflict cannot silently restart or retry", conflict.frames.count == count)
        conflict.model.restartLiveTextEditing()
        check("explicit reread is required to begin again", conflict.frames.last?.type == "textBegin" && conflict.model.editorLoading)
        conflict.reply(conflict.frames.count - 1, text: "电脑新内容")
        check("explicit reread imports current field", conflict.model.draft == "电脑新内容" && conflict.model.liveTextReady)

        let wrong = LiveFixture(); wrong.begin()
        wrong.model.editText("文字", selection: NSRange(location: 2, length: 0), marked: false)
        wrong.reply(1, session: UUID().uuidString)
        check("foreign session ACK never confirms input", wrong.model.liveTextPaused)
        let wrongRevision = LiveFixture(); wrongRevision.begin()
        wrongRevision.model.editText("文字", selection: NSRange(location: 2, length: 0), marked: false)
        wrongRevision.reply(1, revision: 9)
        check("skipped revision ACK pauses without replay", wrongRevision.model.liveTextPaused)

        let focus = LiveFixture(); focus.begin("旧输入框")
        focus.model.editText("尚未确认", selection: NSRange(location: 4, length: 0), marked: false)
        focus.model.testReceiveFocus(1)
        check("focus switch invalidates pending session and preserves draft", focus.model.liveTextPaused && focus.frames.last?.type == "textEnd")
        focus.reply(1)
        check("late old-focus ACK cannot reopen the session", focus.model.liveTextPaused && focus.model.draft == "尚未确认")
        let idleFocus = LiveFixture(); idleFocus.begin("已同步")
        idleFocus.model.testReceiveFocus(1)
        check("settled session ends on field identity change", idleFocus.model.liveTextStatus == .idle && idleFocus.frames.last?.type == "textEnd")

        let unsupported = LiveFixture(); unsupported.model.openTextEditor(); unsupported.reply(0, error: "live_text_unsupported")
        unsupported.model.editText("手动兼容", selection: NSRange(location: 4, length: 0), marked: false)
        check("unsupported field keeps explicit-send compatibility", !unsupported.model.usesLiveText && unsupported.model.canSendText && unsupported.frames.count == 1)
        check("unsupported hint is shown only before manual delivery", unsupported.model.textStatus.contains("不支持实时编辑"))
        unsupported.model.sendText()
        check("fallback sending status shows pending delivery", unsupported.model.textStatus.contains("等待电脑确认"))
        unsupported.reply(1)
        check("fallback successful receipt clears every hint", unsupported.model.textStatus.isEmpty)
        unsupported.model.clearDraft()
        unsupported.model.editText("新内容", selection: NSRange(location: 3, length: 0), marked: false)
        unsupported.model.sendText(); unsupported.reply(2, error: "input_unavailable")
        check("fallback rejection says the text did not reach the computer", unsupported.model.textStatus == "没有送到电脑" && unsupported.model.textDelivery == .rejected("input_unavailable"))
        let importedFallback = LiveFixture(); importedFallback.begin("电脑已有的文字")
        importedFallback.model.testReceiveFocus(1)
        importedFallback.model.openTextEditor(); importedFallback.reply(2, error: "live_text_unsupported")
        check("unsupported field cannot append a previous imported field", importedFallback.model.draft.isEmpty && !importedFallback.model.canSendText)
        importedFallback.model.editText("本次输入", selection: NSRange(location: 4, length: 0), marked: false)
        importedFallback.model.sendText()
        check("manual fallback sends only the new local draft", importedFallback.frames.last?.fields["text"] as? String == "本次输入")
        let disconnected = LiveFixture(); disconnected.begin()
        disconnected.model.editText("断线草稿", selection: NSRange(location: 4, length: 0), marked: false)
        disconnected.model.disconnect()
        check("disconnect preserves ephemeral draft and suppresses append fallback", disconnected.model.liveTextPaused && disconnected.model.usesLiveText && !disconnected.model.canSendText && disconnected.model.draft == "断线草稿")

        let speech = LiveTextSnapshot(text: "保留 开始 保留后缀", selection: NSRange(location: 3, length: 2))
        check("speech replaces selected range while retaining both sides", speech.replacingSelection(with: "今天")?.text == "保留 今天 保留后缀")
        check("shorter speech correction retains suffix and moves caret", speech.replacingSelection(with: "好") == LiveTextSnapshot(text: "保留 好 保留后缀", selection: NSRange(location: 4, length: 0)))
        check("UTF16 half-surrogate selection is rejected", !LiveTextSnapshot(text: "🛋️", selection: NSRange(location: 1, length: 0)).valid)
        check("NUL is rejected before transmission", !LiveTextSnapshot(text: "a\0b", selection: NSRange(location: 0, length: 0)).valid)
        check("boolean selection metadata is not an integer", LiveTextSnapshot.integer(true) == nil)
        check("oversized field is rejected before transmission", !LiveTextSnapshot(text: String(repeating: "a", count: 16001), selection: NSRange(location: 0, length: 0)).valid)
        check("ordinary CJK can use the full UTF16 field limit", LiveTextSnapshot(text: String(repeating: "中", count: 16000), selection: NSRange(location: 16000, length: 0)).valid)
        let escapedTooLarge = String(repeating: "\u{0001}", count: 12000)
        check("JSON control escape budget is checked separately from UTF16 length", !LiveTextSnapshot(text: escapedTooLarge, selection: NSRange(location: 12000, length: 0)).valid)
        check("receiver surrogate escape budget is bounded before send", !LiveTextSnapshot(text: String(repeating: "🛋", count: 6000), selection: NSRange(location: 12000, length: 0)).valid)
        let oversizedWire = LiveFixture(); oversizedWire.begin()
        oversizedWire.model.editText(escapedTooLarge, selection: NSRange(location: 12000, length: 0), marked: false)
        check("oversized escaped draft pauses locally without a textSync frame", oversizedWire.model.liveTextPaused && !oversizedWire.frames.contains(where: { $0.type == "textSync" }) && oversizedWire.model.draft == escapedTooLarge)
        let exactBudget = String(repeating: "\u{0001}", count: 10751) + "abcd"
        check("escaped text may fill the shared 64512 byte budget exactly", LiveTextSnapshot(text: exactBudget, selection: NSRange(location: exactBudget.utf16.count, length: 0)).valid)
        check("escaped text exceeding reserved envelope by one byte is rejected", !LiveTextSnapshot(text: exactBudget + "e", selection: NSRange(location: 0, length: 0)).valid)

        let editor = LiveEditorFixture("前缀 🛋️")
        check("initial remote caret is applied to actual UITextView", editor.view.selectedRange.location == "前缀 🛋️".utf16.count)
        editor.view.deleteBackward(); editor.ackAll()
        check("native backspace sends complete emoji deletion", editor.transport.frames.last?.fields["text"] as? String == "前缀 ")
        editor.view.selectAll(nil); editor.ackAll()
        check("native UIKit selectAll sends remote selection without duplicate text", editor.transport.frames.last?.fields["selectionLength"] as? Int == 3)
        editor.view.deleteBackward(); editor.ackAll()
        check("native delete after selectAll clears remote field", editor.transport.frames.last?.fields["text"] as? String == "" && editor.transport.model.draft.isEmpty)
        let emptyLiveCount = editor.transport.frames.count
        editor.view.deleteBackward(); editor.transport.model.remoteBackspace()
        check("empty live Backspace produces neither another snapshot nor a raw key", editor.transport.frames.count == emptyLiveCount)

        let shortcut = LiveFixture(); shortcut.begin("前缀 👨‍👩‍👧‍👦")
        shortcut.model.remoteBackspace()
        check("remote shortcut deletes the complete preceding emoji through textSync", shortcut.frames.count == 2 && shortcut.frames[1].type == "textSync" && shortcut.frames[1].fields["text"] as? String == "前缀 ")
        shortcut.model.remoteBackspace()
        check("shortcut during pending live ACK coalesces instead of sending a raw key", shortcut.frames.count == 2 && shortcut.model.draft == "前缀")
        shortcut.reply(1)
        check("ACK flushes exactly one latest deletion snapshot", shortcut.frames.count == 3 && shortcut.frames[2].fields["text"] as? String == "前缀")
        shortcut.reply(2)
        shortcut.model.selectAll(); shortcut.reply(3)
        shortcut.model.remoteBackspace(); shortcut.reply(4)
        check("remote shortcut deletes live selected text without closing its session", shortcut.model.draft.isEmpty && shortcut.model.liveTextReady && shortcut.frames.allSatisfy { $0.type == "textBegin" || $0.type == "textSync" })
        let startingBackspace = LiveFixture(); startingBackspace.model.openTextEditor(); startingBackspace.model.remoteBackspace()
        check("initial live snapshot cannot race the remote Backspace shortcut", startingBackspace.frames.count == 1 && !startingBackspace.model.canRemoteBackspace)

        let beginIMECount = editor.transport.frames.count
        editor.view.setMarkedText("shice", selectedRange: NSRange(location: 5, length: 0))
        check("actual UIKit marked range is not transmitted", editor.transport.frames.count == beginIMECount && editor.transport.model.composing)
        let markedSelection = editor.view.selectedRange
        editor.transport.model.draftSelection = NSRange(location: 0, length: 0)
        editor.coordinator.synchronizeText(editor.view)
        check("external selection update cannot displace an active UIKit marked range", editor.view.markedTextRange != nil && editor.view.selectedRange == markedSelection && editor.transport.frames.count == beginIMECount)
        editor.view.insertText("实测"); editor.ackAll()
        check("actual UIKit candidate sends all committed characters", editor.transport.frames.last?.fields["text"] as? String == "实测" && editor.transport.model.draft == "实测")
        check("selection-before-text native callbacks always emit valid atomic snapshots", editor.transport.frames.filter { $0.type == "textSync" }.allSatisfy { LiveTextSnapshot.parse($0.fields) != nil })
        var loadingFocus = true
        var loadingEditor = NativeDraftEditor(text: .constant("当前输入框"), composing: .constant(false),
                                              isFocused: Binding(get: { loadingFocus }, set: { loadingFocus = $0 }),
                                              disabled: true, preservesFocusWhileLoading: true, liveEditing: true)
        let loadingCoordinator = loadingEditor.makeCoordinator()
        let loadingView = UITextView(); loadingCoordinator.textView = loadingView
        loadingCoordinator.synchronizeText(loadingView)
        loadingCoordinator.textViewDidEndEditing(loadingView)
        check("initial-snapshot temporary disable preserves keyboard focus intent", loadingFocus)
        loadingFocus = false
        loadingCoordinator.textViewDidEndEditing(loadingView)
        check("explicit keyboard hide during snapshot wait is never undone", !loadingFocus)
        loadingFocus = true
        loadingEditor.disabled = false; loadingEditor.preservesFocusWhileLoading = false
        loadingCoordinator.parent = loadingEditor
        loadingCoordinator.textViewDidEndEditing(loadingView)
        check("ordinary editing end still clears keyboard focus intent", !loadingFocus)
        check("live editor accessibility describes automatic synchronization", loadingEditor.editorAccessibilityLabel == "与电脑实时同步的文字和选区")
        loadingEditor.liveEditing = false
        check("fallback accessibility describes an unsent draft", loadingEditor.editorAccessibilityLabel == "要发送到电脑的文字草稿")
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func syncs(_ fixture: LiveEditorFixture) -> [String] {
            fixture.transport.frames.filter { $0.type == "textSync" }.compactMap { $0.fields["text"] as? String }
        }
        // Dictation 1: marked increments, then unmark. Only the final string syncs.
        let marked = LiveEditorFixture("")
        for partial in ["今", "今天", "今天天气", "今天天气很好"] {
            marked.view.setMarkedText(partial, selectedRange: NSRange(location: partial.utf16.count, length: 0)); pump()
        }
        check("dictation marked increments never send textSync", syncs(marked).isEmpty && marked.transport.model.composing)
        marked.view.unmarkText(); pump(); marked.ackAll()
        check("unmark sends exactly the final dictation string once", syncs(marked) == ["今天天气很好"] && !marked.transport.model.composing)

        // Dictation 2: keyboard dictation streams plain text, then replaces it whole.
        let whole = LiveEditorFixture("")
        whole.view.simulateDictation(true)
        whole.view.insertText("hello"); pump()
        whole.view.insertText(" world"); pump()
        whole.view.textStorage.replaceCharacters(in: NSRange(location: 0, length: whole.view.textStorage.length), with: "Hello, world."); pump()
        check("in-progress keyboard dictation stays on the phone", syncs(whole).isEmpty && whole.transport.model.composing)
        whole.view.simulateDictation(false); pump(); whole.ackAll()
        check("dictation end sends only the whole replacement", syncs(whole) == ["Hello, world."] && whole.transport.model.draft == "Hello, world." && !whole.transport.model.composing)

        // Dictation 3: the app's own microphone partials (model level).
        let mic = LiveFixture(); mic.begin()
        for partial in ["打开", "打开设置", "打开设置页面"] {
            mic.model.editText(partial, selection: NSRange(location: partial.utf16.count, length: 0), marked: true)
        }
        check("mic partials are not transmitted", mic.frames.count == 1)
        mic.model.finishDictation()
        check("mic end publishes the final text once", mic.frames.count == 2 && mic.frames[1].type == "textSync" && mic.frames[1].fields["text"] as? String == "打开设置页面")

        // Regression: ordinary typing still syncs per edit.
        let typing = LiveEditorFixture("")
        typing.view.insertText("a"); typing.ackAll(); typing.view.insertText("b"); typing.ackAll()
        check("normal keyboard typing still syncs live", syncs(typing).last == "ab" && !typing.transport.model.composing)
        print("Live text controller: \(passed) recording-transport and UIKit checks passed without windows or OS input")
    }
}
