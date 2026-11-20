import SwiftUI

/// An ASS/SSA subtitle track's styles (from its header): sizes, colours, bold and italic, where on
/// the picture each style sits, and the script's canvas size.
struct JellyASSSheet {
    struct Style {
        var size: CGFloat = 20
        var colour = Color.white
        var outline = Color.black
        var bold = false
        var italic = false
        /// Numpad layout: 1–3 bottom, 4–6 middle, 7–9 top; left, centre, right.
        var alignment = 2
        var marginL: CGFloat = 10
        var marginR: CGFloat = 10
        var marginV: CGFloat = 10
    }
    var canvas = CGSize(width: 384, height: 288)
    var styles: [String: Style] = [:]

    init?(_ header: String?) {
        guard let header, !header.isEmpty else { return nil }
        var section = "", fields: [String] = []
        var width: CGFloat?, height: CGFloat?
        for raw in header.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            if line.hasPrefix("PlayResX:") { width = Double(line.dropFirst(9).trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
            else if line.hasPrefix("PlayResY:") { height = Double(line.dropFirst(9).trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
            else if section.contains("styles"), line.hasPrefix("Format:") {
                fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if section.contains("styles"), line.hasPrefix("Style:"), !fields.isEmpty {
                let values = line.dropFirst(6).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                func value(_ name: String) -> String? { fields.firstIndex(of: name).flatMap { values.indices.contains($0) ? values[$0] : nil } }
                var style = Style()
                if let size = value("fontsize").flatMap(Double.init) { style.size = CGFloat(size) }
                if let colour = value("primarycolour").flatMap(Self.colour) { style.colour = colour }
                if let colour = value("outlinecolour").flatMap(Self.colour) { style.outline = colour }
                style.bold = (value("bold").flatMap(Int.init) ?? 0) != 0
                style.italic = (value("italic").flatMap(Int.init) ?? 0) != 0
                if let alignment = value("alignment").flatMap(Int.init), (1...9).contains(alignment) { style.alignment = alignment }
                if let margin = value("marginl").flatMap(Double.init) { style.marginL = CGFloat(margin) }
                if let margin = value("marginr").flatMap(Double.init) { style.marginR = CGFloat(margin) }
                if let margin = value("marginv").flatMap(Double.init) { style.marginV = CGFloat(margin) }
                if let name = value("name") { styles[name] = style }
            }
        }
        // libass's rule: one side given, the other follows the 4:3 default.
        switch (width, height) {
        case let (w?, h?): canvas = CGSize(width: w, height: h)
        case let (w?, nil): canvas = CGSize(width: w, height: w * 3 / 4)
        case let (nil, h?): canvas = CGSize(width: h * 4 / 3, height: h)
        default: break
        }
    }

    /// "&H00FFFFFF" (alpha, blue, green, red) as a colour; alpha 00 is solid.
    static func colour(_ text: String) -> Color? {
        let hex = text.uppercased().replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "H", with: "")
        guard let number = UInt32(hex, radix: 16) else { return nil }
        let alpha = hex.count > 6 ? Double((number >> 24) & 0xFF) : 0
        return Color(red: Double(number & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255,
                     blue: Double((number >> 16) & 0xFF) / 255, opacity: 1 - alpha / 255)
    }

    /// One line on screen: its text with styling, where it anchors, and its style's margins.
    struct Line {
        var text: AttributedString
        var alignment: Int
        var position: CGPoint?
        var style: Style
        var marginL: CGFloat
        var marginR: CGFloat
        var marginV: CGFloat
    }

    /// Reads one raw event ("ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text", or a
    /// whole "Dialogue:" line). Drawings (\p1) are left out; animations and karaoke show as plain text.
    func line(_ raw: String, scale: CGFloat) -> Line? {
        var event = raw.trimmingCharacters(in: .whitespaces)
        var dialogue = false
        if event.hasPrefix("Dialogue:") { event = String(event.dropFirst(9)).trimmingCharacters(in: .whitespaces); dialogue = true }
        let parts = event.split(separator: ",", maxSplits: dialogue ? 9 : 8, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == (dialogue ? 10 : 9) else { return nil }
        let offset = dialogue ? 1 : 0
        let base = styles[parts[2 + offset].trimmingCharacters(in: .whitespaces)] ?? styles["Default"] ?? Style()
        func margin(_ index: Int, _ fallback: CGFloat) -> CGFloat {
            let value = CGFloat(Double(parts[index + offset].trimmingCharacters(in: .whitespaces)) ?? 0)
            return value > 0 ? value : fallback
        }
        var result = AttributedString()
        var bold = base.bold, italic = base.italic, colour = base.colour, size = base.size
        var alignment = base.alignment, position: CGPoint?, drawing = false
        var rest = Substring(parts[8 + offset])
        while !rest.isEmpty {
            if rest.first == "{", let close = rest.firstIndex(of: "}") {
                for tag in rest[rest.index(after: rest.startIndex)..<close].split(separator: "\\").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if tag.hasPrefix("an"), let value = Int(tag.dropFirst(2)), (1...9).contains(value) { alignment = value }
                    else if tag.hasPrefix("pos(") {
                        let numbers = tag.dropFirst(4).dropLast(tag.hasSuffix(")") ? 1 : 0).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        if numbers.count >= 2 { position = CGPoint(x: numbers[0], y: numbers[1]) }
                    }
                    else if tag == "b1" || (tag.hasPrefix("b") && (Int(tag.dropFirst()) ?? 0) >= 600) { bold = true }
                    else if tag == "b0" { bold = false }
                    else if tag == "i1" { italic = true }
                    else if tag == "i0" { italic = false }
                    else if tag.hasPrefix("1c&H") || tag.hasPrefix("c&H") { colour = Self.colour(String(tag.drop { $0 != "&" })) ?? colour }
                    else if tag.hasPrefix("fs"), let value = Double(tag.dropFirst(2)) { size = CGFloat(value) }
                    else if tag.hasPrefix("p"), let value = Int(tag.dropFirst()) { drawing = value > 0 }
                    else if tag == "r" { bold = base.bold; italic = base.italic; colour = base.colour; size = base.size }
                }
                rest = rest[rest.index(after: close)...]
            } else {
                let end = rest.dropFirst().firstIndex(of: "{") ?? rest.endIndex
                let chunk = String(rest[..<end]).replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\h", with: "\u{00A0}")
                if !drawing, !chunk.isEmpty {
                    var run = AttributedString(chunk)
                    var font = Font.system(size: max(10, size * scale), weight: bold ? .bold : .semibold)
                    if italic { font = font.italic() }
                    run.font = font
                    run.foregroundColor = colour
                    result += run
                }
                rest = rest[end...]
            }
        }
        guard !result.characters.isEmpty, !String(result.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Line(text: result, alignment: alignment, position: position, style: base,
                    marginL: margin(4, base.marginL), marginR: margin(5, base.marginR), marginV: margin(6, base.marginV))
    }
}

/// Styled subtitles over the picture: each line where the script puts it (by its alignment and
/// margins, or an exact position), in its colours and sizes, scaled with the picture and kept
/// inside the screen's safe area. Lines sharing a spot stack.
struct JellyASSLayer: View {
    let events: [String]
    let sheet: JellyASSSheet
    let size: CGSize
    let safe: CGRect
    let fill: JellyFill
    let originalSize: CGSize
    let userScale: Double

    var body: some View {
        let frame = pictureFrame
        let scale = frame.height / max(1, sheet.canvas.height)
        let lines = events.flatMap { $0.components(separatedBy: "\n") }.compactMap { sheet.line($0, scale: scale * CGFloat(userScale)) }
        let placed = lines.filter { $0.position != nil }
        let grouped = Dictionary(grouping: lines.filter { $0.position == nil }, by: \.alignment)
        ZStack {
            ForEach(grouped.keys.sorted(), id: \.self) { alignment in
                if let group = grouped[alignment], let first = group.first {
                    let anchor = anchorPoint(alignment, first, frame: frame, scale: scale)
                    let width = max(80, frame.width - (first.marginL + first.marginR) * scale)
                    VStack(alignment: Self.horizontal(alignment), spacing: 2) {
                        ForEach(group.indices, id: \.self) { index in styled(group[index]) }
                    }
                    .multilineTextAlignment(Self.textAlignment(alignment))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: min(width, safe.width), alignment: Self.frameAlignment(alignment))
                    .anchored(at: anchor, alignment: Self.anchor(alignment))
                }
            }
            ForEach(placed.indices, id: \.self) { index in
                let line = placed[index]
                let point = CGPoint(x: frame.minX + (line.position?.x ?? 0) * scale, y: frame.minY + (line.position?.y ?? 0) * scale)
                styled(line).multilineTextAlignment(Self.textAlignment(line.alignment)).fixedSize()
                    .anchored(at: CGPoint(x: min(max(point.x, safe.minX), safe.maxX), y: min(max(point.y, safe.minY), safe.maxY)),
                              alignment: Self.anchor(line.alignment))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func styled(_ line: JellyASSSheet.Line) -> some View {
        Text(line.text)
            .shadow(color: line.style.outline, radius: 1.2).shadow(color: line.style.outline, radius: 1.2)
            .shadow(color: .black.opacity(0.6), radius: 3)
    }

    /// The script's canvas laid over the picture as it is shown.
    private var pictureFrame: CGRect {
        let canvas = sheet.canvas
        guard canvas.width > 0, canvas.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale: CGFloat = switch fill {
        case .fit: min(size.width / canvas.width, size.height / canvas.height)
        case .fill: max(size.width / canvas.width, size.height / canvas.height)
        case .original: originalSize.width > 0 ? originalSize.width / canvas.width : min(size.width / canvas.width, size.height / canvas.height)
        }
        let shown = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2, width: shown.width, height: shown.height)
    }
    /// Where a block of lines anchors: its margins inside the picture, kept within the safe area.
    private func anchorPoint(_ alignment: Int, _ line: JellyASSSheet.Line, frame: CGRect, scale: CGFloat) -> CGPoint {
        let left = max(frame.minX + line.marginL * scale, safe.minX), right = min(frame.maxX - line.marginR * scale, safe.maxX)
        let x: CGFloat = switch (alignment - 1) % 3 {
        case 0: left
        case 2: right
        default: (left + right) / 2
        }
        let y: CGFloat = switch alignment {
        case 7...9: max(frame.minY + line.marginV * scale, safe.minY)
        case 4...6: frame.midY
        default: min(frame.maxY - line.marginV * scale, safe.maxY)
        }
        return CGPoint(x: x, y: y)
    }
    static func anchor(_ alignment: Int) -> Alignment {
        switch alignment {
        case 1: .bottomLeading
        case 3: .bottomTrailing
        case 4: .leading
        case 5: .center
        case 6: .trailing
        case 7: .topLeading
        case 8: .top
        case 9: .topTrailing
        default: .bottom
        }
    }
    static func horizontal(_ alignment: Int) -> HorizontalAlignment {
        switch (alignment - 1) % 3 { case 0: .leading; case 2: .trailing; default: .center }
    }
    static func textAlignment(_ alignment: Int) -> TextAlignment {
        switch (alignment - 1) % 3 { case 0: .leading; case 2: .trailing; default: .center }
    }
    static func frameAlignment(_ alignment: Int) -> Alignment {
        switch (alignment - 1) % 3 { case 0: .leading; case 2: .trailing; default: .center }
    }
}

private extension View {
    /// Puts the view so that its `alignment` point lands on `point` (a 1-point anchor carries it as
    /// an overlay, which keeps the view's own size).
    func anchored(at point: CGPoint, alignment: Alignment) -> some View {
        Color.clear.frame(width: 1, height: 1)
            .overlay(alignment: alignment) { self }
            .position(x: point.x, y: point.y)
    }
}
