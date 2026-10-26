import SelfcareCore
import SwiftUI

enum MenuSort: String, CaseIterable {
    case recent, name
}

struct PackCandidate: Identifiable, Hashable {
    var id: String { pack.id + "/" + menu.name }
    var pack: Pack
    var menu: MenuFile
}

struct MenuThumb: View {
    @Environment(AppModel.self) private var app
    let menu: MenuFile
    var pack: Pack?

    var body: some View {
        Group {
            if let url {
                VaultImage(url: url, contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
                    .overlay {
                        Text(String(menu.name.prefix(1)))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var url: URL? {
        guard let ref = menu.thumbnailReference else { return nil }
        if let pack {
            guard let path = ImageResolver.resolve(ref, fromDirectory: "menus", files: pack.files()) else { return nil }
            return pack.root.appendingPathComponent(path)
        }
        return app.thumbnailURL(menu)
    }
}

struct MenuListView: View {
    @Environment(AppModel.self) private var app
    var picking: Bool
    var includePacks: Bool
    var filter: ((MenuFile) -> Bool)?
    var onPick: (MenuFile) -> Void
    var onCreate: (String) -> Void
    @Binding var selection: Set<String>
    var selecting: Bool
    @State private var search = ""
    @State private var tags: Set<String> = []
    @State private var sort: MenuSort = .recent
    @State private var lastUsed: [String: String] = [:]
    @State private var expanded: Set<String> = []

    var vaultMenus: [MenuFile] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = app.menus.filter { m in
            if let filter, !filter(m) { return false }
            if !tags.isSubset(of: Set(m.tags)) { return false }
            if q.isEmpty { return true }
            return m.name.lowercased().contains(q) || m.tags.contains { $0.lowercased().contains(q) }
        }
        switch sort {
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recent:
            list.sort { a, b in
                let da = lastUsed[a.name.lowercased()] ?? ""
                let db = lastUsed[b.name.lowercased()] ?? ""
                if da != db { return da > db }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return list
    }

    var enabledPacks: [Pack] {
        app.packs.packs.filter { app.packs.isEnabled($0) }
    }

    func candidates(_ pack: Pack) -> [MenuFile] {
        let existing = app.menuNamesInVault()
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return app.packs.menus(pack).filter { m in
            if existing.contains(m.name.lowercased()) { return false }
            if let filter, !filter(m) { return false }
            if !tags.isSubset(of: Set(m.tags)) { return false }
            if q.isEmpty { return true }
            return m.name.lowercased().contains(q) || m.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var allTags: [String] {
        Array(Set(app.menus.flatMap(\.tags))).sorted()
    }

    var body: some View {
        List(selection: selecting ? $selection : nil) {
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(tags.sorted(), id: \.self) { tag in
                            Button {
                                tags.remove(tag)
                            } label: {
                                Label(tag, systemImage: "xmark")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty && !selecting {
                Section {
                    if MenuName.validate(term) == nil && !app.menuNamesInVault().contains(term.lowercased()) {
                        Button {
                            onCreate(term)
                        } label: {
                            Label("Create “\(term)”", systemImage: "plus")
                        }
                    }
                    Button {
                        app.ai.runQuick(.libraryCreate, target: "library", date: app.today(), input: term)
                        search = ""
                    } label: {
                        Label("Create with AI", systemImage: "wand.and.sparkles")
                    }
                    .disabled(app.ai.quickRunning)
                }
            }
            QuickStatusSection(target: "library")
            Section {
                ForEach(vaultMenus) { menu in
                    row(menu)
                        .tag(menu.name)
                }
            }
            if includePacks && !selecting {
                if term.isEmpty {
                    ForEach(enabledPacks) { pack in
                        let list = candidates(pack)
                        if !list.isEmpty {
                            Section {
                                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(pack.id) }, set: { if $0 { expanded.insert(pack.id) } else { expanded.remove(pack.id) } })) {
                                    ForEach(list) { menu in
                                        packRow(PackCandidate(pack: pack, menu: menu), showPack: false)
                                    }
                                } label: {
                                    Text(pack.name).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    let matches = enabledPacks.flatMap { pack in candidates(pack).map { PackCandidate(pack: pack, menu: $0) } }
                    if !matches.isEmpty {
                        Section {
                            ForEach(matches) { packRow($0, showPack: true) }
                        }
                    }
                }
            }
        }
        .themed()
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Recent").tag(MenuSort.recent)
                        Text("Name").tag(MenuSort.name)
                    }
                    if !allTags.isEmpty {
                        Section("Tags") {
                            ForEach(allTags, id: \.self) { tag in
                                Button {
                                    if tags.contains(tag) { tags.remove(tag) } else { tags.insert(tag) }
                                } label: {
                                    if tags.contains(tag) { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: tags.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .onAppear { lastUsed = app.index.lastUsed(app.vault) }
        .onChange(of: app.revision) { _, _ in lastUsed = app.index.lastUsed(app.vault) }
    }

    func row(_ menu: MenuFile) -> some View {
        Button {
            onPick(menu)
        } label: {
            HStack(spacing: 12) {
                MenuThumb(menu: menu)
                Text(menu.name).foregroundStyle(.primary)
                if menu.hasProblem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
                Spacer()
            }
        }
        .tint(.primary)
        .disabled(selecting)
    }

    func packRow(_ c: PackCandidate, showPack: Bool) -> some View {
        Button {
            do {
                try app.copyFromPack(c.pack, names: [c.menu.name])
                if let m = app.menu(c.menu.name) { onPick(m) }
            } catch {
                app.alert = error.localizedDescription
            }
        } label: {
            HStack(spacing: 12) {
                MenuThumb(menu: c.menu, pack: c.pack)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.menu.name).foregroundStyle(.primary)
                    if showPack {
                        Text(c.pack.name).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
        }
        .tint(.primary)
    }
}

struct MenuPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let title: String
    var filter: ((MenuFile) -> Bool)?
    var includePacks = true
    let onPick: (MenuFile) -> Void
    @State private var path: [String] = []
    @State private var selection: Set<String> = []

    var body: some View {
        NavigationStack(path: $path) {
            MenuListView(picking: true, includePacks: includePacks, filter: filter, onPick: { menu in
                onPick(menu)
                dismiss()
            }, onCreate: { name in
                path.append(name)
            }, selection: $selection, selecting: false)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(for: String.self) { name in
                MenuEditorView(mode: .create(name)) { menu in
                    onPick(menu)
                    dismiss()
                }
            }
        }
    }
}
