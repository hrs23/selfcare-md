import SelfcareCore
import SwiftUI
import UIKit

struct DayScreen: View {
    @Environment(AppModel.self) private var app
    @State private var store: DayStore?
    @State private var sheet: DaySheet?

    enum DaySheet: Identifiable {
        case add, calendar, copy, reorder, timer
        var id: Self { self }
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.dayPath) {
            Group {
                if let store {
                    DayContainer(store: store, sheet: $sheet)
                }
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .onAppear {
            if store == nil { store = DayStore(app: app) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dayChanged)) { _ in
            store?.date = app.today()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDay)) { note in
            if let date = note.object as? String {
                app.dayPath = []
                store?.date = date
            }
        }
        .onChange(of: app.tab) { _, tab in
            if tab != .day { store?.clearAllHistory() }
        }
    }
}

private struct DayContainer: View {
    @Environment(AppModel.self) private var app
    @Bindable var store: DayStore
    @Binding var sheet: DayScreen.DaySheet?

    var model: DayModel { store.current }

    var body: some View {
        DayPager(store: store, app: app)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(DayTitle.text(store.date, today: app.today()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        sheet = .calendar
                    } label: {
                        HStack(spacing: 4) {
                            Text(DayTitle.text(store.date, today: app.today())).font(.headline)
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    if model.canUndo || model.canRedo {
                        Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .disabled(!model.canUndo)
                        Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                            .disabled(!model.canRedo)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        DaySecondaryActions(model: model, sheet: $sheet)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    Button {
                        sheet = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(model.doc?.fileProblem != nil || model.unreadable)
                }
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .add:
                    MenuPickerSheet(title: "Add") { menu in
                        model.add(menu: menu)
                    }
                case .calendar:
                    CalendarSheet(date: store.date) { store.date = $0 }
                case .copy:
                    CopySheet(target: store.date) { doc in model.copy(from: doc) }
                case .reorder:
                    ReorderSheet(model: model)
                case .timer:
                    TimerStartSheet()
                }
            }
    }
}

struct DaySecondaryActions: View {
    @Environment(AppModel.self) private var app
    let model: DayModel
    @Binding var sheet: DayScreen.DaySheet?

    var body: some View {
        Button { sheet = .copy } label: { Label("Copy from…", systemImage: "doc.on.doc") }
        Button { sheet = .reorder } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
            .disabled((model.doc?.entries.count ?? 0) < 2)
        Button {
            app.ai.runQuick(.dayPlan, target: model.path, date: model.date)
        } label: { Label("Plan with AI", systemImage: "wand.and.sparkles") }
            .disabled(app.ai.quickRunning)
        Button {
            app.openChat(attachments: [model.path], text: "Let's look at this day's records and adjust them.")
        } label: { Label("Chat about this day", systemImage: "bubble.left.and.text.bubble.right") }
        Button { sheet = .timer } label: { Label("Start timer", systemImage: "stopwatch") }
            .disabled(app.timer.isRunning)
        Button {
            app.show(.markdown(model.path))
        } label: { Label("Edit Markdown", systemImage: "chevron.left.forwardslash.chevron.right") }
    }
}

enum DayTitle {
    static func text(_ date: String, today: String) -> String {
        if date == today { return "Today" }
        if date == DayDate.adding(-1, to: today) { return "Yesterday" }
        if date == DayDate.adding(1, to: today) { return "Tomorrow" }
        guard let d = DayDate.date(date) else { return date }
        let sameYear = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
        return d.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day() : .dateTime.year().month(.abbreviated).day())
    }
}

struct DayPager: UIViewControllerRepresentable {
    let store: DayStore
    let app: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .systemGroupedBackground
        pvc.setViewControllers([context.coordinator.host(store.date)], direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard let current = pvc.viewControllers?.first as? DayHost else { return }
        if current.date != store.date {
            let forward = store.date > current.date
            pvc.setViewControllers([context.coordinator.host(store.date)], direction: forward ? .forward : .reverse, animated: true)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: DayPager

        init(_ parent: DayPager) {
            self.parent = parent
        }

        func host(_ date: String) -> DayHost {
            let model = parent.store.model(date)
            return DayHost(date: date, rootView: AnyView(DayPage(model: model).environment(parent.app)))
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let h = vc as? DayHost else { return nil }
            return host(DayDate.adding(-1, to: h.date))
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let h = vc as? DayHost else { return nil }
            return host(DayDate.adding(1, to: h.date))
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let h = pvc.viewControllers?.first as? DayHost else { return }
            parent.store.date = h.date
        }
    }
}

final class DayHost: UIHostingController<AnyView> {
    let date: String

    init(date: String, rootView: AnyView) {
        self.date = date
        super.init(rootView: rootView)
        view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }
}

struct CalendarSheet: View {
    let date: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date

    init(date: String, onPick: @escaping (String) -> Void) {
        self.date = date
        self.onPick = onPick
        _selection = State(initialValue: DayDate.date(date) ?? Date())
    }

    var body: some View {
        NavigationStack {
            DatePicker("", selection: $selection, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .navigationTitle("Go to")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Today") {
                            onPick(DayDate.string(Date()))
                            dismiss()
                        }
                    }
                }
                .onChange(of: selection) { _, new in
                    onPick(DayDate.string(new))
                    dismiss()
                }
        }
        .presentationDetents([.medium, .large])
    }
}
