import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import PDFKit

actor ChatAttachmentImporter {
    static let maximumOriginalBytes = 20 * 1_048_576
    static let maximumImageBytes = 2 * 1_048_576
    static let maximumImageEdge = 4096
    static let maximumSourcePixels = 64_000_000
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func read(url: URL) throws -> PreparedChatAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        // Simulator processes do not expose the iPhone app memory limit.
        #if !targetEnvironment(simulator)
        guard os_proc_available_memory() >= 512 * 1_048_576 else { throw AppFailure("Für diesen Import ist gerade zu wenig Arbeitsspeicher frei. Bitte andere aufwendige Apps schließen und erneut versuchen.") }
        #endif
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= Self.maximumOriginalBytes else { throw AppFailure("Bitte eine einzelne Datei bis 20 MB auswählen.") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: 262_144), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= Self.maximumOriginalBytes else { throw AppFailure("Die Datei überschreitet 20 MB.") }
            data.append(chunk)
        }
        return try prepare(data: data, name: url.lastPathComponent)
    }
    /// One way in for every file (ADR 0017): document photos and PDFs are marked to be read by the model, clinical
    /// photos stay images, text files are reviewed as text. The app decides from the content, not from a menu choice.
    func prepare(data: Data, name: String) throws -> PreparedChatAttachment {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= Self.maximumOriginalBytes else { throw AppFailure("Die Datei ist leer oder größer als 20 MB.") }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let hash = Self.digest(data), id = UUID()
        if ["jpg", "jpeg", "png", "heic", "heif"].contains(ext) {
            let (upload, width, height) = try Self.jpegUpload(data)
            // A photo of a lab printout or letter is read like a PDF; a wound or an X-ray stays an image.
            let text = (try? DocumentTextExtractor.extract(upload, extension: "jpg", allowImageWithoutText: true))?.sections.map(\.text).joined(separator: "\n") ?? ""
            if DocumentRouting.looksLikeDocument(text) {
                let attachment = ChatAttachment(id: id, kind: .document, originalName: "Dokument (Foto)", originalExtension: ext, originalByteCount: data.count,
                    originalSHA256: hash, uploadSHA256: Self.digest(upload), uploadByteCount: upload.count, width: width, height: height,
                    extractedText: text, usedOCR: true, isLab: true)
                return PreparedChatAttachment(attachment: attachment, original: data, upload: upload)
            }
            let attachment = ChatAttachment(id: id, kind: .image, originalName: name, originalExtension: ext, originalByteCount: data.count,
                originalSHA256: hash, uploadSHA256: Self.digest(upload), uploadByteCount: upload.count,
                width: width, height: height, usedOCR: false)
            return PreparedChatAttachment(attachment: attachment, original: data, upload: upload)
        }
        guard ["pdf", "txt", "text", "md"].contains(ext) else { throw AppFailure("Bitte ein Bild, PDF oder eine UTF-8-Textdatei auswählen.") }
        let result = try DocumentTextExtractor.extract(data, extension: ext, maxPages: 50, maxCharacters: 100_000, preservePDFText: true)
        let text = result.sections.map { section in (section.page.map { "Seite \($0)\n" } ?? "") + section.text }.joined(separator: "\n\n")
        // PDFs up to LabExtraction.maxPages pages are read by the model; their pages also go through OCR for the cross-check.
        let readable = ext == "pdf" && (PDFDocument(data: data)?.pageCount ?? .max) <= LabExtraction.maxPages
        let check = readable ? try DocumentTextExtractor.ocrPages(data, maxPages: LabExtraction.maxPages) : ""
        let attachment = ChatAttachment(id: id, kind: .document, originalName: name, originalExtension: ext, originalByteCount: data.count,
            originalSHA256: hash, uploadSHA256: nil, uploadByteCount: nil, width: nil, height: nil,
            extractedText: text, usedOCR: result.usedOCR, isLab: readable ? true : nil, checkText: check.isEmpty ? nil : check)
        return PreparedChatAttachment(attachment: attachment, original: data, upload: nil)
    }

    /// Page images for the model: rendered PDF pages (about 180 dpi) or the cleaned photo, JPEG within LabExtraction.maxPageBytes.
    static func labPages(_ attachment: ChatAttachment, original: Data, upload: Data?) throws -> [Data] {
        guard attachment.originalExtension == "pdf" else {
            guard let upload else { throw AppFailure("Das Befundfoto ist nicht verfügbar.") }
            return [upload]
        }
        guard let pdf = PDFDocument(data: original), !pdf.isLocked else { throw AppFailure("PDF ist beschädigt oder passwortgeschützt.") }
        guard pdf.pageCount <= LabExtraction.maxPages else { throw AppFailure("Das Dokument hat \(pdf.pageCount) Seiten. Gelesen werden höchstens \(LabExtraction.maxPages) Seiten; bitte den lokalen Text prüfen.") }
        return try (0..<pdf.pageCount).map { index in
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { throw AppFailure("Eine PDF-Seite konnte nicht gelesen werden.") }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 2000 / max(bounds.width, bounds.height, 1)
            guard let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox).cgImage else {
                throw AppFailure("Eine PDF-Seite konnte nicht als Bild gelesen werden.")
            }
            for quality in [0.85, 0.75, 0.62, 0.5] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { break }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= LabExtraction.maxPageBytes { return output as Data }
            }
            throw AppFailure("Eine Dokumentseite ist zu groß für den Versand.")
        }
    }

    /// Pixels only: orientation applied, EXIF/GPS and original filenames not copied.
    private static func jpegUpload(_ data: Data) throws -> (Data, Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 50_000, height <= 50_000, width * height <= Self.maximumSourcePixels,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.maximumImageEdge, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw AppFailure("Das Bild konnte nicht geöffnet werden. Bitte ein einzelnes JPG, PNG oder HEIC mit höchstens 64 Megapixeln wählen.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw AppFailure("Das Versandbild konnte nicht vorbereitet werden.") }
        // Encode pixels only: orientation is applied above; EXIF/GPS and original filenames are not copied.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppFailure("Das Versandbild konnte nicht gespeichert werden.") }
        let upload = output as Data
        guard upload.count <= Self.maximumImageBytes else { throw AppFailure("Das vorbereitete Bild ist zu groß. Bitte einen passenden Ausschnitt als eigenes Bild wählen. Das Original wird nicht still weiter verkleinert.") }
        return (upload, image.width, image.height)
    }
}
