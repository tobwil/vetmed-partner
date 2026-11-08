import Foundation

struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, document }
    let id: UUID
    var createdAt = Date()
    let kind: Kind
    let originalName: String
    let originalExtension: String
    let originalByteCount: Int
    let originalSHA256: String
    let uploadSHA256: String?
    let uploadByteCount: Int?
    let width: Int?
    let height: Int?
    var extractedText: String?
    var reviewedText: String?
    var reviewedAt: Date?
    var usedOCR: Bool
    /// Lab result read as a table (ADR 0015). The chat only uses it once `confirmedAt` is set.
    var lab: LabReport? = nil
    /// To be read by the model (PDF or document photo), decided by the app at import; the name stays from version 1.
    var isLab: Bool? = nil
    /// On-device OCR of the pages, in addition to the text layer: the original the reading's numbers are checked against.
    var checkText: String? = nil
    var displayName: String {
        if kind == .image { return "Bild" }
        if let lab { return lab.heading }
        return isLab == true && originalExtension != "pdf" ? "Dokument (Foto)" : originalName
    }
    /// Everything read locally from the original: text layer and OCR.
    var localText: String { [extractedText, checkText].compactMap { $0 }.joined(separator: "\n") }
}
struct ChatImageReference: Codable, Equatable, Sendable {
    let attachmentID: UUID
    let sha256: String
    let byteCount: Int
    let width: Int
    let height: Int
    var placeholder: String { "vetmed-image:" + attachmentID.uuidString + ":" + sha256 }
}
struct ChatDocumentReference: Codable, Equatable, Sendable {
    let attachmentID: UUID
    let originalSHA256: String
    let text: String
}
struct PreparedChatAttachment: Sendable {
    let attachment: ChatAttachment
    let original: Data
    let upload: Data?
}
