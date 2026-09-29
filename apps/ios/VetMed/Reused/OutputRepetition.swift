import Foundation

/// Detect runaway generation, not ordinary repeated words or citation numbers.
/// Shared by inference and history filtering, so old loops cannot seed new ones.
enum OutputRepetition {
    struct Detected: LocalizedError {
        var errorDescription: String? { "Die Antwort wurde wegen einer Wiederholungsschleife gestoppt. Bitte die Frage eingrenzen oder erneut versuchen." }
    }
    static func containsLoop(_ text: String) -> Bool {
        let words = text.lowercased().replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // Three occurrences of a long phrase also detect alternating duplicate
        // bullets and loops without punctuation. Short legitimate overlaps stay.
        guard words.count >= 48 else { return false }
        var occurrences: [String: [Int]] = [:]
        for start in 0...(words.count - 16) {
            let phrase = words[start..<(start + 16)].joined(separator: " ")
            let prior = occurrences[phrase] ?? []
            if let last = prior.last, start - last < 16 { continue }
            if prior.count >= 2 { return true }
            occurrences[phrase, default: []].append(start)
        }
        return false
    }
}

/// High-precision rejection checks, NOT semantic entailment or a guarantee of
/// correctness. In particular, shared numbers can still be assigned incorrectly.
