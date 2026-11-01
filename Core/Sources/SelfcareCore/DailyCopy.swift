import Foundation

public enum DailyCopy {
    public static func blocks(from source: DailyDocument, record: (String) -> Record?) -> [[String]] {
        var blocks: [[String]] = []
        for e in source.entries where e.problem == nil {
            guard let r = record(e.name) else { continue }
            let importedLine = e.marker != nil
            let keptSets = e.sets.filter { $0.marker == nil && $0.problem == nil }
            let checkbox: Bool?
            if !e.sets.isEmpty {
                checkbox = nil
            } else {
                switch r {
                case .check: checkbox = false
                case .avoid: checkbox = true
                case .sets: checkbox = e.checkbox == nil ? nil : false
                }
            }
            let value = importedLine || r == .avoid ? "" : e.valueText
            var block = [DailyDocument.menuLine(checkbox: checkbox, link: e.link, value: value, comment: importedLine ? nil : e.comment)]
            for s in keptSets {
                block.append(DailyDocument.setLine(indent: DailyDocument.indent(of: s.raw), checked: false, value: s.valueText, comment: s.comment))
            }
            blocks.append(block)
        }
        return blocks
    }

    public static func append(_ blocks: [[String]], to doc: inout DailyDocument) {
        for block in blocks {
            doc.appendBlock(block)
        }
    }

    public static func newDaily(date: String, template: DailyDocument?, record: (String) -> Record?) -> DailyDocument {
        var doc = DailyDocument.new(date: date)
        if let template, template.fileProblem == nil {
            append(blocks(from: template, record: record), to: &doc)
        }
        return doc
    }
}
