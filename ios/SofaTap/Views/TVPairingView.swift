import SwiftUI

/// Native pairing; the TV itself grants access. No browser, model or subscription.
struct TVPairingView: View {
    @ObservedObject var tv: WebOSTVController
    let selectTV: () -> Void
    let finishPairing: () -> Void
    var completionTitle = String(localized: "开始遥控电视")
    @State private var address = ""
    @State private var forgetAlert = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(String(localized: "LG webOS 电视"), systemImage: "tv")
                    .sofaTextStyle(.title2, weight: .semibold).foregroundStyle(Palette.mint)
                Text(String(localized: "电视遥控预览：手机与电视连接同一家庭网络。在电视网络设置中查看 IP 地址，连接后用电视遥控器允许配对。"))
                    .foregroundStyle(Palette.muted)
                TextField("192.168.1.20", text: $address)
                    .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(String(localized: "电视 IP 地址"))
                    .accessibilityIdentifier("tvAddress")
                    .disabled(tv.busy || tv.phase == .trust)
                if tv.phase == .trust {
                    Text(String(localized: "确认这是你要配对的电视，并且正在使用信任的家庭网络。继续后需要在电视上允许连接。"))
                    DisclosureGroup(String(localized: "查看连接指纹")) {
                        Text(tv.certificate ?? "").sofaMonospacedCaption().textSelection(.enabled)
                    }
                    Button(String(localized: "继续并在电视上确认")) { tv.trustAndPair() }
                        .buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
                        .accessibilityIdentifier("trustTV")
                    Button(String(localized: "取消")) { tv.disconnect() }
                } else if tv.busy {
                    HStack { ProgressView(); Text(tv.title) }
                    Button(String(localized: "取消连接")) { tv.disconnect() }
                } else if tv.phase == .ready {
                    Button(completionTitle) { finishPairing() }
                        .buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
                    Button(String(localized: "断开电视")) { tv.disconnect() }
                } else {
                    Button(String(localized: "连接电视")) {
                        selectTV()
                        tv.connect(host: address)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("connectTV")
                }
                Text(tv.notice).foregroundStyle(tv.phase == .failed ? .orange : Palette.muted)
                    .accessibilityIdentifier("tvConnectionStatus")
                Text(String(localized: "当前预览提供移动、单击、双指滚动、返回和主页。机型兼容性仍在验证，暂未开放电视键盘、语音输入、右键或拖动。"))
                    .font(.footnote).foregroundStyle(Palette.muted)
                if tv.saved != nil {
                    Button(String(localized: "移除电视配对"), role: .destructive) { forgetAlert = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .background(Palette.background)
        .navigationTitle(String(localized: "配对电视"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if address.isEmpty { address = tv.saved?.host ?? tv.host } }
        .onDisappear { if tv.busy || tv.phase == .trust { tv.disconnect() } }
        .alert(String(localized: "移除电视配对？"), isPresented: $forgetAlert) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "移除"), role: .destructive) { tv.forget() }
        } message: { Text(String(localized: "下次连接需要在电视上重新允许配对。")) }
    }
}
