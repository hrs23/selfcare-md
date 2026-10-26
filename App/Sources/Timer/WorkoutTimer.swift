import HealthKit
import Observation
import SelfcareCore
import SwiftUI

struct TimerState: Codable, Equatable {
    var type: String
    var start: Date
    var pauseStarts: [Date] = []
    var pauseEnds: [Date] = []

    var paused: Bool { pauseStarts.count > pauseEnds.count }

    func elapsed(at now: Date) -> TimeInterval {
        var paused: TimeInterval = 0
        for (i, s) in pauseStarts.enumerated() {
            let e = i < pauseEnds.count ? pauseEnds[i] : now
            paused += e.timeIntervalSince(s)
        }
        return max(0, now.timeIntervalSince(start) - paused)
    }
}

@Observable
final class WorkoutTimer {
    unowned let app: AppModel
    private(set) var state: TimerState? {
        didSet { AppFiles.save(state, "timer.json") }
    }
    var saving = false

    init(model: AppModel) {
        app = model
        state = AppFiles.load(TimerState?.self, "timer.json") ?? nil
    }

    var isRunning: Bool { state != nil }

    func start(_ type: String) async {
        guard state == nil else { return }
        let store = app.health.store
        guard HKHealthStore.isHealthDataAvailable() else {
            app.alert = "Apple Health is not available"
            return
        }
        let workoutType = HKWorkoutType.workoutType()
        if store.authorizationStatus(for: workoutType) == .notDetermined {
            try? await store.requestAuthorization(toShare: [workoutType], read: [workoutType])
        }
        guard store.authorizationStatus(for: workoutType) == .sharingAuthorized else {
            app.alert = "Allow selfcare.md to save workouts in Apple Health to use the timer."
            return
        }
        app.settings.prefs.timerCounts[type, default: 0] += 1
        state = TimerState(type: type, start: Date())
    }

    func pause() {
        guard var s = state, !s.paused else { return }
        s.pauseStarts.append(Date())
        state = s
    }

    func resume() {
        guard var s = state, s.paused else { return }
        s.pauseEnds.append(Date())
        state = s
    }

    func discard() {
        state = nil
    }

    func finish() async {
        guard var s = state, !saving, let activity = HealthTypes.activityType(for: s.type) else { return }
        saving = true
        defer { saving = false }
        let end = Date()
        if s.paused { s.pauseEnds.append(end) }
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        let builder = HKWorkoutBuilder(healthStore: app.health.store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: s.start)
            var events: [HKWorkoutEvent] = []
            for (i, p) in s.pauseStarts.enumerated() where i < s.pauseEnds.count {
                events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: p, duration: 0), metadata: nil))
                events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: s.pauseEnds[i], duration: 0), metadata: nil))
            }
            if !events.isEmpty { try await builder.addWorkoutEvents(events) }
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { throw CocoaError(.fileWriteUnknown) }
            state = nil
            await app.health.importWorkout(workout)
        } catch {
            app.alert = "Could not save the workout: \(error.localizedDescription)"
        }
    }
}

struct TimerBanner: View {
    @Environment(AppModel.self) private var app
    @State private var confirmDiscard = false

    var body: some View {
        if let state = app.timer.state {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.packs.appleName(state.type)).font(.subheadline).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(DurationText.format(Int(state.elapsed(at: context.date))))
                            .font(.title.monospacedDigit().weight(.semibold))
                            .foregroundStyle(state.paused ? .secondary : .primary)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                Button {
                    if state.paused { app.timer.resume() } else { app.timer.pause() }
                } label: {
                    Image(systemName: state.paused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                Button {
                    Task { await app.timer.finish() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(app.timer.saving)
            }
            .contextMenu {
                Button(role: .destructive) { confirmDiscard = true } label: { Label("Discard", systemImage: "trash") }
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { app.timer.discard() }
            }
        }
    }
}

struct TimerStartSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var types: [String] {
        let counts = app.settings.prefs.timerCounts
        let workouts = app.packs.catalogOrder.filter { $0.hasPrefix("HKWorkoutActivityType") }
        let frequent = workouts.filter { (counts[$0] ?? 0) > 0 }.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
        let rest = workouts.filter { (counts[$0] ?? 0) == 0 }
        let all = frequent + rest
        guard !search.isEmpty else { return all }
        return all.filter { app.packs.appleName($0).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(types, id: \.self) { type in
                Button {
                    Task {
                        await app.timer.start(type)
                        dismiss()
                    }
                } label: {
                    Text(app.packs.appleName(type)).foregroundStyle(.primary)
                }
                .tint(.primary)
            }
            .themed()
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
