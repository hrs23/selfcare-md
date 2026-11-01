import Testing
@testable import SelfcareCore

struct TextHistoryTests {
    @Test func undoAndRedoWhileDiskMatches() {
        var h = TextHistory()
        h.record(before: nil, after: "a\n")
        h.record(before: "a\n", after: "b\n")
        #expect(h.undo(disk: "b\n") == .text("a\n"))
        #expect(h.undo(disk: "a\n") == .missing)
        #expect(!h.canUndo && h.canRedo)
        #expect(h.redo(disk: nil) == .text("a\n"))
        #expect(h.redo(disk: "a\n") == .text("b\n"))
        #expect(h.canUndo && !h.canRedo)
    }

    @Test func changedDiskClearsHistory() {
        var h = TextHistory()
        h.record(before: nil, after: "a\n")
        h.record(before: "a\n", after: "b\n")
        #expect(h.undo(disk: "b from sync\n") == nil)
        #expect(!h.canUndo && !h.canRedo)

        h.record(before: "a\n", after: "b\n")
        #expect(h.undo(disk: "b\n") == .text("a\n"))
        #expect(h.redo(disk: "a with memo\n") == nil)
        #expect(!h.canUndo && !h.canRedo)
    }

    @Test func mergingExtendsTheLastStep() {
        var h = TextHistory()
        h.record(before: "a\n", after: "b\n")
        h.record(before: "b\n", after: "c\n", merging: true)
        #expect(h.undo(disk: "c\n") == .text("a\n"))
        #expect(!h.canUndo)

        var other = TextHistory()
        other.record(before: "a\n", after: "b\n")
        other.record(before: "x\n", after: "y\n", merging: true)
        #expect(other.undo(disk: "y\n") == .text("x\n"))
        #expect(other.canUndo)
    }

    @Test func newChangeDropsRedo() {
        var h = TextHistory()
        h.record(before: "a\n", after: "b\n")
        #expect(h.undo(disk: "b\n") == .text("a\n"))
        h.record(before: "a\n", after: "c\n")
        #expect(!h.canRedo)
    }
}
