import XCTest
import CryptoKit
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import VetMed

@MainActor
final class ChatAttachmentTests: XCTestCase {
    private func image() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let cg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }.cgImage)
        let data = NSMutableData()
        let target = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, cg, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE CAMERA METADATA"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(target))
        return data as Data
    }
    private func prepare() async throws -> PreparedChatAttachment {
        try await ChatAttachmentImporter().prepare(data: image(), name: "PRIVATE OWNER.jpg")
    }
    private func snapshot(_ values: [ChatAttachment], encounter: Encounter = .init()) throws -> SparringSnapshot {
        var context = encounter; context.chatAttachments = values
        return try SparringRequestBuilder.prepare(caseID: nil, encounter: context,
            draft: .init(question: "Was ist erkennbar?", attachmentIDs: values.map(\.id)), modelID: "synthetic-vision-model")
    }
    func testImagePreservesLocalOriginalButAppliesOrientationAndStripsMetadataForUpload() async throws {
        let original = try image(), result = try await ChatAttachmentImporter().prepare(data: original, name: "PRIVATE OWNER.jpg")
        XCTAssertEqual(result.original, original)
        XCTAssertEqual(result.attachment.originalSHA256, ChatAttachmentImporter.digest(original))
        XCTAssertEqual(result.attachment.width, 80); XCTAssertEqual(result.attachment.height, 120)
        let upload = try XCTUnwrap(result.upload)
        XCTAssertNotEqual(upload, original); XCTAssertLessThanOrEqual(upload.count, ChatAttachmentImporter.maximumImageBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(upload as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertFalse(String(describing: properties).contains("PRIVATE CAMERA METADATA"))
    }
    func testInvalidEmptyOversizedAndUnsupportedFilesAreRejected() async throws {
        let importer = ChatAttachmentImporter()
        for (data, name) in [(Data(), "x.txt"), (Data("corrupt".utf8), "x.jpg"), (Data("test".utf8), "x.zip"), (Data(repeating: 1, count: ChatAttachmentImporter.maximumOriginalBytes + 1), "x.png")] {
            do { _ = try await importer.prepare(data: data, name: name); XCTFail("Accepted \(name)") } catch {}
        }
    }
    func testOversizedPixelDimensionsAreRejectedBeforeDecodingImage() async throws {
        var data = try image()
        // Alter only the JPEG frame dimensions, without allocating a large bitmap.
        let marker = try XCTUnwrap((0..<(data.count - 9)).first { data[$0] == 0xff && [UInt8(0xc0), 0xc1, 0xc2].contains(data[$0 + 1]) })
        data[marker + 5] = 0x23; data[marker + 6] = 0x28 // 9000 px height
        data[marker + 7] = 0x23; data[marker + 8] = 0x28 // 9000 px width
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 9000)
        do { _ = try await ChatAttachmentImporter().prepare(data: data, name: "large.jpg"); XCTFail("Excessive pixel count accepted") } catch {}
    }
    func testDocumentNeedsReviewAndPreservesNumbersUnitsAndNegation() async throws {
        let original = Data("Hund 12,5 kg. Kein Fieber. Na 148 mmol/l.\n<7,0; nicht gemessen.".utf8)
        let value = try await ChatAttachmentImporter().prepare(data: original, name: "PRIVATE OWNER.txt")
        XCTAssertNil(value.upload); XCTAssertNil(value.attachment.reviewedAt)
        XCTAssertEqual(value.attachment.extractedText, String(decoding: original, as: UTF8.self))
        XCTAssertThrowsError(try snapshot([value.attachment]))
        var reviewed = value.attachment; reviewed.reviewedAt = Date(); reviewed.reviewedText = value.attachment.extractedText
        let result = try snapshot([reviewed])
        XCTAssertEqual(result.documents?.first?.text, reviewed.reviewedText)
        let body = String(decoding: result.payload, as: UTF8.self)
        XCTAssertTrue(body.contains("12,5 kg")); XCTAssertTrue(body.contains("Kein Fieber")); XCTAssertTrue(body.contains("148 mmol"))
        XCTAssertFalse(body.contains("PRIVATE OWNER"))
    }
    func testPDFTextLayerStaysLocalUntilReviewed() async throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            context.beginPage(); ("Na 148 mmol/l. Kein Fieber." as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        let result = try await ChatAttachmentImporter().prepare(data: data, name: "Befund.pdf")
        XCTAssertFalse(result.attachment.usedOCR)
        XCTAssertTrue(result.attachment.extractedText?.contains("148 mmol/l") == true)
        XCTAssertNil(result.attachment.reviewedAt); XCTAssertNil(result.upload)
        XCTAssertThrowsError(try snapshot([result.attachment]))
    }
    func testImageWireUsesVerifiedBytesWithoutFilenameAndManifestStaysSmall() async throws {
        let value = try await prepare(), result = try snapshot([value.attachment]), bytes = try XCTUnwrap(value.upload)
        XCTAssertLessThan(result.payload.count, 16_384)
        XCTAssertFalse(String(decoding: result.payload, as: UTF8.self).contains("base64"))
        let request = try SparringRequestBuilder.request(snapshot: result, key: "synthetic-image-key-for-contract-tests", imageData: [value.attachment.id: bytes])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.last?["image_url"] as? String, "data:image/jpeg;base64," + bytes.base64EncodedString())
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("PRIVATE OWNER"))
        XCTAssertThrowsError(try SparringRequestBuilder.request(snapshot: result, key: "synthetic-image-key-for-contract-tests"))
        XCTAssertThrowsError(try SparringRequestBuilder.request(snapshot: result, key: "synthetic-image-key-for-contract-tests", imageData: [value.attachment.id: Data(repeating: 0, count: bytes.count)]))
        var missing = result; missing.requestImages = nil
        XCTAssertThrowsError(try SparringRequestBuilder.request(snapshot: missing, key: "synthetic-image-key-for-contract-tests", imageData: [value.attachment.id: bytes]))
    }
    func testFollowUpRetainsSameChatImageButRejectsForeignAttachment() async throws {
        let value = try await prepare(); var context = Encounter(chatAttachments: [value.attachment])
        let first = try snapshot([value.attachment], encounter: context)
        let run = AnalysisRun(snapshot: first, status: .completed, text: "Hypothese")
        context.analysisRuns = [run]
        let next = try SparringRequestBuilder.prepare(caseID: nil, encounter: context, draft: .init(question: "Und weiter?", historyIDs: [run.id]), modelID: "test")
        XCTAssertTrue(next.images?.isEmpty == true); XCTAssertEqual(next.requestImages, first.images)
        let request = try SparringRequestBuilder.request(snapshot: next, key: "synthetic-image-key-for-contract-tests", imageData: [value.attachment.id: try XCTUnwrap(value.upload)])
        XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("Hypothese"))
        XCTAssertThrowsError(try SparringRequestBuilder.prepare(caseID: nil, encounter: .init(), draft: .init(question: "Frage", attachmentIDs: [value.attachment.id]), modelID: "test"))
    }
    func testImageLimitIncludesHistoryWithoutSilentlyDroppingOlderPictures() async throws {
        let source = try await prepare()
        let images = (0..<9).map { _ in ChatAttachment(id: UUID(), kind: .image, originalName: "Bild.jpg", originalExtension: "jpg",
            originalByteCount: source.original.count, originalSHA256: source.attachment.originalSHA256,
            uploadSHA256: source.attachment.uploadSHA256, uploadByteCount: source.attachment.uploadByteCount,
            width: source.attachment.width, height: source.attachment.height, usedOCR: false) }
        var context = Encounter(chatAttachments: images)
        let first = try snapshot(Array(images.prefix(8)), encounter: context)
        let run = AnalysisRun(snapshot: first, status: .completed, text: "Erste Einordnung")
        context.analysisRuns = [run]
        XCTAssertThrowsError(try SparringRequestBuilder.prepare(caseID: nil, encounter: context,
            draft: .init(question: "Noch ein Bild", historyIDs: [run.id], attachmentIDs: [images[8].id]), modelID: "test"))
        XCTAssertEqual(context.analysisRuns?.first?.snapshot.images?.count, 8)
    }
    func testEncryptedStorageCleanupReopenAndQuickCheckDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), repository = try CaseRepository(root: root, key: key)
        let keep = try await prepare(), orphan = try await prepare(), check = QuickCheck(chatAttachments: [keep.attachment])
        try await repository.storeAttachment(keep, caseID: nil, encounterID: check.id)
        try await repository.storeAttachment(orphan, caseID: nil, encounterID: check.id)
        let document = VaultDocument(quickChecks: [check]); try await repository.save(document)
        try await repository.cleanUnreferencedAttachments(document)
        let reopened = try CaseRepository(root: root, key: key)
        let loaded = try await reopened.load(); XCTAssertEqual(loaded, document)
        let bytes = try await reopened.attachmentData(caseID: nil, encounterID: check.id, id: keep.attachment.id, upload: false)
        XCTAssertEqual(bytes, keep.original)
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("ChatAttachments"), includingPropertiesForKeys: nil)!.allObjects as! [URL]
        for file in files where file.pathExtension == "aesgcm" { XCTAssertNotEqual(try Data(contentsOf: file), keep.original) }
        do { _ = try await reopened.attachmentData(caseID: nil, encounterID: check.id, id: orphan.attachment.id, upload: false); XCTFail("Orphan survived") } catch {}
        try await reopened.removeQuickCheckFiles(check.id)
        do { _ = try await reopened.attachmentData(caseID: nil, encounterID: check.id, id: keep.attachment.id, upload: true); XCTFail("Deleted attachment survived") } catch {}
    }
    func testCiphertextCannotMoveBetweenCases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CaseRepository(root: root, key: SymmetricKey(size: .bits256)), value = try await prepare()
        let a = UUID(), b = UUID(), encounter = UUID()
        try await repository.storeAttachment(value, caseID: a, encounterID: encounter)
        try await repository.storeAttachment(value, caseID: b, encounterID: encounter)
        let base = root.appendingPathComponent("ChatAttachments")
        let suffix = encounter.uuidString + "/" + value.attachment.id.uuidString + "-original.aesgcm"
        let source = base.appendingPathComponent(a.uuidString).appendingPathComponent(suffix)
        let target = base.appendingPathComponent(b.uuidString).appendingPathComponent(suffix)
        try Data(contentsOf: source).write(to: target)
        do { _ = try await repository.attachmentData(caseID: b, encounterID: encounter, id: value.attachment.id, upload: false); XCTFail("Foreign ciphertext accepted") } catch {}
        try await repository.removeCaseFiles(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
}
