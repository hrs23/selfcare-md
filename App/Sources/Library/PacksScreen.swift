import SelfcareCore
import SwiftUI
import UniformTypeIdentifiers

struct PacksView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var askingURL = false
    @State private var urlText = ""
    @State private var busy = false

    var body: some View {
        List {
            ForEach(app.packs.packs) { pack in
                Button {
                    app.show(.pack(pack.id))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name).foregroundStyle(.primary)
                            Text(subtitle(pack)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.packs.isEnabled(pack) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            if busy {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .themed()
        .tint(.primary)
        .navigationTitle("Packs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { importing = true } label: { Label("From Files", systemImage: "folder") }
                    Button { askingURL = true } label: { Label("From URL", systemImage: "link") }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    try app.packs.importFolder(url)
                } else {
                    try app.packs.importZip(try Data(contentsOf: url), name: url.lastPathComponent)
                }
            } catch {
                app.alert = error.localizedDescription
            }
        }
        .alert("Import from URL", isPresented: $askingURL) {
            TextField("https://…/pack.zip", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            Button("Import") { Task { await importURL() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    func subtitle(_ pack: Pack) -> String {
        let count = app.packs.menus(pack).count
        let kind = pack.isBundled ? (pack.language ?? "") : "imported"
        return "\(count) · \(kind)"
    }

    func importURL() async {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            app.alert = "Invalid URL"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SyncError.http(http.statusCode, url.lastPathComponent)
            }
            try app.packs.importZip(data, name: url.lastPathComponent)
            urlText = ""
        } catch {
            app.alert = error.localizedDescription
        }
    }
}

struct PackDetailView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var selection: Set<String> = []
    @State private var confirmDelete = false
    @State private var confirmReplace = false

    var pack: Pack? { app.packs.packs.first { $0.id == id } }

    func replaceTitle(_ existing: Set<String>) -> String {
        let count = selection.filter { existing.contains($0.lowercased()) }.count
        return count == 1 ? "Replace 1 Menu?" : "Replace \(count) Menus?"
    }

    func add(_ pack: Pack, replacing: Bool) {
        do {
            try app.copyFromPack(pack, names: selection.sorted(), replacing: replacing)
            selection = []
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            app.alert = error.localizedDescription
        }
    }

    var body: some View {
        Group {
            if let pack {
                let existing = app.menuNamesInVault()
                let menus = app.packs.menus(pack)
                List {
                    if let readme = pack.readme {
                        Section {
                            MarkdownView(text: readme)
                                .font(.callout)
                        }
                    }
                    Section {
                        ForEach(menus) { menu in
                            let inVault = existing.contains(menu.name.lowercased())
                            Button {
                                if selection.contains(menu.name) { selection.remove(menu.name) } else { selection.insert(menu.name) }
                            } label: {
                                HStack(spacing: 12) {
                                    let selected = selection.contains(menu.name)
                                    Image(systemName: selected ? "checkmark.circle.fill" : (inVault ? "checkmark.circle" : "circle"))
                                        .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                                        .font(.title3)
                                    MenuThumb(menu: menu, pack: pack)
                                    Text(menu.name).foregroundStyle(inVault && !selected ? .secondary : .primary)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .themed()
                .navigationTitle(pack.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            let enabled = app.packs.isEnabled(pack)
                            Button {
                                app.packs.setEnabled(pack, !enabled)
                            } label: {
                                Label(enabled ? "Disable" : "Enable", systemImage: enabled ? "minus.circle" : "checkmark.circle")
                            }
                            Button {
                                let available = menus.map(\.name).filter { !existing.contains($0.lowercased()) }
                                selection = selection.count == available.count ? [] : Set(available)
                            } label: { Label("Select all", systemImage: "checklist") }
                            if !pack.isBundled {
                                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button("Add \(selection.isEmpty ? "" : "(\(selection.count))")") {
                            if selection.contains(where: { existing.contains($0.lowercased()) }) {
                                confirmReplace = true
                            } else {
                                add(pack, replacing: false)
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(selection.isEmpty)
                    }
                }
                .confirmationDialog(replaceTitle(existing), isPresented: $confirmReplace, titleVisibility: .visible) {
                    Button("Replace", role: .destructive) { add(pack, replacing: true) }
                }
                .confirmationDialog("Delete \(pack.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        app.packs.delete(pack)
                        _ = app.libraryPath.popLast()
                    }
                }
            }
        }
    }
}
