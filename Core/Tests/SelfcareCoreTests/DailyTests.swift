import Foundation
import Testing
@testable import SelfcareCore

let sampleDaily = """
# 2026-08-29

## Selfcare

- [[Squat]]
  - [x] 30kg × 10
  - [ ] 30kg × 10

- [x] [[ストレッチ]]

- [x] [[朝ラン]] 5.0km × 28:00 <!-- apple-health:550E8400-E29B-41D4-A716-446655440000 -->

## Memo

Felt good.
"""

struct DailyTests {
    @Test func parse() {
        let doc = DailyDocument(text: sampleDaily)
        #expect(doc.fileProblem == nil)
        let es = doc.entries
        #expect(es.count == 3)
        #expect(es[0].name == "Squat" && es[0].checkbox == nil && es[0].sets.count == 2)
        #expect(es[0].sets[0].checked && !es[0].sets[1].checked)
        #expect(es[0].sets[0].value?.text == "30kg × 10")
        #expect(es[1].checkbox == true && es[1].value?.isEmpty == true)
        #expect(es[2].marker == .record("550E8400-E29B-41D4-A716-446655440000"))
        #expect(es[2].valueText == "5.0km × 28:00")
        #expect(doc.memo == "Felt good.")
        #expect(doc.text == sampleDaily + "\n")
    }

    @Test func problems() {
        let doc = DailyDocument(text: "# d\n\n## Selfcare\n\n- [x] [[A]] 30kg\n  - [x] 10\n- [ ] [[B]] 10.5\nhello\n")
        #expect(doc.entries[0].problem != nil)
        #expect(doc.entries[1].problem != nil)
        #expect(doc.items.contains { if case .raw = $0 { return true } else { return false } })
        #expect(DailyDocument(text: "# d\n\n## Memo\n").fileProblem != nil)
    }

    @Test func toggleAndValues() {
        var doc = DailyDocument(text: sampleDaily)
        let squat = doc.entries[0]
        doc.setSetCheck(squat.sets[1].line, true)
        #expect(doc.entries[0].sets[1].checked)
        doc.addSet(to: squat.line, value: Value([.weight(32.5, .kg), .reps(8)]), checked: true)
        #expect(doc.entries[0].sets.count == 3)
        #expect(doc.lines[doc.entries[0].sets[2].line] == "  - [x] 32.5kg × 8")
        let stretch = doc.entries[1]
        doc.setEntryCheck(stretch.line, false)
        #expect(doc.entries[1].checkbox == false)
        doc.deleteSet(doc.entries[0].sets[0].line)
        #expect(doc.entries[0].sets.count == 2)
    }

    @Test func addEntryToNewDaily() {
        var doc = DailyDocument.new(date: "2026-09-27")
        doc.addEntry(name: "Squat", record: .sets)
        doc.addEntry(name: "Stretch", record: .check)
        doc.addEntry(name: "No Snacking", record: .avoid)
        #expect(doc.text == "# 2026-09-27\n\n## Selfcare\n\n- [[Squat]]\n\n- [ ] [[Stretch]]\n\n- [x] [[No Snacking]]\n\n## Memo\n")
    }

    @Test func templateIsTight() {
        var doc = DailyDocument.newTemplate()
        doc.addEntry(name: "Squat", record: .sets)
        doc.addEntry(name: "Stretch", record: .check)
        #expect(doc.text == "## Selfcare\n\n- [[Squat]]\n- [ ] [[Stretch]]\n")
    }

    @Test func deleteAndMove() {
        var doc = DailyDocument(text: sampleDaily)
        doc.moveEntry(from: 2, to: 0)
        #expect(doc.entries.map(\.name) == ["朝ラン", "Squat", "ストレッチ"])
        doc.deleteEntry(doc.entries[1].line)
        #expect(doc.entries.map(\.name) == ["朝ラン", "ストレッチ"])
        #expect(!doc.text.contains("\n\n\n"))
        doc.deleteEntry(doc.entries[0].line)
        doc.deleteEntry(doc.entries[0].line)
        #expect(doc.text == "# 2026-08-29\n\n## Selfcare\n\n## Memo\n\nFelt good.\n")
    }

    @Test func memo() {
        var doc = DailyDocument.new(date: "2026-09-27")
        doc.setMemo("Line 1\nLine 2")
        #expect(doc.text == "# 2026-09-27\n\n## Selfcare\n\n## Memo\n\nLine 1\nLine 2\n")
        doc.setMemo("")
        #expect(doc.text == "# 2026-09-27\n\n## Selfcare\n\n## Memo\n")
    }

    @Test func completion() {
        let doc = DailyDocument(text: "## Selfcare\n\n- [[S]]\n  - [x] 10\n- [[Plan]]\n- [[NoSnack]]\n", kind: .template)
        let records: [String: Record] = ["S": .sets, "Plan": .check, "NoSnack": .avoid]
        let c = doc.completion { records[$0.name] }
        #expect(c.done == 2 && c.total == 3)
    }

    @Test func copy() {
        let source = DailyDocument(text: """
        # 2026-08-29

        ## Selfcare

        - [[Squat]]
          - [x] 30kg × 10
          - [x] 25kg × 8 <!-- apple-health:550E8400-E29B-41D4-A716-446655440000 -->
        - [x] [[Stretch]] 10:00
        - [x] [[Run]] 5.0km <!-- apple-health:550E8400-E29B-41D4-A716-446655440001 -->
        - [ ] [[No Snacking]]
        - [x] [[Missing]]
        """)
        let records: [String: Record] = ["Squat": .sets, "Stretch": .check, "Run": .check, "No Snacking": .avoid]
        let blocks = DailyCopy.blocks(from: source) { records[$0] }
        #expect(blocks == [
            ["- [[Squat]]", "  - [ ] 30kg × 10"],
            ["- [ ] [[Stretch]] 10:00"],
            ["- [ ] [[Run]]"],
            ["- [x] [[No Snacking]]"],
        ])
    }
}
