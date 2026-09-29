import Foundation
import ImageIO
import PDFKit
import Vision

enum DocumentTextExtractor {
    static let indexVersion = 3
    struct PageProgress: Sendable, Equatable {
        let completed: Int
        let total: Int
        var fraction: Double { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0 }
        var percent: Int { Int(fraction * 100) }
    }
    struct Section: Sendable { let page: Int?; let text: String }
    struct Result: Sendable { let sections: [Section]; let usedOCR: Bool }
    static let extensions: Set<String> = ["pdf", "txt", "text", "md", "jpg", "jpeg", "png", "heic"]

    /// Called on the knowledge/attachment actor, never on the UI thread. No network involved.
    static func extract(_ data: Data, extension ext: String, maxPages: Int = 500, maxCharacters: Int = 2_000_000, allowImageWithoutText: Bool = false, preservePDFText: Bool = false, onPageRead: ((PageProgress) -> Void)? = nil) throws -> Result {
        try Task.checkCancellation()
        guard extensions.contains(ext) else { throw AppFailure("Format nicht unterstützt. Bitte PDF, TXT, Markdown, JPG, PNG oder HEIC verwenden.") }
        var sections: [Section] = [], usedOCR = false, characters = 0
        func append(_ text: String, page: Int?) throws {
            characters += text.count
            guard characters <= maxCharacters else { throw AppFailure("Mehr als \(maxCharacters.formatted()) Textzeichen. Bitte die Datei aufteilen.") }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(.init(page: page, text: text)) }
        }
        if ext == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw AppFailure("PDF ist beschädigt oder passwortgeschützt.") }
            guard pdf.pageCount <= maxPages else { throw AppFailure("PDFs dürfen hier höchstens \(maxPages) Seiten enthalten. Bitte aufteilen.") }
            onPageRead?(.init(completed: 0, total: pdf.pageCount))
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let page = pdf.page(at: index) else { return }
                    let original = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !original.isEmpty {
                        if preservePDFText { try append(original, page: index + 1) }
                        else { for section in try PDFLayoutReader.sections(page) { try append(section, page: index + 1) } }
                    }
                    else {
                        let bounds = page.bounds(for: .mediaBox)
                        guard bounds.width > 0, bounds.height > 0 else { return }
                        let scale = 2400 / max(bounds.width, bounds.height)
                        guard let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox).cgImage else { throw AppFailure("PDF-Seite konnte nicht für OCR gelesen werden.") }
                        try append(recognize(image), page: index + 1); usedOCR = true
                    }
                }
                onPageRead?(.init(completed: index + 1, total: pdf.pageCount))
            }
        } else if ["txt", "text", "md"].contains(ext) {
            guard let text = String(data: data, encoding: .utf8) else { throw AppFailure("Textdateien müssen UTF-8-kodiert sein.") }
            try append(text, page: nil)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw AppFailure("Bild konnte nicht geöffnet werden.") }
            try append(recognize(image), page: nil); usedOCR = true
        }
        try Task.checkCancellation()
        guard !sections.isEmpty || (allowImageWithoutText && ["jpg", "jpeg", "png", "heic"].contains(ext)) else { throw AppFailure("Keine lesbaren Textinhalte gefunden. OCR erkennt nicht jede Schrift oder Bildqualität.") }
        return Result(sections: sections, usedOCR: usedOCR)
    }

    private static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
