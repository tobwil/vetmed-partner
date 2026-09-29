import Foundation
import UIKit

@MainActor
enum ExportService {
    static func copy(_ report: ReportVersion) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: report.exportText]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
    }
    static func pdf(_ report: ReportVersion) throws -> URL {
        try AppPaths.prepare(AppPaths.exports)
        let url = AppPaths.exports.appendingPathComponent("Bericht-\(report.id).pdf")
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let text = report.exportText as NSString
        let style = NSMutableParagraphStyle(); style.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .paragraphStyle: style]
        let storage = NSTextStorage(string: text as String, attributes: attributes)
        let layout = NSLayoutManager(); storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        var laidOut = 0
        repeat {
            let container = NSTextContainer(size: CGSize(width: 499, height: 722))
            container.lineFragmentPadding = 0; layout.addTextContainer(container); containers.append(container)
            layout.ensureLayout(for: container)
            let range = layout.glyphRange(for: container)
            guard range.length > 0 || storage.length == 0 else { throw AppFailure("PDF-Seitenumbruch fehlgeschlagen.") }
            laidOut = NSMaxRange(range)
        } while laidOut < layout.numberOfGlyphs
        let data = renderer.pdfData { context in
            for (index, container) in containers.enumerated() {
                context.beginPage()
                let range = layout.glyphRange(for: container)
                layout.drawBackground(forGlyphRange: range, at: CGPoint(x: 48, y: 56))
                layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: 48, y: 56))
                ("VetMed · \(index + 1) / \(containers.count)" as NSString).draw(at: CGPoint(x: 48, y: 806), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.secondaryLabel])
            }
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
