import Foundation

public struct TCXSample: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var value: Double

    public init(start: Date, end: Date, value: Double) {
        self.start = start
        self.end = end
        self.value = value
    }
}

public struct TCXLocation: Sendable, Hashable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(time: Date, latitude: Double, longitude: Double, altitude: Double?) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct TCXInput: Sendable {
    public var sport: String
    public var start: Date
    public var end: Date
    public var laps: [DateInterval]
    public var calories: Double?
    public var heartRate: [TCXSample]
    public var distance: [TCXSample]
    public var cadence: [TCXSample]
    public var locations: [TCXLocation]

    public init(sport: String, start: Date, end: Date, laps: [DateInterval], calories: Double?, heartRate: [TCXSample], distance: [TCXSample], cadence: [TCXSample], locations: [TCXLocation]) {
        self.sport = sport
        self.start = start
        self.end = end
        self.laps = laps
        self.calories = calories
        self.heartRate = heartRate
        self.distance = distance
        self.cadence = cadence
        self.locations = locations
    }
}

public enum TCX {
    public static func sport(for activityType: String) -> String {
        switch activityType {
        case "HKWorkoutActivityTypeRunning", "HKWorkoutActivityTypeWheelchairRunPace": "Running"
        case "HKWorkoutActivityTypeCycling", "HKWorkoutActivityTypeHandCycling": "Biking"
        default: "Other"
        }
    }

    static func time(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    static func num(_ v: Double, _ digits: Int = 2) -> String {
        NumberText.format(v, max: digits)
    }

    public static func build(_ input: TCXInput) -> String {
        let laps = input.laps.isEmpty ? [DateInterval(start: input.start, end: max(input.end, input.start))] : input.laps.sorted { $0.start < $1.start }
        var times = Set<Date>()
        for s in input.heartRate { times.insert(s.start) }
        for s in input.distance { times.insert(s.end) }
        for s in input.cadence { times.insert(s.start) }
        for l in input.locations { times.insert(l.time) }
        let sortedTimes = times.sorted()
        let distanceSorted = input.distance.sorted { $0.end < $1.end }
        let hrSorted = input.heartRate.sorted { $0.start < $1.start }
        let cadenceSorted = input.cadence.sorted { $0.start < $1.start }
        let locationByTime = Dictionary(input.locations.map { ($0.time, $0) }, uniquingKeysWith: { a, _ in a })

        var cumulative: [(Date, Double)] = []
        var total = 0.0
        for s in distanceSorted {
            total += s.value
            cumulative.append((s.end, total))
        }
        func distance(at t: Date) -> Double? {
            guard !cumulative.isEmpty else { return nil }
            var result = 0.0
            for (time, value) in cumulative {
                if time <= t { result = value } else { break }
            }
            return result
        }
        func nearest(_ samples: [TCXSample], _ t: Date, within: TimeInterval) -> Double? {
            var best: TCXSample?
            var bestGap = Double.infinity
            for s in samples {
                let gap = abs(s.start.timeIntervalSince(t))
                if gap < bestGap { bestGap = gap; best = s }
                if s.start > t && gap > bestGap { break }
            }
            guard let best, bestGap <= within else { return nil }
            return best.value
        }

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
          <Activities>
            <Activity Sport="\(input.sport)">
              <Id>\(time(input.start))</Id>

        """
        let totalDuration = laps.reduce(0) { $0 + $1.duration }
        for (index, lap) in laps.enumerated() {
            let inLap: (Date) -> Bool = { t in
                index == laps.count - 1 ? (t >= lap.start && t <= lap.end) : (t >= lap.start && t < lap.end)
            }
            let hr = hrSorted.filter { inLap($0.start) }.map(\.value)
            let lapDistance = distanceSorted.filter { inLap($0.end) }.reduce(0) { $0 + $1.value }
            let lapCadence = cadenceSorted.filter { inLap($0.start) }.map(\.value)
            let calories = (input.calories ?? 0) * (totalDuration > 0 ? lap.duration / totalDuration : 0)
            xml += "      <Lap StartTime=\"\(time(lap.start))\">\n"
            xml += "        <TotalTimeSeconds>\(num(lap.duration, 1))</TotalTimeSeconds>\n"
            xml += "        <DistanceMeters>\(num(lapDistance, 1))</DistanceMeters>\n"
            xml += "        <Calories>\(Int(calories.rounded()))</Calories>\n"
            if !hr.isEmpty {
                xml += "        <AverageHeartRateBpm><Value>\(Int((hr.reduce(0, +) / Double(hr.count)).rounded()))</Value></AverageHeartRateBpm>\n"
                xml += "        <MaximumHeartRateBpm><Value>\(Int((hr.max() ?? 0).rounded()))</Value></MaximumHeartRateBpm>\n"
            }
            xml += "        <Intensity>Active</Intensity>\n"
            if input.sport == "Biking", !lapCadence.isEmpty {
                xml += "        <Cadence>\(min(254, Int((lapCadence.reduce(0, +) / Double(lapCadence.count)).rounded())))</Cadence>\n"
            }
            xml += "        <TriggerMethod>Manual</TriggerMethod>\n"
            let points = sortedTimes.filter(inLap)
            if !points.isEmpty {
                xml += "        <Track>\n"
                for t in points {
                    xml += "          <Trackpoint>\n"
                    xml += "            <Time>\(time(t))</Time>\n"
                    if let loc = locationByTime[t] {
                        xml += "            <Position><LatitudeDegrees>\(num(loc.latitude, 7))</LatitudeDegrees><LongitudeDegrees>\(num(loc.longitude, 7))</LongitudeDegrees></Position>\n"
                        if let alt = loc.altitude {
                            xml += "            <AltitudeMeters>\(num(alt, 1))</AltitudeMeters>\n"
                        }
                    }
                    if let d = distance(at: t) {
                        xml += "            <DistanceMeters>\(num(d, 1))</DistanceMeters>\n"
                    }
                    if let h = nearest(hrSorted, t, within: 10) {
                        xml += "            <HeartRateBpm><Value>\(Int(h.rounded()))</Value></HeartRateBpm>\n"
                    }
                    if input.sport == "Biking", let c = nearest(cadenceSorted, t, within: 10) {
                        xml += "            <Cadence>\(min(254, Int(c.rounded())))</Cadence>\n"
                    }
                    xml += "          </Trackpoint>\n"
                }
                xml += "        </Track>\n"
            }
            xml += "      </Lap>\n"
        }
        xml += """
            </Activity>
          </Activities>
        </TrainingCenterDatabase>

        """
        return xml
    }
}
