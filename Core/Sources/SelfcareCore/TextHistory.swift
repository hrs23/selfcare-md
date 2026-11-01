public struct TextHistory: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case text(String)
        case missing

        init(_ text: String?) {
            self = text.map(Target.text) ?? .missing
        }
    }

    struct Step: Sendable, Hashable {
        var before: String?
        var after: String?
    }

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []

    public init() {}

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }

    public mutating func record(before: String?, after: String?, merging: Bool = false) {
        redoSteps = []
        if merging, let last = undoSteps.last, last.after == before {
            undoSteps[undoSteps.count - 1].after = after
        } else {
            undoSteps.append(Step(before: before, after: after))
        }
    }

    public mutating func undo(disk: String?) -> Target? {
        guard let step = undoSteps.last else { return nil }
        guard step.after == disk else {
            clear()
            return nil
        }
        undoSteps.removeLast()
        redoSteps.append(step)
        return Target(step.before)
    }

    public mutating func redo(disk: String?) -> Target? {
        guard let step = redoSteps.last else { return nil }
        guard step.before == disk else {
            clear()
            return nil
        }
        redoSteps.removeLast()
        undoSteps.append(step)
        return Target(step.after)
    }

    public mutating func clear() {
        undoSteps = []
        redoSteps = []
    }
}
