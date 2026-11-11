import Foundation

// Explicit text delivery hints through the production send/ACK path with a
// recording wire (fake transport). No window, network session or OS input.
@MainActor
private final class DeliveryFixture {
    var frames: [[String: Any]] = []
    lazy var model = ControllerModel(testRecordingWire: { [unowned self] text in
        frames.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    })
    init(noFocusCheck: Bool = true) {
        var state = ReceiverState(platform: .macos, status: .ready, inputAvailable: true,
                                  textFocus: .editable, reportsTextFocus: true, supportsLiveText: false)
        state.supportsNoFocusCheck = noFocusCheck
        model.testReceiveState(state)
    }
    var textFrames: [[String: Any]] { frames.filter { $0["type"] as? String == "text" } }
    func ack(error: String? = nil) {
        guard let frame = textFrames.last else { preconditionFailure("No text frame") }
        var message: [String: Any] = ["type": "ack", "id": frame["id"]!, "ok": error == nil]
        if let error { message["error"] = error }
        precondition(model.testReceiveAcknowledgement(message))
    }
    func send(_ text: String) { model.draft = text; model.sendText() }
}

@main
struct TextDeliveryStatesTests {
    @MainActor static func main() {
        var passed = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        let text = "你好，Sofatap 🛋️"

        // ok: no text, Send greys out because there is nothing new.
        let ok = DeliveryFixture(); ok.send(text)
        check("new receiver frames opt in to the focus check", ok.textFrames.first?["requireFocus"] as? Bool == true && ok.textFrames.first?["text"] as? String == text)
        check("pending send shows no delivery hint", ok.model.textDelivery == .sending)
        ok.ack()
        check("ok delivery shows no text", ok.model.textDelivery == .sent && ok.model.textStatus.isEmpty && !ok.model.canSendText)

        // Old receiver: never ask for the check, so never see the third hint.
        let old = DeliveryFixture(noFocusCheck: false); old.send(text)
        check("old receiver frames stay byte-compatible (no requireFocus)", old.textFrames.first?["requireFocus"] == nil)
        old.ack(error: "input_unavailable")
        check("old receiver rejection is the plain not-delivered hint", old.model.textStatus == "没有送到电脑" && old.model.textDelivery != .noFocus)

        // input_no_focus: third hint, retry sends the identical payload.
        let focus = DeliveryFixture(); focus.send(text)
        focus.ack(error: "input_no_focus: No editable field is focused on the computer.")
        check("input_no_focus maps to the focus hint", focus.model.textDelivery == .noFocus && focus.model.textStatus == "电脑上没有可输入的位置，请先点一下输入框")
        check("input_no_focus keeps the draft and the connection", focus.model.draft == text && focus.model.connected)
        focus.model.retryTextDelivery()
        check("no-focus retry sends the same text once", focus.textFrames.count == 2 && focus.textFrames[1]["text"] as? String == text && focus.textFrames[1]["requireFocus"] as? Bool == true)
        focus.ack()
        check("successful retry clears the hint", focus.model.textDelivery == .sent && focus.model.textStatus.isEmpty)

        // input_busy (and every refusal before any event) = definitely not delivered.
        for code in ["input_busy", "input_unavailable", "input_failed", "too_large", "invalid_message", "invalid_frame", "rate_limited"] {
            let busy = DeliveryFixture(); busy.send(text); busy.ack(error: code)
            check("\(code) is definitely not delivered", busy.model.textDelivery == .rejected(code) && busy.model.textStatus == "没有送到电脑")
            busy.model.retryTextDelivery()
            check("\(code) retry payload is identical", busy.textFrames.count == 2 && busy.textFrames[1]["text"] as? String == text)
        }

        // input_partial / unknown: uncertain, both actions available.
        for code in ["input_partial", "something_new"] {
            let partial = DeliveryFixture(); partial.send(text); partial.ack(error: code)
            check("\(code) is uncertain", partial.model.textDelivery == .uncertain && partial.model.textStatus == "连接断了一下，不确定电脑收到没有")
            check("\(code) locks Send until the user decides", !partial.model.canSendText && partial.textFrames.count == 1)
            partial.model.retryTextDelivery()
            check("\(code) 再发一次 resends exactly the same text", partial.textFrames.count == 2 && partial.textFrames[1]["text"] as? String == text)
            partial.ack()
            check("\(code) resend success clears the hint", partial.model.textDelivery == .sent)
        }
        let arrived = DeliveryFixture(); arrived.send(text); arrived.ack(error: "input_partial")
        arrived.model.confirmTextDelivered()
        check("已上屏 clears the draft and unlocks", arrived.model.draft.isEmpty && arrived.model.textDelivery != .uncertain && arrived.textFrames.count == 1)
        arrived.send("下一句"); 
        check("after 已上屏 the next send is a fresh phrase", arrived.textFrames.count == 2 && arrived.textFrames[1]["text"] as? String == "下一句")

        // Timeout after the frame went out: uncertain.
        let late = DeliveryFixture(); late.send(text)
        late.model.testCommandTimeout("text")()
        check("timeout after the frame left is uncertain", late.model.textDelivery == .uncertain && late.model.draft == text)

        // Timeout while still queued on the phone: definitely not delivered.
        let queued = DeliveryFixture(); queued.model.testWireHoldsFrames = true; queued.send(text)
        queued.model.testCommandTimeout("text")()
        check("timeout before the frame left is not delivered", queued.model.textDelivery == .rejected("send_timeout") && queued.model.textStatus == "没有送到电脑")

        // Not connected: definite.
        let offline = DeliveryFixture(); offline.model.testTransportFailure(retryable: false)
        offline.model.draft = text
        check("offline Send is unavailable rather than uncertain", !offline.model.canSendText && offline.model.textDelivery != .uncertain)

        // Composing (IME or dictation) keeps Send grey; finishing lights it up.
        let compose = DeliveryFixture(); compose.model.draft = "听写中"; compose.model.composing = true
        check("composing draft cannot be sent", !compose.model.canSendText)
        compose.model.finishDictation()
        check("finished dictation enables Send without sending", compose.model.canSendText && compose.textFrames.isEmpty)
        compose.model.sendText()
        check("only the final dictation string is sent", compose.textFrames.count == 1 && compose.textFrames[0]["text"] as? String == "听写中")

        print("Text delivery states: \(passed) recording-transport checks passed without OS input")
    }
}
