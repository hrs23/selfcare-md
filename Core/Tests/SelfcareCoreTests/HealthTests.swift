import Foundation
import Testing
@testable import SelfcareCore

struct HealthPlacementTests {
    let types: Set<String> = ["HKWorkoutActivityTypeRunning", "HKWorkoutActivityTypeCycling", "HKQuantityTypeIdentifierDietaryWater", "HKCategoryTypeIdentifierSleepAnalysis", "HKWorkoutActivityTypeWalking"]

    func menu(_ name: String, _ fm: String) -> MenuFile {
        MenuFile(name: name, text: "---\n\(fm)\n---\n", appleHealthTypes: types)
    }

    var catalog: (String) -> CatalogEntry? {
        { type in
            switch type {
            case "HKWorkoutActivityTypeWalking": CatalogEntry(type: type, name: "Walking", record: .check, fields: [.distance, .duration, .heartRate])
            case "HKQuantityTypeIdentifierDietaryWater": CatalogEntry(type: type, name: "Water", record: .sets, fields: [.volume])
            case "HKCategoryTypeIdentifierSleepAnalysis": CatalogEntry(type: type, name: "Sleep", record: .check, fields: [.duration])
            default: nil
            }
        }
    }

    let run = HealthRecord(type: "HKWorkoutActivityTypeRunning", uuid: "550e8400-e29b-41d4-a716-446655440000", date: "2026-09-27", quantities: [.distance(5, .km), .duration(1680), .heartRate(150)])

    @Test func fillsPlannedLine() {
        let menus = [menu("Run A", "record: check\nfields: [distance, duration]\napple-health: HKWorkoutActivityTypeRunning")]
        let placement = HealthPlacement(menus: menus, catalog: catalog, recentMenu: { $0.first })
        var doc = DailyDocument(text: "# d\n\n## Selfcare\n\n- [ ] [[Run A]]\n\n## Memo\n")
        #expect(placement.place(run, into: &doc))
        #expect(doc.lines[4] == "- [x] [[Run A]] 5.0km × 28:00 <!-- apple-health:550E8400-E29B-41D4-A716-446655440000 -->")
        #expect(!placement.place(run, into: &doc))
    }

    @Test func manualLineThenAppend() {
        let menus = [menu("Run A", "record: check\nfields: [distance, duration, heart-rate]\napple-health: HKWorkoutActivityTypeRunning")]
        let placement = HealthPlacement(menus: menus, catalog: catalog, recentMenu: { $0.first })
        var doc = DailyDocument(text: "# d\n\n## Selfcare\n\n- [x] [[Run A]] 4.0km\n\n## Memo\n")
        placement.place(run, into: &doc)
        #expect(doc.entries[0].marker != nil)
        #expect(doc.entries[0].valueText == "5.0km × 28:00 × 150bpm")
        var second = run
        second.uuid = "550E8400-E29B-41D4-A716-446655440001"
        placement.place(second, into: &doc)
        #expect(doc.entries.count == 2)
        #expect(doc.entries[1].name == "Run A" && doc.entries[1].checkbox == true)
    }

    @Test func menuLessLine() {
        let placement = HealthPlacement(menus: [], catalog: catalog, recentMenu: { _ in nil })
        var doc = DailyDocument.new(date: "2026-09-27")
        let walk = HealthRecord(type: "HKWorkoutActivityTypeWalking", uuid: UUID().uuidString, date: "2026-09-27", quantities: [.duration(600)])
        placement.place(walk, into: &doc)
        #expect(doc.entries[0].name == "Walking")
        #expect(doc.entries[0].valueText == "10:00")
    }

    @Test func setsAddValueLines() {
        let menus = [menu("Water Sets", "record: sets\nfields: [volume]\napple-health: HKQuantityTypeIdentifierDietaryWater")]
        let placement = HealthPlacement(menus: menus, catalog: catalog, recentMenu: { $0.first })
        var doc = DailyDocument(text: "# d\n\n## Selfcare\n\n- [[Water Sets]]\n  - [ ] 250ml\n\n## Memo\n")
        for i in 0..<3 {
            let r = HealthRecord(type: "HKQuantityTypeIdentifierDietaryWater", uuid: "550E8400-E29B-41D4-A716-44665544000\(i)", date: "d", quantities: [.volume(300, .ml)])
            placement.place(r, into: &doc)
        }
        #expect(doc.entries.count == 1)
        #expect(doc.entries[0].sets.count == 3)
        #expect(doc.entries[0].sets.allSatisfy { $0.checked && $0.marker != nil && $0.valueText == "300ml" })
    }

    @Test func segmentsIntoSets() {
        let menus = [menu("Bike Intervals", "record: sets\nfields: [distance, duration]\napple-health: HKWorkoutActivityTypeCycling")]
        let placement = HealthPlacement(menus: menus, catalog: catalog, recentMenu: { $0.first })
        var doc = DailyDocument.new(date: "d")
        let r = HealthRecord(type: "HKWorkoutActivityTypeCycling", uuid: UUID().uuidString, date: "d", quantities: [.distance(10, .km)], segments: [[.distance(5, .km), .duration(600)], [.distance(5, .km), .duration(660)]])
        placement.place(r, into: &doc)
        #expect(doc.entries[0].sets.map(\.valueText) == ["5.0km × 10:00", "5.0km × 11:00"])
        #expect(Set(doc.entries[0].sets.compactMap(\.marker)).count == 1)
        #expect(!placement.place(r, into: &doc))
    }

    @Test func aggregateOverwrites() {
        let placement = HealthPlacement(menus: [], catalog: catalog, recentMenu: { _ in nil })
        var doc = DailyDocument.new(date: "d")
        placement.place(HealthRecord(type: "HKCategoryTypeIdentifierSleepAnalysis", uuid: nil, date: "d", quantities: [.duration(25200)]), into: &doc)
        placement.place(HealthRecord(type: "HKCategoryTypeIdentifierSleepAnalysis", uuid: nil, date: "d", quantities: [.duration(26100)]), into: &doc)
        #expect(doc.entries.count == 1)
        #expect(doc.entries[0].valueText == "7:15:00")
        #expect(doc.entries[0].marker == .aggregate("HKCategoryTypeIdentifierSleepAnalysis"))
    }

    @Test func skipsBrokenDaily() {
        let placement = HealthPlacement(menus: [], catalog: catalog, recentMenu: { _ in nil })
        var doc = DailyDocument(text: "# d\n")
        #expect(!placement.place(run, into: &doc))
    }

    func walk(_ date: String) -> HealthRecord {
        HealthRecord(type: "HKWorkoutActivityTypeWalking", uuid: UUID().uuidString, date: date, quantities: [.duration(600)])
    }

    @Test func applyWritesAndReportsFailures() throws {
        let vault = tempVault()
        let placement = HealthPlacement(menus: [], catalog: catalog, recentMenu: { _ in nil })
        try vault.write("daily/2026-09-02.md", "# 2026-09-02\n\n## Selfcare\n\n## Memo\n")
        try vault.writeData("daily/2026-09-03.md", Data([0xff, 0xfe]))
        try vault.write("daily/2026-09-04.md", "# broken\n")
        let records = ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05"].map(walk)
        let result = placement.apply(records, vault: vault) { date in
            if date == "2026-09-05" { throw VaultError.notUTF8(Vault.templatePath) }
            return DailyDocument.new(date: date)
        }
        #expect(result.written == ["2026-09-01", "2026-09-02"])
        #expect(Set(result.failed.keys) == ["2026-09-03", "2026-09-04", "2026-09-05"])
        #expect(result.failed["2026-09-04"]?.contains("No ## Selfcare") == true)
        #expect(try vault.read("daily/2026-09-01.md").contains("[[Walking]]"))
        #expect(try vault.read("daily/2026-09-02.md").contains("[[Walking]]"))
        #expect(try vault.readData("daily/2026-09-03.md") == Data([0xff, 0xfe]))
        #expect(try vault.read("daily/2026-09-04.md") == "# broken\n")
        #expect(!vault.exists("daily/2026-09-05.md"))
    }

    @Test func applyReportsWriteErrors() throws {
        let vault = tempVault()
        let placement = HealthPlacement(menus: [], catalog: catalog, recentMenu: { _ in nil })
        try vault.write("daily/2026-09-02.md", "# 2026-09-02\n\n## Selfcare\n\n## Memo\n")
        let daily = try vault.url("daily").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: daily)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daily) }
        let result = placement.apply([walk("2026-09-01"), walk("2026-09-02")], vault: vault) { DailyDocument.new(date: $0) }
        #expect(result.written.isEmpty)
        #expect(Set(result.failed.keys) == ["2026-09-01", "2026-09-02"])
    }

    @Test func workoutSplitOrder() {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        func spans(_ n: Int, offset: Double) -> [DateInterval] {
            (0..<n).map { DateInterval(start: t.addingTimeInterval(offset + Double($0) * 60), duration: 60) }
        }
        let laps = spans(3, offset: 0)
        let segments = spans(2, offset: 1000)
        let activities = spans(2, offset: 2000)
        #expect(WorkoutSplit.pick(laps: laps, segments: segments, activities: activities) == WorkoutSplit(source: .laps, intervals: laps))
        #expect(WorkoutSplit.pick(laps: [], segments: segments, activities: activities) == WorkoutSplit(source: .segments, intervals: segments))
        #expect(WorkoutSplit.pick(laps: [], segments: [], activities: activities) == WorkoutSplit(source: .activities, intervals: activities))
        #expect(WorkoutSplit.pick(laps: [], segments: [], activities: spans(1, offset: 0)) == nil)
        #expect(WorkoutSplit.pick(laps: [], segments: [], activities: []) == nil)
    }

    @Test func tcx() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let input = TCXInput(sport: "Running", start: start, end: start.addingTimeInterval(600), laps: [], calories: 100, heartRate: [TCXSample(start: start.addingTimeInterval(5), end: start.addingTimeInterval(5), value: 140)], distance: [TCXSample(start: start, end: start.addingTimeInterval(60), value: 200)], cadence: [], locations: [TCXLocation(time: start.addingTimeInterval(5), latitude: 35.1, longitude: 139.2, altitude: 10)])
        let xml = TCX.build(input)
        #expect(xml.contains("<Activity Sport=\"Running\">"))
        #expect(xml.contains("<DistanceMeters>200</DistanceMeters>"))
        #expect(xml.contains("<LatitudeDegrees>35.1</LatitudeDegrees>"))
        #expect(XMLParser(data: Data(xml.utf8)).parse())
    }

    @Test func tcxNonFiniteValues() async {
        await #expect(processExitsWith: .success) {
            let start = Date(timeIntervalSince1970: 1_790_000_000)
            for calories in [Double.nan, .infinity] {
                let input = TCXInput(sport: "Biking", start: start, end: start.addingTimeInterval(600), laps: [], calories: calories, heartRate: [TCXSample(start: start, end: start, value: .infinity)], distance: [], cadence: [TCXSample(start: start, end: start, value: .nan)], locations: [])
                let xml = TCX.build(input)
                precondition(xml.contains("<Calories>0</Calories>") && !xml.contains("HeartRateBpm") && !xml.contains("<Cadence>"))
                precondition(XMLParser(data: Data(xml.utf8)).parse())
            }
        }
    }
}
