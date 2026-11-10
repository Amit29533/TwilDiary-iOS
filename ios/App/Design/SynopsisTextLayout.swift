import UIKit

/// Keep the same four leading lines (the design's overview) in place when only the overflow expands.
/// TextKit measures actual glyphs, including scripts and composed characters.
@MainActor enum SynopsisTextLayout {
    struct Parts: Equatable {
        let leading: String
        let continuation: String
    }
    /// The first three lines use the whole `width`; only the fourth stops `lastLineReserve` short,
    /// leaving room for "… More". Expanded, the same three lines stay exactly where they were.
    static func split(_ text: String, width: CGFloat, lastLineReserve: CGFloat = 0) -> Parts {
        guard !text.isEmpty, width > 0 else { return Parts(leading: text, continuation: "") }
        let total = text.utf16.count
        let first = fitting(text, width: width, lines: 3)
        guard first < total else { return Parts(leading: text, continuation: "") }
        let start = text.indices.last { $0.utf16Offset(in: text) <= first } ?? text.startIndex
        let rest = String(text[start...]), base = start.utf16Offset(in: text)
        // The rest fits on one full line: four lines show it all, no More.
        if fitting(rest, width: width, lines: 1) >= rest.utf16.count {
            return Parts(leading: text, continuation: "")
        }
        let offset = min(total, base + fitting(rest, width: max(40, width - lastLineReserve), lines: 1))
        // Round back to a whole Character: UTF-16 offsets can land inside a composed glyph.
        let split = text.indices.last { $0.utf16Offset(in: text) <= offset } ?? text.startIndex
        return Parts(leading: String(text[..<split]), continuation: String(text[split...]))
    }
    /// How many UTF-16 units of `text` fit in `lines` lines of `width`.
    private static func fitting(_ text: String, width: CGFloat, lines: Int) -> Int {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: text, attributes: [.font: UIFont.systemFont(ofSize: 17), .paragraphStyle: paragraph])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lines
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        let characters = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
        return min(text.utf16.count, NSMaxRange(characters))
    }
}
