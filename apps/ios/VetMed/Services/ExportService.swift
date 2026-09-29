import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
enum ExportService {
    static func copy(_ report: ReportVersion) {
        copyText(report.exportText)
    }
    static func copyText(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
    }
    /// A receiving share extension can still be reading after the app returns to foreground.
    static func cleanExpiredFiles(in directory: URL = AppPaths.exports, now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > 86_400 else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
    static func removeExports(reportIDs: [UUID]) throws {
        for id in reportIDs {
            let url = AppPaths.exports.appendingPathComponent("Bericht-\(id).pdf")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
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
