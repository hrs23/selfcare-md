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

    public static func forDayLines(laps: [DateInterval], segments: [DateInterval], activities: [DateInterval]) -> WorkoutSplit? {
        first([.activities, .segments, .laps], laps: laps, segments: segments, activities: activities)
    }

    public static func forLaps(laps: [DateInterval], segments: [DateInterval], activities: [DateInterval]) -> WorkoutSplit? {
        first([.laps, .segments, .activities], laps: laps, segments: segments, activities: activities)
    }

    static func first(_ order: [Source], laps: [DateInterval], segments: [DateInterval], activities: [DateInterval]) -> WorkoutSplit? {
        for source in order {
            let intervals: [DateInterval]
            switch source {
            case .laps: intervals = laps
            case .segments: intervals = segments
            case .activities: intervals = activities.count > 1 ? activities : []
            }
            if !intervals.isEmpty { return WorkoutSplit(source: source, intervals: intervals) }
        }
        return nil
    }
}
