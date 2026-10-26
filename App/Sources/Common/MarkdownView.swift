import SwiftUI

struct MarkdownView: View {
    let text: String
    var imageResolver: ((String) -> URL?)?

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case list([(String, String)])
        case code(String)
        case quote(String)
        case image(String, String)
        case table(String)
        case rule

        static func == (lhs: Block, rhs: Block) -> Bool { lhs.hashKey == rhs.hashKey }
        func hash(into hasher: inout Hasher) { hasher.combine(hashKey) }

        var hashKey: String {
            switch self {
            case let .heading(l, t): "h\(l)\(t)"
            case let .paragraph(t): "p\(t)"
            case let .list(items): "l" + items.map { $0.0 + $0.1 }.joined(separator: "\u{1}")
            case let .code(t): "c\(t)"
            case let .quote(t): "q\(t)"
            case let .image(a, s): "i\(a)\(s)"
            case let .table(t): "t\(t)"
            case .rule: "r"
            }
        }
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [(String, String)] = []
        var code: [String]?
        var table: [String] = []
        var quote: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !list.isEmpty { blocks.append(.list(list)); list = [] }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))); table = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            if var c = code {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(c.joined(separator: "\n")))
                    code = nil
                } else {
                    c.append(raw)
                    code = c
                }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flush()
                    blocks.append(.heading(level, String(line.dropFirst(level + 1))))
                    continue
                }
            }
            if line == "---" || line == "***" {
                flush()
                blocks.append(.rule)
                continue
            }
            if let image = imageLine(line) {
                flush()
                blocks.append(.image(image.0, image.1))
                continue
            }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty || !list.isEmpty { flush() }
                table.append(line)
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                if !paragraph.isEmpty || !list.isEmpty { flush() }
                quote.append(String(line.dropFirst(line == ">" ? 1 : 2)))
                continue
            }
            if let item = listItem(raw) {
                if !paragraph.isEmpty { flush() }
                list.append(item)
                continue
            }
            if !list.isEmpty {
                flush()
            }
            paragraph.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func imageLine(_ line: String) -> (String, String)? {
        if line.hasPrefix("!["), line.hasSuffix(")"), let mid = line.range(of: "](") {
            let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<mid.lowerBound])
            var src = String(line[mid.upperBound..<line.index(before: line.endIndex)])
            if let space = src.firstIndex(of: " ") { src = String(src[..<space]) }
            return (alt, src)
        }
        if line.hasPrefix("![["), line.hasSuffix("]]") {
            let inner = line.dropFirst(3).dropLast(2)
            let src = inner.split(separator: "|").first.map(String.init) ?? String(inner)
            return ("", src)
        }
        return nil
    }

    static func listItem(_ raw: String) -> (String, String)? {
        let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
        let line = raw.trimmingCharacters(in: .whitespaces)
        let pad = String(repeating: "  ", count: min(indent / 2, 4))
        for marker in ["- [ ] ", "- [x] ", "- [X] "] where line.hasPrefix(marker) {
            return (pad + (marker == "- [ ] " ? "○" : "●"), String(line.dropFirst(marker.count)))
        }
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (pad + "•", String(line.dropFirst(2)))
        }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
            return (pad + String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...]))
        }
        return nil
    }

    static func inline(_ s: String) -> AttributedString {
        let linked = s.replacingOccurrences(of: #"\[\[([^\]|]+)(\|([^\]]+))?\]\]"#, with: "**$1**", options: .regularExpression)
        return (try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    func view(_ block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case let .paragraph(text):
            Text(Self.inline(text))
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.0).foregroundStyle(.secondary)
                        Text(Self.inline(item.1))
                    }
                }
            }
        case let .code(text):
            ScrollView(.horizontal) {
                Text(text).font(.callout.monospaced()).padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        case let .quote(text):
            HStack(spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary)
            }
        case let .table(text):
            ScrollView(.horizontal) {
                Text(text).font(.caption.monospaced())
            }
        case let .image(alt, src):
            if let url = imageResolver?(src) {
                VaultImage(url: url)
                    .frame(maxWidth: .infinity, maxHeight: 280)
            } else if let url = URL(string: src), url.scheme?.hasPrefix("http") == true {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear.frame(height: 40)
                }
                .frame(maxHeight: 280)
            } else {
                Text(alt.isEmpty ? src : alt).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }
}

struct VaultImage: View {
    let url: URL
    var contentMode: ContentMode = .fit
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .task(id: url) {
            let url = self.url
            image = await Task.detached {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 900, height: 900))
            }.value
        }
    }
}
