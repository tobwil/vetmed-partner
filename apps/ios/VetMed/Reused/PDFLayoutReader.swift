import Foundation
import PDFKit

/// Geometric text reading, not a vision-model transcription. Coordinates and
/// original PDF page numbers remain authoritative; uncertain tables stay text.
enum PDFLayoutReader {
    struct Cell { let text: String; let bounds: CGRect }
    struct Row { var cells: [Cell]; var y: CGFloat; var height: CGFloat }

    static func sections(_ page: PDFPage) throws -> [String] {
        let bounds = page.bounds(for: .cropBox)
        guard page.numberOfCharacters <= 150_000 else { return [page.string ?? ""] }
        var glyphs: [Cell] = []
        var seen = Set<String>()
        for index in 0..<page.numberOfCharacters {
            if index % 512 == 0 { try Task.checkCancellation() }
            let cells: [Cell] = autoreleasepool {
                let character = page.characterBounds(at: index)
                guard character.height > 0, character.width > 0,
                  let selection = page.selectionForWord(at: CGPoint(x: character.midX, y: character.midY)) else { return [] }
            // PDF character indices/ink bounds are not NSString layout offsets.
            // Word selections provide the actual text and a stable text baseline.
                // PDFKit can return a selection spanning multiple lines even
                // for selectionForWord. Never interleave those lines by x.
                return selection.selectionsByLine().compactMap { line in
                    let value = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let box = line.bounds(for: page)
                    guard !value.isEmpty, box.width > 0, box.height > 0, box.minX.isFinite, box.minY.isFinite else { return nil }
                    return Cell(text: value, bounds: box)
                }
            }
            for cell in cells where seen.insert("\(cell.bounds)-\(cell.text)").inserted { glyphs.append(cell) }
        }
        guard !glyphs.isEmpty else { return [page.string ?? ""] }
        // A landscape spread with a genuinely empty central gutter. Do not cut a
        // full-width table just because its page happens to be landscape.
        let gutter = CGRect(x: bounds.midX - bounds.width * 0.012, y: bounds.minY + bounds.height * 0.07,
                            width: bounds.width * 0.024, height: bounds.height * 0.86)
        let split = bounds.width > bounds.height * 1.25 && !glyphs.contains { $0.bounds.intersects(gutter) }
        let regions = split
            ? [glyphs.filter { $0.bounds.midX < bounds.midX }, glyphs.filter { $0.bounds.midX >= bounds.midX }]
            : [glyphs]
        return regions.filter { !$0.isEmpty }.map { render(rows($0)) }
    }

    static func rows(_ glyphs: [Cell]) -> [Row] {
        var rows: [Row] = []
        for glyph in glyphs.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            // Compare nearby rows only, avoiding quadratic work on large pages.
            if let index = rows.indices.suffix(4).min(by: {
                abs(rows[$0].y - glyph.bounds.midY) < abs(rows[$1].y - glyph.bounds.midY)
            }), abs(rows[index].y - glyph.bounds.midY) < min(3, max(1.5, min(rows[index].height, glyph.bounds.height) * 0.20)) {
                rows[index].cells.append(glyph)
            } else { rows.append(.init(cells: [glyph], y: glyph.bounds.midY, height: glyph.bounds.height)) }
        }
        return rows.map { row in
            var cells: [Cell] = [], value = "", box = CGRect.null, last = CGRect.null
            for glyph in row.cells.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                let gap = last.isNull ? 0 : glyph.bounds.minX - last.maxX
                if !value.isEmpty && gap > row.height * 1.4 {
                    cells.append(.init(text: value, bounds: box)); value = ""; box = .null
                } else if !value.isEmpty && (gap > min(1.2, row.height * 0.10) ||
                            (value.last?.isLetter == true && glyph.text.first?.isLetter == true)) { value += " " }
                // PDFs sometimes draw the same character twice (fake bold).
                if !last.isNull && glyph.bounds == last && value.hasSuffix(glyph.text) { continue }
                value += glyph.text; box = box.union(glyph.bounds); last = glyph.bounds
            }
            if !value.isEmpty { cells.append(.init(text: value, bounds: box)) }
            return Row(cells: cells, y: row.y, height: row.height)
        }
    }

    static func render(_ rows: [Row]) -> String {
        var output: [String] = [], headers: [Cell] = [], previousY: CGFloat?
        for row in rows {
            let cells = row.cells.sorted { $0.bounds.minX < $1.bounds.minX }
            guard !cells.isEmpty else { continue }
            // Only explicit comparable quantity headers. Never infer column
            // identities from arbitrary numbers elsewhere in a drawing.
            let header = cells.filter { $0.text.range(of: #"^\d+(?:[.,]\d+)?\s*(?:kW|W|V|A|mm|cm|kg)$"#, options: .regularExpression) != nil }
            if header.count >= 2 && header.count == cells.count {
                headers = header
                output.append("\nTabellenspalten: " + headers.map(\.text).joined(separator: " | "))
                previousY = row.y; continue
            }
            if let y = previousY, y - row.y > row.height * 2.8 { output.append("") }
            previousY = row.y
            if headers.count == 2 {
                let first = headers[0].bounds.midX, second = headers[1].bounds.midX
                let halfColumn = (second - first) * 0.47
                // A spanning section heading or a new three-column table ends
                // the previous mapping. Never carry power variants into a
                // later product-series/network table on the same PDF page.
                let spanningHeading = cells.count == 1 && cells[0].bounds.minX < first - halfColumn && cells[0].bounds.maxX > second
                let duplicateColumn = headers.contains { header in cells.filter {
                    abs($0.bounds.midX - header.bounds.midX) < halfColumn
                }.count > 1 }
                if spanningHeading || duplicateColumn {
                    headers = []
                    output.append(cells.map(\.text).joined(separator: " | "))
                    continue
                }
                let bothColumns = headers.allSatisfy { header in cells.contains {
                    abs($0.bounds.midX - header.bounds.midX) < halfColumn && $0.bounds.width < (second - first) * 0.97
                } }
                var labelled = false
                let values = cells.map { cell -> String in
                    // A shared/full-width cell is NOT assigned to one variant.
                    guard bothColumns, cell.bounds.width < (second - first) * 0.97,
                          let match = headers.min(by: { abs($0.bounds.midX - cell.bounds.midX) < abs($1.bounds.midX - cell.bounds.midX) }),
                          abs(match.bounds.midX - cell.bounds.midX) < halfColumn else { return cell.text }
                    labelled = true
                    return "\(match.text): \(cell.text)"
                }
                output.append(values.joined(separator: " | "))
                // A new section spanning the whole region ends the table.
                if !labelled && cells.count == 1 && cells[0].bounds.minX < first - halfColumn && row.height > headers[0].bounds.height * 1.3 { headers = [] }
            } else { output.append(cells.map(\.text).joined(separator: " | ")) }
        }
        return output.joined(separator: "\n")
    }
}
