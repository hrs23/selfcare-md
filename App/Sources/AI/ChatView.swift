import SelfcareCore
import SwiftUI

struct AIScreen: View {
    @Environment(AppModel.self) private var app
    @State private var session: ChatSession?
    @State private var showingList = false

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.aiPath) {
            Group {
                if !app.ai.configured {
                    List {
                        Button {
                            app.tab = .settings
                            app.settingsPath = [.aiSettings]
                        } label: {
                            Label("Set up AI", systemImage: "key")
                        }
                    }
                    .themed()
                } else if let session {
                    ChatView(session: session)
                }
            }
            .navigationTitle(session?.conversation.title.isEmpty == false ? session!.conversation.title : "AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if app.ai.configured {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingList = true } label: { Image(systemName: "list.bullet") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            session?.stop()
                            session = ChatSession(app: app)
                        } label: { Image(systemName: "square.and.pencil") }
                    }
                }
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
            .sheet(isPresented: $showingList) {
                ConversationList { conversation in
                    session?.stop()
                    session = ChatSession(app: app, conversation: conversation)
                    showingList = false
                }
            }
        }
        .onAppear {
            if session == nil { session = ChatSession(app: app) }
            consumePending()
        }
        .onChange(of: app.pendingChat) { _, _ in consumePending() }
    }

    func consumePending() {
        guard let pending = app.pendingChat else { return }
        app.pendingChat = nil
        session?.stop()
        let s = ChatSession(app: app)
        s.attachments = pending.attachments
        s.input = pending.text
        session = s
    }
}

struct ConversationList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onOpen: (Conversation) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.ai.conversations) { c in
                    Button {
                        onOpen(c)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title.isEmpty ? "Conversation" : c.title).foregroundStyle(.primary).lineLimit(1)
                            Text(c.updated.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets.map({ $0 }).sorted(by: >) { app.ai.delete(app.ai.conversations[i]) }
                }
            }
            .themed()
            .tint(.primary)
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: ChatSession
    @State private var picking = false
    @FocusState private var inputFocused: Bool

    var mentionQuery: String? {
        guard let last = session.input.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }

    var mentionMatches: [String] {
        guard let q = mentionQuery?.lowercased() else { return [] }
        return app.vault.list()
            .filter { !$0.hasPrefix(".") && (q.isEmpty || $0.lowercased().contains(q)) }
            .sorted { ($0.hasPrefix("daily/") ? 1 : 0, $1) < ($1.hasPrefix("daily/") ? 1 : 0, $0) }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.visibleMessages) { message in
                            MessageView(session: session, message: message)
                                .id(message.id)
                        }
                        if let p = session.permission {
                            PermissionCard(permission: p.permission) { session.answer($0) }
                                .id("permission")
                        }
                        if let error = session.error {
                            HStack {
                                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                                Spacer()
                            }
                        }
                        if session.canResend && !session.visibleMessages.isEmpty {
                            Button { session.resend() } label: { Label("Resend", systemImage: "arrow.clockwise") }
                                .buttonStyle(.bordered)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.conversation.messages) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.permission?.id) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if !mentionMatches.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(mentionMatches, id: \.self) { path in
                            Button {
                                if !session.attachments.contains(path) { session.attachments.append(path) }
                                var parts = session.input.split(separator: " ", omittingEmptySubsequences: false)
                                parts.removeLast()
                                session.input = parts.joined(separator: " ")
                            } label: {
                                Text(path).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(.bar)
            }
            InputBar(session: session, picking: $picking, focused: $inputFocused)
        }
        .background(Theme.canvas)
        .sheet(isPresented: $picking) {
            VaultFilePicker(selection: session.attachments) { session.attachments = $0 }
        }
    }
}

struct InputBar: View {
    @Bindable var session: ChatSession
    @Binding var picking: Bool
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 6) {
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(session.attachments, id: \.self) { path in
                            Button {
                                session.attachments.removeAll { $0 == path }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: VaultTools.isImage(path) ? "photo" : "doc.text")
                                    Text((path as NSString).lastPathComponent).lineLimit(1)
                                    Image(systemName: "xmark").font(.caption2)
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { picking = true } label: {
                    Image(systemName: "paperclip").font(.title3)
                }
                .padding(.bottom, 6)
                TextField("Message", text: $session.input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                if session.running {
                    Button { session.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.title)
                    }
                } else {
                    Button { session.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.attachments.isEmpty)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Theme.canvas)
    }
}

struct MessageView: View {
    @Environment(AppModel.self) private var app
    let session: ChatSession
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    Text(message.attachments.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let text = session.displayText(message)
                if !text.isEmpty {
                    Text(text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    MarkdownView(text: message.text)
                } else if message.toolCalls.isEmpty && session.running {
                    ProgressView()
                }
                ForEach(message.toolCalls) { call in
                    Label(Self.describe(call), systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Button {
                expanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: message.text.hasPrefix("Error") ? "xmark.circle" : "checkmark.circle")
                        Text(message.toolName ?? "tool")
                        Text(message.omitted ? "omitted" : (message.text.components(separatedBy: "\n").first ?? ""))
                            .lineLimit(1)
                    }
                    if expanded && !message.omitted {
                        Text(String(message.text.prefix(4000)))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        case .system:
            EmptyView()
        }
    }

    static func describe(_ call: ToolCall) -> String {
        let args = call.args
        let main = (args["path"] as? String) ?? (args["pattern"] as? String) ?? (args["url"] as? String) ?? (args["from"] as? String) ?? (args["prompt"] as? String) ?? ""
        return "\(call.name) \(main)"
    }
}

struct PermissionCard: View {
    let permission: ToolPermission
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(permission.title).font(.headline)
                Text(permission.path).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            if !permission.detail.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(permission.detail.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.caption.monospaced())
                                .foregroundStyle(permission.isDiff && line.hasPrefix("+") ? .green : (permission.isDiff && line.hasPrefix("-") ? .red : .primary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            HStack {
                Button("Deny", role: .destructive) { onAnswer(false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Allow") { onAnswer(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct VaultFilePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var selection: [String]
    let onDone: ([String]) -> Void
    @State private var kind = 0
    @State private var search = ""
    @State private var day = Date()

    init(selection: [String], onDone: @escaping ([String]) -> Void) {
        _selection = State(initialValue: selection)
        self.onDone = onDone
    }

    var files: [String] {
        let all = app.vault.list()
        let list: [String]
        switch kind {
        case 0: list = all.filter { $0.hasPrefix("menus/") && $0.hasSuffix(".md") }
        case 1: list = all.filter { $0.hasPrefix("daily/") && $0.hasSuffix(".md") }.sorted(by: >)
        case 2: list = all.filter { $0.hasPrefix("templates/") }
        case 3: list = all.filter { $0.hasSuffix(".tcx") }.sorted(by: >)
        default: list = all.filter { VaultTools.isImage($0) }
        }
        return search.isEmpty ? list : list.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $kind) {
                    Text("Menu").tag(0)
                    Text("Daily").tag(1)
                    Text("Template").tag(2)
                    Text("Workout").tag(3)
                    Text("Image").tag(4)
                }
                .pickerStyle(.segmented)
                .padding()
                List {
                    if kind == 1 {
                        DatePicker("Day", selection: $day, displayedComponents: .date)
                            .onChange(of: day) { _, d in
                                let path = Vault.dailyPath(DayDate.string(d))
                                if app.vault.exists(path), !selection.contains(path) { selection.append(path) }
                            }
                    }
                    ForEach(files, id: \.self) { path in
                        Button {
                            if let i = selection.firstIndex(of: path) { selection.remove(at: i) } else { selection.append(path) }
                        } label: {
                            HStack {
                                Text(kind == 0 ? String((path as NSString).lastPathComponent.dropLast(3)) : (path as NSString).lastPathComponent)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selection.contains(path) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }
                .themed()
                .searchable(text: $search)
                .tint(.primary)
            }
            .navigationTitle("Attach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(selection)
                        dismiss()
                    }
                }
            }
        }
    }
}
