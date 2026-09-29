import Foundation

struct ChatMarkdownBlock: Sendable {
    enum Kind: Equatable, Sendable { case paragraph, heading(Int), list(String, Int), quote, code, divider }
    let kind: Kind
    let text: AttributedString
}
/// Native attributed text only: no web view, remote images, HTML execution or resource loading.
enum ChatMarkdown {
    static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in result.runs {
            if let link = run.link, !["https", "http"].contains(link.scheme?.lowercased() ?? "") { result[run.range].link = nil }
        }
        return result
    }
    static func blocks(_ text: String) -> [ChatMarkdownBlock] {
        var output: [ChatMarkdownBlock] = [], paragraph: [String] = [], code: [String] = []
        var fence: String?
        func flush() {
            if !paragraph.isEmpty { output.append(.init(kind: .paragraph, text: inline(paragraph.joined(separator: "\n")))); paragraph.removeAll(keepingCapacity: true) }
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { output.append(.init(kind: .code, text: AttributedString(code.joined(separator: "\n")))); code.removeAll(keepingCapacity: true); fence = nil }
                else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { flush(); fence = String(trimmed.prefix(3)); continue }
            if trimmed.isEmpty { flush(); continue }
            if let range = trimmed.range(of: "^#{1,6} +", options: .regularExpression) {
                flush(); let prefix = String(trimmed[range]); let body = String(trimmed[range.upperBound...])
                output.append(.init(kind: .heading(prefix.prefix { $0 == "#" }.count), text: inline(body))); continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); output.append(.init(kind: .divider, text: AttributedString(""))); continue }
            if let range = trimmed.range(of: "^(?:[-+*]|[0-9]{1,9}[.)]) +", options: .regularExpression) {
                flush(); let marker = trimmed[range].trimmingCharacters(in: .whitespaces)
                let indent = min(6, line.prefix { $0 == " " || $0 == "\t" }.count / 2)
                output.append(.init(kind: .list(["-", "+", "*"].contains(marker) ? "•" : marker, indent), text: inline(String(trimmed[range.upperBound...])))); continue
            }
            if trimmed.hasPrefix("> ") { flush(); output.append(.init(kind: .quote, text: inline(String(trimmed.dropFirst(2))))); continue }
            paragraph.append(line)
        }
        flush()
        if fence != nil { output.append(.init(kind: .code, text: AttributedString(code.joined(separator: "\n")))) }
        return output
    }
    static func plainText(_ source: String) -> String {
        blocks(source).map { block in
            let text = plainInline(block.text)
            switch block.kind {
            case .list(let marker, let indent): return String(repeating: "  ", count: indent) + marker + " " + text
            case .quote: return "> " + text
            case .divider: return "—"
            default: return text
            }
        }.joined(separator: "\n\n")
    }
    private static func plainInline(_ source: AttributedString) -> String {
        var output = "", activeLink: URL?, linkText = ""
        func finishLink() {
            if let link = activeLink, linkText != link.absoluteString { output += " (" + link.absoluteString + ")" }
            activeLink = nil; linkText = ""
        }
        for run in source.runs {
            if run.link != activeLink { finishLink(); activeLink = run.link }
            let text = String(source[run.range].characters); output += text
            if activeLink != nil { linkText += text }
        }
        finishLink(); return output
    }
    static func export(_ run: AnalysisRun) -> String {
        let status = run.status == .completed ? "KI-Antwort · fachlich ungeprüft" : "UNVOLLSTÄNDIGE KI-Antwort · fachlich ungeprüft"
        return "VetMed · " + status + "\n\n" + plainText(run.text)
    }
}

actor ChatMarkdownParser {
    static let shared = ChatMarkdownParser()
    func parse(_ text: String) throws -> [ChatMarkdownBlock] {
        try Task.checkCancellation()
        let result = ChatMarkdown.blocks(text)
        try Task.checkCancellation(); return result
    }
}
