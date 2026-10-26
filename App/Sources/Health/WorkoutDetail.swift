import Charts
import CoreLocation
import HealthKit
import MapKit
import SelfcareCore
import SwiftUI

struct WorkoutDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let uuid: String
    @State private var workout: HKWorkout?
    @State private var loading = true
    @State private var route: [CLLocationCoordinate2D] = []
    @State private var heartRate: [TCXSample] = []
    @State private var laps: [LapInfo] = []

    struct LapInfo: Identifiable {
        let id: Int
        let duration: TimeInterval
        let meters: Double?
        let heartRate: Double?
    }

    var body: some View {
        List {
            if let w = workout {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(HealthTypes.constant(for: w.workoutActivityType).map { app.packs.appleName($0) } ?? "Workout")
                            .font(.title2.bold())
                        Text(w.startDate.formatted(date: .abbreviated, time: .shortened) + " – " + w.endDate.formatted(date: .omitted, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    StatGrid(items: stats(w))
                }
                if route.count > 1 {
                    Section {
                        Map {
                            MapPolyline(coordinates: route)
                                .stroke(Color.accentColor, lineWidth: 4)
                        }
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if heartRate.count > 1 {
                    Section("Heart rate") {
                        Chart(heartRate, id: \.start) { s in
                            LineMark(x: .value("Time", s.start), y: .value("bpm", s.value))
                                .foregroundStyle(.red)
                                .interpolationMethod(.monotone)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 160)
                    }
                }
                if !laps.isEmpty {
                    Section("Laps") {
                        ForEach(laps) { lap in
                            HStack {
                                Text("\(lap.id)").foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                                Text(DurationText.format(Int(lap.duration.rounded())))
                                Spacer()
                                if let m = lap.meters {
                                    Text(Quantity.distance(m / 1000, .km).converted(to: app.units).text)
                                }
                                if let hr = lap.heartRate {
                                    Text("\(Int(hr.rounded()))bpm").foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
                Section {
                    Button { openURL(URL(string: "fitnessapp://")!) } label: { Label("Open Fitness", systemImage: "figure.run.circle") }
                    Button { openURL(URL(string: "x-apple-health://")!) } label: { Label("Open Health", systemImage: "heart.text.square") }
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .themed()
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let w = workout {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let tcx = "workouts/\(DayDate.string(w.endDate))-\(w.uuid.uuidString).tcx"
                        var files = [Vault.dailyPath(DayDate.string(w.endDate))]
                        if app.vault.exists(tcx) { files.append(tcx) }
                        app.openChat(attachments: files, text: "Let's review this workout.")
                    } label: {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                    }
                }
            }
        }
        .task { await load() }
    }

    func load() async {
        loading = true
        defer { loading = false }
        guard let w = await app.health.workout(uuid) else {
            dismiss()
            return
        }
        workout = w
        route = await app.health.locations(w).map(\.coordinate)
        heartRate = await app.health.samples(.heartRate, w, unit: .count().unitDivided(by: .minute()))
        var intervals = (w.workoutEvents ?? []).filter { $0.type == .lap }.map(\.dateInterval)
        if intervals.isEmpty { intervals = HealthService.intervals(w) }
        let dist = await app.health.distanceSamples(w)
        laps = intervals.enumerated().map { i, interval in
            let meters = dist.filter { $0.end > interval.start && $0.end <= interval.end }.reduce(0) { $0 + $1.value }
            let hr = heartRate.filter { interval.contains($0.start) }.map(\.value)
            return LapInfo(id: i + 1, duration: interval.duration, meters: meters > 0 ? meters : nil, heartRate: hr.isEmpty ? nil : hr.reduce(0, +) / Double(hr.count))
        }
    }

    func stats(_ w: HKWorkout) -> [(String, String)] {
        var items: [(String, String)] = [("Time", DurationText.format(Int(w.duration.rounded())))]
        var meters: Double?
        for id in HealthTypes.distanceTypes {
            if let sum = w.statistics(for: HKQuantityType(id))?.sumQuantity() {
                meters = sum.doubleValue(for: .meter())
                break
            }
        }
        if let meters, meters > 0 {
            let q = Quantity.distance(meters / 1000, .km).converted(to: app.units)
            items.append(("Distance", q.text))
            if let km = q.numbers.first, km > 0 {
                let pace = Int((w.duration / km).rounded())
                items.append(("Pace", DurationText.format(pace) + "/" + (app.units.distance == .mi ? "mi" : "km")))
            }
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let hr = w.statistics(for: HKQuantityType(.heartRate)) {
            if let avg = hr.averageQuantity()?.doubleValue(for: bpm) { items.append(("Avg HR", "\(Int(avg.rounded()))bpm")) }
            if let max = hr.maximumQuantity()?.doubleValue(for: bpm) { items.append(("Max HR", "\(Int(max.rounded()))bpm")) }
        }
        if let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
            items.append(("Energy", "\(Int(kcal.rounded()))kcal"))
        }
        return items
    }
}

struct StatGrid: View {
    let items: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                    Text(item.1).font(.title3.monospacedDigit().weight(.semibold))
                }
            }
        }
        .padding(.vertical, 4)
    }
}
