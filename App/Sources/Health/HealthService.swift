import CoreLocation
import Foundation
import HealthKit
import Observation
import SelfcareCore

@Observable
final class HealthService {
    unowned let app: AppModel
    let store = HKHealthStore()
    var rangeProgress: Double?
    var rangeTask: Task<Void, Never>?
    var lastError: String?
    private var observers: [HKObserverQuery] = []
    private var autoRunning = false

    init(model: AppModel) {
        app = model
        if settings.autoImport { registerObservers() }
    }

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    var settings: HealthSettings {
        get { app.settings.prefs.health }
        set { app.settings.prefs.health = newValue }
    }

    var enabledTypes: Set<String> {
        Set(settings.enabledTypes ?? HealthTypes.defaultEnabled)
    }

    func setEnabled(_ key: String, _ on: Bool) {
        var set = enabledTypes
        if on { set.insert(key) } else { set.remove(key) }
        settings.enabledTypes = Array(set).sorted()
        if settings.autoImport {
            Task {
                try? await requestAuthorization()
                registerObservers()
            }
        }
    }

    var workoutsEnabled: Bool { enabledTypes.contains(HealthTypes.workoutKey) }

    var enabledOthers: [HealthTypeDef] {
        HealthTypes.others.filter { enabledTypes.contains($0.constant) }
    }

    func readTypes() -> Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if workoutsEnabled {
            types.insert(HKWorkoutType.workoutType())
            types.insert(HKSeriesType.workoutRoute())
            types.insert(HKQuantityType(.heartRate))
            types.insert(HKQuantityType(.activeEnergyBurned))
            types.insert(HKQuantityType(.cyclingCadence))
            for d in HealthTypes.distanceTypes { types.insert(HKQuantityType(d)) }
        }
        for def in enabledOthers {
            for t in def.readTypes { types.insert(t) }
            if case .bloodPressure = def.kind { types.insert(HKCorrelationType(.bloodPressure)) }
        }
        return types
    }

    func requestAuthorization() async throws {
        guard available else { throw HealthError.unavailable }
        let types = readTypes()
        let read = types.filter { !($0 is HKCorrelationType) }
        try await store.requestAuthorization(toShare: [], read: read)
        settings.requested = true
    }

    func setAutoImport(_ on: Bool) async {
        if on {
            do {
                try await requestAuthorization()
                settings.autoImport = true
                if settings.autoSince == nil { settings.autoSince = Date() }
                registerObservers()
                await importAutomatically()
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            settings.autoImport = false
            for q in observers { store.stop(q) }
            observers = []
            try? await store.disableAllBackgroundDelivery()
        }
    }

    func registerObservers() {
        for q in observers { store.stop(q) }
        observers = []
        guard available, settings.autoImport else { return }
        var types: [HKSampleType] = enabledOthers.map(\.sampleType)
        if workoutsEnabled { types.append(HKWorkoutType.workoutType()) }
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil else {
                    completion()
                    return
                }
                nonisolated(unsafe) let done = completion
                Task { @MainActor in
                    await self?.importAutomatically()
                    done()
                }
            }
            store.execute(query)
            observers.append(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    enum HealthError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Apple Health is not available" }
    }

    func importAutomatically() async {
        guard available, settings.autoImport, !autoRunning, let since = settings.autoSince else { return }
        autoRunning = true
        defer { autoRunning = false }
        var records: [HealthRecord] = []
        var aggregateDays: [String: Set<String>] = [:]
        var workouts: [HKWorkout] = []
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        do {
            if workoutsEnabled {
                let (samples, anchor) = try await anchored(HKWorkoutType.workoutType(), predicate: predicate, key: HealthTypes.workoutKey)
                for case let w as HKWorkout in samples {
                    if let r = await workoutRecord(w) {
                        records.append(r)
                        workouts.append(w)
                    }
                }
                saveAnchor(anchor, key: HealthTypes.workoutKey)
            }
            for def in enabledOthers {
                let (samples, anchor) = try await anchored(def.sampleType, predicate: predicate, key: def.constant)
                if def.aggregate {
                    for s in samples {
                        aggregateDays[def.constant, default: []].insert(aggregateDay(for: s, def: def))
                    }
                } else {
                    records.append(contentsOf: samples.compactMap { record(for: $0, def: def) })
                }
                saveAnchor(anchor, key: def.constant)
            }
            for (constant, days) in aggregateDays {
                guard let def = HealthTypes.def(constant) else { continue }
                for day in days {
                    if let r = try await aggregate(def, day: day) { records.append(r) }
                }
            }
            apply(records)
            for w in workouts { await exportTCX(w) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func anchored(_ type: HKSampleType, predicate: NSPredicate, key: String) async throws -> ([HKSample], HKQueryAnchor?) {
        let anchor = settings.anchors[key].flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.sample(type: type, predicate: predicate)], anchor: anchor)
        let result = try await descriptor.result(for: store)
        return (result.addedSamples, result.newAnchor)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor?, key: String) {
        guard let anchor, let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        settings.anchors[key] = data
    }

    func importDay(_ date: String) async {
        guard available, settings.requested, let start = DayDate.date(date), let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        do {
            try await importInterval(start: start, end: end)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startRangeImport(from: Date, to: Date) {
        rangeTask?.cancel()
        rangeProgress = 0
        rangeTask = Task {
            do {
                try await requestAuthorization()
                let cal = Calendar.current
                var day = cal.startOfDay(for: from)
                let last = cal.startOfDay(for: to)
                let total = max(1, (cal.dateComponents([.day], from: day, to: last).day ?? 0) + 1)
                var done = 0
                while day <= last, !Task.isCancelled {
                    let chunkEnd = min(cal.date(byAdding: .day, value: 7, to: day)!, cal.date(byAdding: .day, value: 1, to: last)!)
                    try await importInterval(start: day, end: chunkEnd)
                    done += cal.dateComponents([.day], from: day, to: chunkEnd).day ?? 1
                    rangeProgress = Double(done) / Double(total)
                    day = chunkEnd
                }
            } catch {
                lastError = error.localizedDescription
            }
            rangeProgress = nil
            rangeTask = nil
        }
    }

    func cancelRangeImport() {
        rangeTask?.cancel()
    }

    private func importInterval(start: Date, end: Date) async throws {
        var records: [HealthRecord] = []
        var workouts: [HKWorkout] = []
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        if workoutsEnabled {
            let d = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.endDate)])
            for w in try await d.result(for: store) {
                try Task.checkCancellation()
                if let r = await workoutRecord(w) {
                    records.append(r)
                    workouts.append(w)
                }
            }
        }
        for def in enabledOthers {
            try Task.checkCancellation()
            if def.aggregate {
                var day = start
                while day < end {
                    if let r = try await aggregate(def, day: DayDate.string(day)) { records.append(r) }
                    day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                }
            } else {
                let d = HKSampleQueryDescriptor(predicates: [.sample(type: def.sampleType, predicate: predicate)], sortDescriptors: [SortDescriptor(\.endDate)])
                records.append(contentsOf: try await d.result(for: store).compactMap { record(for: $0, def: def) })
            }
        }
        apply(records)
        for w in workouts { await exportTCX(w) }
    }

    func apply(_ records: [HealthRecord]) {
        guard !records.isEmpty else { return }
        let placement = app.placement()
        var changed = false
        for (date, group) in Dictionary(grouping: records, by: \.date) {
            let result = app.loadDaily(date)
            if result.unreadable { continue }
            var doc = result.doc ?? app.newDaily(date)
            if doc.fileProblem != nil { continue }
            let before = doc.text
            for r in group.sorted(by: { ($0.uuid ?? "") < ($1.uuid ?? "") }) {
                placement.place(r, into: &doc)
            }
            if doc.text != before || result.doc == nil && doc.text != before {
                try? app.vault.write(Vault.dailyPath(date), doc.text)
                changed = true
            }
        }
        if changed { app.vaultChanged() }
    }

    private func aggregateDay(for sample: HKSample, def: HealthTypeDef) -> String {
        if def.constant == "HKCategoryTypeIdentifierSleepAnalysis" {
            return Self.sleepDay(sample.endDate)
        }
        return DayDate.string(sample.startDate)
    }

    static func sleepDay(_ date: Date) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let day = cal.startOfDay(for: date)
        return DayDate.string(hour >= 18 ? cal.date(byAdding: .day, value: 1, to: day)! : day)
    }

    private func aggregate(_ def: HealthTypeDef, day: String) async throws -> HealthRecord? {
        guard let start = DayDate.date(day), let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        switch def.kind {
        case .category(.sleepAnalysis):
            let cal = Calendar.current
            let windowStart = cal.date(byAdding: .hour, value: -6, to: start)!
            let windowEnd = cal.date(byAdding: .hour, value: 18, to: start)!
            let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: [])
            let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate)])
            let samples = try await d.result(for: store).filter { HealthTypes.asleepValues.contains($0.value) }
            var intervals = samples.map { (max($0.startDate, windowStart), min($0.endDate, windowEnd)) }.filter { $0.0 < $0.1 }
            intervals.sort { $0.0 < $1.0 }
            var total: TimeInterval = 0
            var current: (Date, Date)?
            for i in intervals {
                if let c = current, i.0 <= c.1 {
                    current = (c.0, max(c.1, i.1))
                } else {
                    if let c = current { total += c.1.timeIntervalSince(c.0) }
                    current = i
                }
            }
            if let c = current { total += c.1.timeIntervalSince(c.0) }
            guard total > 0 else { return nil }
            return HealthRecord(type: def.constant, uuid: nil, date: day, quantities: [.duration(Int(total.rounded()))])
        case let .quantity(id):
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let d = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate), options: .cumulativeSum)
            guard let sum = try await d.result(for: store)?.sumQuantity() else { return nil }
            let q: Quantity
            switch id {
            case .stepCount: q = .reps(Int(sum.doubleValue(for: .count()).rounded()))
            case .activeEnergyBurned: q = .energy(sum.doubleValue(for: .kilocalorie()).rounded())
            case .appleExerciseTime: q = .duration(Int((sum.doubleValue(for: .minute()) * 60).rounded()))
            default: return nil
            }
            if q.numbers.first == 0 { return nil }
            return HealthRecord(type: def.constant, uuid: nil, date: day, quantities: [q])
        default:
            return nil
        }
    }

    private func record(for sample: HKSample, def: HealthTypeDef) -> HealthRecord? {
        let units = app.units
        let date = DayDate.string(sample.endDate)
        let uuid = sample.uuid.uuidString
        var quantities: [Quantity] = []
        switch def.kind {
        case .category:
            quantities = [.duration(Int(sample.endDate.timeIntervalSince(sample.startDate).rounded()))]
        case let .quantity(id):
            guard let q = sample as? HKQuantitySample else { return nil }
            switch id {
            case .bodyMass: quantities = [Quantity.weight(q.quantity.doubleValue(for: .gramUnit(with: .kilo)), .kg).converted(to: units)]
            case .bodyFatPercentage: quantities = [.percent(q.quantity.doubleValue(for: .percent()) * 100)]
            case .bodyTemperature: quantities = [Quantity.temperature(q.quantity.doubleValue(for: .degreeCelsius()), .celsius).converted(to: units)]
            case .restingHeartRate: quantities = [.heartRate(q.quantity.doubleValue(for: .count().unitDivided(by: .minute())).rounded())]
            case .dietaryWater: quantities = [Quantity.volume(q.quantity.doubleValue(for: .literUnit(with: .milli)), .ml).converted(to: units)]
            case .numberOfAlcoholicBeverages: quantities = [.reps(Int(q.quantity.doubleValue(for: .count()).rounded()))]
            default: return nil
            }
        case .bloodPressure:
            guard let c = sample as? HKCorrelation,
                  let sys = c.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample,
                  let dia = c.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample else { return nil }
            quantities = [.bloodPressure(Int(sys.quantity.doubleValue(for: .millimeterOfMercury()).rounded()), Int(dia.quantity.doubleValue(for: .millimeterOfMercury()).rounded()))]
        }
        return HealthRecord(type: def.constant, uuid: uuid, date: date, quantities: quantities)
    }

    private func distance(of stats: [HKQuantityType: HKStatistics]) -> Double? {
        for id in HealthTypes.distanceTypes {
            if let sum = stats[HKQuantityType(id)]?.sumQuantity() {
                return sum.doubleValue(for: .meter())
            }
        }
        return nil
    }

    private func workoutQuantities(duration: TimeInterval, meters: Double?, heartRate: Double?) -> [Quantity] {
        var q: [Quantity] = [.duration(Int(duration.rounded()))]
        if let meters, meters > 0 { q.append(Quantity.distance(meters / 1000, .km).converted(to: app.units)) }
        if let heartRate, heartRate > 0 { q.append(.heartRate(heartRate.rounded())) }
        return q
    }

    func workoutRecord(_ w: HKWorkout) async -> HealthRecord? {
        guard let type = HealthTypes.constant(for: w.workoutActivityType), app.packs.catalog[type] != nil else { return nil }
        let hr = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
        let whole = workoutQuantities(duration: w.duration, meters: distance(of: w.allStatistics), heartRate: hr)
        var segments: [[Quantity]] = []
        let activities = w.workoutActivities
        if activities.count > 1 {
            for a in activities {
                let ahr = a.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
                segments.append(workoutQuantities(duration: a.duration, meters: distance(of: a.allStatistics), heartRate: ahr))
            }
        } else {
            let intervals = Self.intervals(w)
            for i in intervals {
                segments.append(await intervalQuantities(w, i))
            }
        }
        return HealthRecord(type: type, uuid: w.uuid.uuidString, date: DayDate.string(w.endDate), quantities: whole, segments: segments)
    }

    static func intervals(_ w: HKWorkout) -> [DateInterval] {
        let events = w.workoutEvents ?? []
        let segments = events.filter { $0.type == .segment }.map(\.dateInterval)
        if !segments.isEmpty { return segments }
        return events.filter { $0.type == .lap }.map(\.dateInterval)
    }

    private func intervalQuantities(_ w: HKWorkout, _ interval: DateInterval) async -> [Quantity] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        var meters: Double?
        for id in HealthTypes.distanceTypes {
            let d = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate), options: .cumulativeSum)
            if let sum = try? await d.result(for: store)?.sumQuantity() {
                meters = sum.doubleValue(for: .meter())
                break
            }
        }
        let hrd = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: predicate), options: .discreteAverage)
        let hr = (try? await hrd.result(for: store))??.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
        return workoutQuantities(duration: interval.duration, meters: meters, heartRate: hr)
    }

    func workout(_ uuid: String) async -> HKWorkout? {
        guard let id = UUID(uuidString: uuid) else { return nil }
        let d = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: id))], sortDescriptors: [])
        return try? await d.result(for: store).first
    }

    private var extraCache: [String: String] = [:]

    func summaryExtra(uuid: String) async -> String? {
        if let cached = extraCache[uuid] { return cached }
        guard available, let w = await workout(uuid) else { return nil }
        guard let max = w.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) else { return nil }
        let text = "max \(Int(max.rounded()))bpm"
        extraCache[uuid] = text
        return text
    }

    func samples(_ id: HKQuantityTypeIdentifier, _ w: HKWorkout, unit: HKUnit) async -> [TCXSample] {
        let predicate = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate, options: [])
        let d = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate)])
        let result = (try? await d.result(for: store)) ?? []
        return result.map { TCXSample(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    func distanceSamples(_ w: HKWorkout) async -> [TCXSample] {
        for id in HealthTypes.distanceTypes where w.allStatistics[HKQuantityType(id)] != nil {
            return await samples(id, w, unit: .meter())
        }
        return []
    }

    func locations(_ w: HKWorkout) async -> [CLLocation] {
        let d = HKSampleQueryDescriptor(predicates: [.sample(type: HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: w))], sortDescriptors: [])
        guard let routes = try? await d.result(for: store) else { return [] }
        var all: [CLLocation] = []
        for case let route as HKWorkoutRoute in routes {
            let rd = HKWorkoutRouteQueryDescriptor(route)
            do {
                for try await location in rd.results(for: store) {
                    all.append(location)
                }
            } catch {
                continue
            }
        }
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    func exportTCX(_ w: HKWorkout) async {
        guard let type = HealthTypes.constant(for: w.workoutActivityType) else { return }
        let hr = await samples(.heartRate, w, unit: .count().unitDivided(by: .minute()))
        let dist = await distanceSamples(w)
        let sport = TCX.sport(for: type)
        let cadence = sport == "Biking" ? await samples(.cyclingCadence, w, unit: .count().unitDivided(by: .minute())) : []
        let locs = await locations(w)
        var laps = (w.workoutEvents ?? []).filter { $0.type == .lap }.map(\.dateInterval)
        if laps.isEmpty { laps = (w.workoutEvents ?? []).filter { $0.type == .segment }.map(\.dateInterval) }
        if laps.isEmpty && w.workoutActivities.count > 1 {
            laps = w.workoutActivities.map { DateInterval(start: $0.startDate, end: $0.endDate ?? $0.startDate) }
        }
        let calories = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let input = TCXInput(
            sport: sport, start: w.startDate, end: w.endDate, laps: laps, calories: calories,
            heartRate: hr, distance: dist, cadence: cadence,
            locations: locs.map { TCXLocation(time: $0.timestamp, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: $0.verticalAccuracy >= 0 ? $0.altitude : nil) }
        )
        let xml = TCX.build(input)
        try? app.vault.writeRaw("workouts/\(DayDate.string(w.endDate))-\(w.uuid.uuidString).tcx", xml)
    }

    func importWorkout(_ w: HKWorkout) async {
        guard let r = await workoutRecord(w) else { return }
        apply([r])
        await exportTCX(w)
    }
}
