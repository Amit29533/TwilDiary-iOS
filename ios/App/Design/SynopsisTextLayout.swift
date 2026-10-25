import UIKit

/// Keep the same two leading lines in place when only the overflow expands.
/// TextKit measures actual glyphs, including scripts and composed characters.
@MainActor enum SynopsisTextLayout {
    struct Parts: Equatable {
        let leading: String
        let continuation: String
    }
    static func split(_ text: String, width: CGFloat) -> Parts {
        guard !text.isEmpty, width > 0 else { return Parts(leading: text, continuation: "") }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: text, attributes: [.font: UIFont.systemFont(ofSize: 15.04), .paragraphStyle: paragraph])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 2
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        let characters = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
        let offset = min(text.utf16.count, NSMaxRange(characters))
        guard offset < text.utf16.count else { return Parts(leading: text, continuation: "") }
        // Round back to a whole Character: UTF-16 offsets can land inside a composed glyph.
        let split = text.indices.last { $0.utf16Offset(in: text) <= offset } ?? text.startIndex
        return Parts(leading: String(text[..<split]), continuation: String(text[split...]))
    }
}
