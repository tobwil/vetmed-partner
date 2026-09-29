import SwiftUI

struct ChatMarkdownView: View {
    let text: String
    @State private var blocks: [ChatMarkdownBlock] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .heading(let level):
                    Text(block.text).font(level <= 2 ? .title3.bold() : .headline).padding(.top, 4)
                case .list(let marker, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text(marker); Text(block.text).frame(maxWidth: .infinity, alignment: .leading) }.padding(.leading, CGFloat(indent * 12))
                case .quote:
                    HStack(spacing: 10) { Rectangle().fill(.teal.opacity(0.4)).frame(width: 3); Text(block.text).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                case .code:
                    ScrollView(.horizontal) { Text(block.text).font(.system(.footnote, design: .monospaced)).padding(12) }.background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                case .divider: Divider()
                case .paragraph: Text(block.text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.textSelection(.enabled)
            .task(id: text) {
                do { blocks = try await ChatMarkdownParser.shared.parse(text) } catch {}
            }
    }
}
