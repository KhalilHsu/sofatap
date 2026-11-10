import SwiftUI

struct AndroidTVPairingView: View {
    @ObservedObject var tv: AndroidTVController
    let selectTV: () -> Void
    let finishPairing: () -> Void
    @State private var rawLink = ""
    @State private var showScanner = false
    @State private var forgetAlert = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("Android TV / Google TV", systemImage: "tv")
                    .sofaTextStyle(.title2, weight: .semibold).foregroundStyle(Palette.mint)
                Text(String(localized: "在电视上打开 Sofatap 接收器，扫描原生界面中的二维码。手机与电视需要连接同一家庭网络。"))
                    .foregroundStyle(Palette.muted)
                Button { showScanner = true } label: {
                    Label(String(localized: "扫描电视二维码"), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent).disabled(tv.busy)
                SofaVerticalTextField(prompt: "sofatap://tv?host=…", text: $rawLink, limit: 5)
                    .sofaMonospacedCaption().privacySensitive()
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(String(localized: "电视配对链接"))
                    .accessibilityIdentifier("androidTVPairingLink")
                Button(String(localized: "连接电视")) { accept(rawLink) }
                    .buttonStyle(.bordered)
                    .disabled(rawLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tv.busy)
                if tv.busy {
                    HStack { ProgressView(); Text(tv.title) }
                    Button(String(localized: "取消连接")) { tv.disconnect() }
                } else if tv.phase == .ready {
                    Button(String(localized: "开始遥控电视")) { finishPairing() }
                        // The sheet deliberately pauses the touch surface. Receiver
                        // permission, not that temporary pause, gates leaving pairing.
                        .buttonStyle(.borderedProminent).disabled(tv.status?.available != true && tv.status?.tvControls == nil)
                    Button(String(localized: "断开电视")) { tv.disconnect() }
                } else if tv.saved != nil {
                    Button(String(localized: "重新连接 Android TV")) { selectTV(); tv.reconnect() }
                        .buttonStyle(.borderedProminent)
                }
                Text(tv.notice).foregroundStyle(tv.phase == .failed ? .orange : Palette.muted)
                    .accessibilityIdentifier("androidTVConnectionStatus")
                Text(tv.status?.tvControls == nil ? String(localized: "实验性接收端：光标是屏幕指示层，单击操作可访问控件，兼容性取决于电视与应用。暂不支持系统鼠标、右键、拖动、键盘或语音输入。") : String(localized: "电视暂不支持右键、鼠标双击或拖动。文字输入需启用 Sofatap 输入法。"))
                    .font(.footnote).foregroundStyle(Palette.muted)
                Text(String(localized: "二维码五分钟后失效，首次连接后立即作废。连接未确认时，请在电视上生成新二维码。"))
                    .font(.footnote).foregroundStyle(Palette.muted)
                if tv.saved != nil {
                    Button(String(localized: "移除电视配对"), role: .destructive) { forgetAlert = true }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .background(Palette.background).navigationTitle(String(localized: "配对 Android TV"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            ScannerSheet(accepts: { (try? AndroidTVPairing.parse($0)) != nil }) { value in
                showScanner = false
                accept(value)
            }
        }
        .onDisappear { if tv.busy { tv.disconnect() } }
        .alert(String(localized: "移除电视配对？"), isPresented: $forgetAlert) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "移除"), role: .destructive) { tv.forget() }
        } message: { Text(String(localized: "下次连接需要在电视上生成新二维码。")) }
    }
    private func accept(_ raw: String) {
        selectTV()
        tv.pair(raw)
        rawLink = ""
    }
}
