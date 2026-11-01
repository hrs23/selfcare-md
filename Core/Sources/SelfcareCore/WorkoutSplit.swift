import Foundation

public struct WorkoutSplit: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case laps, segments, activities
    }

    public var source: Source
    public var intervals: [DateInterval]

    public init(source: Source, intervals: [DateInterval]) {
        self.source = source
        self.intervals = intervals
    }

    public static func pick(laps: [DateInterval], segments: [DateInterval], activities: [DateInterval]) -> WorkoutSplit? {
        if !laps.isEmpty { return WorkoutSplit(source: .laps, intervals: laps) }
        if !segments.isEmpty { return WorkoutSplit(source: .segments, intervals: segments) }
        if activities.count > 1 { return WorkoutSplit(source: .activities, intervals: activities) }
        return nil
    }
}
