import SwiftUI
import UniformTypeIdentifiers

/// A frozen text value advertised as text, rather than an inferred attachment or URL.
final class SharedTextItem: NSObject, UIActivityItemSource {
    let text: String
    init(_ text: String) { self.text = text }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { text as NSString }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { text as NSString }
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { UTType.utf8PlainText.identifier }
}
struct SharePayload: Identifiable {
    enum Content { case text(String), file(URL) }
    let id = UUID()
    let content: Content
    let reportID: UUID?
    let format: String
}
struct ActivitySheet: UIViewControllerRepresentable {
    let content: SharePayload.Content
    let completion: (Bool, Error?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any]
        switch content { case .text(let text): items = [SharedTextItem(text)]; case .file(let url): items = [url] }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in completion(completed, error) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
