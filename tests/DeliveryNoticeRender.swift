import SwiftUI
import UIKit

// Offscreen render of the composer's delivery hint at iPhone SE widths, using the
// repo's own Localizable.strings. Writes PNGs and reports line counts.
@main
struct DeliveryNoticeRender {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let repo = args[1], out = args[2]
        let width = CGFloat(Double(args[3]) ?? 320), prefix = args[4]
        let states: [(String, String, [String])] = [
            ("rejected", "没有送到电脑", ["重试"]),
            ("nofocus", "电脑上没有可输入的位置，请先点一下输入框", ["重试"]),
            ("uncertain", "连接断了一下，不确定电脑收到没有", ["已上屏", "再发一次"])]
        var problems = 0
        for loc in ["de", "fr", "ru"] {
            let path = "\(repo)/ios/SofaTap/\(loc).lproj/Localizable.strings"
            let table = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil)) as? [String: String] ?? [:]
            func t(_ key: String) -> String { table[key] ?? key }
            let draft = t("你好，帮我播放今晚想看的电影。")
            for (name, key, buttons) in states {
                let message = t(key), titles = buttons.map(t)
                // Same geometry as RemoteView: composer padding 12, row padding 6, spacing 14.
                let rowWidth = width - 24 - 12
                let semibold = UIFont.systemFont(ofSize: 13, weight: .semibold), regular = UIFont.systemFont(ofSize: 13)
                let buttonWidths = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: semibold]).width) }
                let textWidth = rowWidth - buttonWidths.reduce(0, +) - 14 * CGFloat(titles.count)
                let full = (message as NSString).boundingRect(with: CGSize(width: textWidth, height: 1000), options: .usesLineFragmentOrigin, attributes: [.font: regular], context: nil)
                let lines = Int(round(full.height / regular.lineHeight))
                let truncated = lines > 2
                if truncated { problems += 1 }
                print("\(prefix)-\(loc)-\(name) width=\(Int(width)) textWidth=\(Int(textWidth)) lines=\(lines) truncated=\(truncated) buttons=\(zip(titles, buttonWidths).map { "\($0.0)(\(Int($0.1))pt,1 line)" }.joined(separator: " "))")
                let view = VStack(spacing: 0) {
                    HStack(spacing: 18) {
                        ForEach(["trash", "arrow.up", "delete.left"], id: \.self) { Image(systemName: $0).font(.system(size: 18)).foregroundStyle(Kare.ink2) }
                        Spacer()
                    }.padding(.horizontal, 10).frame(height: 44)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 22).fill(Kare.surface)
                        Text(draft).font(.system(size: 19)).foregroundStyle(Kare.ink).padding(14)
                        Circle().fill(Kare.accent.opacity(0.35)).frame(width: 44, height: 44)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
                    }.frame(height: 112)
                    DeliveryNoticeRow(message: message, font: .system(size: 13),
                                      actions: titles.enumerated().map { DeliveryNoticeRow.Action(title: $0.element, identifier: "a\($0.offset)", run: {}) })
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .frame(width: width, height: 240)
                .background(Kare.sand)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: loc))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.uiImage, let png = image.pngData() else { print("render failed"); exit(1) }
                try! png.write(to: URL(fileURLWithPath: "\(out)/\(prefix)-\(loc)-\(name).png"))
            }
        }
        print("problems=\(problems)")
    }
}
