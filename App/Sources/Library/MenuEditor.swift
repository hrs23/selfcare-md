import PhotosUI
import SelfcareCore
import SwiftUI

extension Record {
    var label: String {
        switch self {
        case .check: "Check"
        case .avoid: "Avoid"
        case .sets: "Sets"
        }
    }
}

struct MenuEditorView: View {
    enum Mode: Hashable {
        case create(String)
        case edit(String)
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    var onSaved: ((MenuFile) -> Void)?
    @State private var draft = MenuDraft()
    @State private var tagsText = ""
    @State private var touchedRecordOrFields = false
    @State private var loaded = false
    @State private var photo: PhotosPickerItem?
    @State private var error: String?
    @State private var pickingHealth = false

    var original: MenuFile? {
        if case let .edit(name) = mode { return app.menu(name) }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .textInputAutocapitalization(.words)
                if let message = nameProblem {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Record") {
                Picker("Record", selection: Binding(get: { draft.record }, set: { draft.record = $0; touchedRecordOrFields = true })) {
                    ForEach(Record.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if draft.record != .avoid {
                Section("Fields") {
                    FieldsPicker(fields: Binding(get: { draft.fields }, set: { draft.fields = $0; touchedRecordOrFields = true }))
                }
                Section("Apple Health") {
                    Button {
                        pickingHealth = true
                    } label: {
                        HStack {
                            Text(draft.appleHealth.map { app.packs.appleName($0) } ?? "None")
                                .foregroundStyle(draft.appleHealth == nil ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Tags") {
                TextField("", text: $tagsText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Image") {
                HStack {
                    if let thumb = draft.thumbnail, let url = app.resolveImage(thumb, from: "menus") {
                        VaultImage(url: url, contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    PhotosPicker(selection: $photo, matching: .images) {
                        Text(draft.thumbnail == nil ? "Choose" : "Change")
                    }
                    Spacer()
                    if draft.thumbnail != nil {
                        Button(role: .destructive) { draft.thumbnail = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Body") {
                TextField("", text: $draft.body, axis: .vertical)
                    .lineLimit(6...)
                    .font(.body.monospaced())
            }
        }
        .themed()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(original == nil ? "New Menu" : "Edit Menu")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!draft.isValid || nameProblem != nil)
            }
        }
        .sheet(isPresented: $pickingHealth) {
            HealthTypePicker(selection: draft.appleHealth) { type in
                draft.appleHealth = type
                if let type, !touchedRecordOrFields, let entry = app.packs.catalog[type] {
                    draft.record = entry.record
                    draft.fields = entry.fields
                }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .errorAlert("Cannot save", message: $error)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            switch mode {
            case let .create(name):
                draft = MenuDraft(name: name)
            case .edit:
                if let original {
                    draft = MenuDraft(menu: original)
                    draft.body = draft.body.trimmingCharacters(in: .newlines)
                    touchedRecordOrFields = true
                }
            }
            tagsText = draft.tags.joined(separator: ", ")
        }
    }

    var nameProblem: String? {
        if draft.name.isEmpty { return nil }
        if let m = MenuName.validate(draft.name) { return m }
        let others = app.menus.filter { $0.name != original?.name }
        if others.contains(where: { $0.name.caseInsensitiveCompare(draft.name) == .orderedSame }) {
            return "A Menu with this name already exists"
        }
        return nil
    }

    func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let resized = image.preparingThumbnail(of: fit(image.size, 1200)) ?? image
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
        let path = "media/\(VaultTools.slug(draft.name))-\(UUID().uuidString.prefix(6)).jpg"
        do {
            try app.vault.writeData(path, jpeg)
            draft.thumbnail = "../" + path
        } catch {
            self.error = error.localizedDescription
        }
    }

    func fit(_ size: CGSize, _ maxSide: CGFloat) -> CGSize {
        let scale = min(1, maxSide / max(size.width, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func save() {
        draft.tags = tagsText.split(whereSeparator: { $0 == "," || $0 == "、" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if draft.record == .avoid {
            draft.fields = []
            draft.appleHealth = nil
        }
        var draft = self.draft
        let body = draft.body.trimmingCharacters(in: .newlines)
        draft.body = original != nil && !body.isEmpty ? "\n" + body : body
        do {
            if let original {
                try app.updateMenu(original, draft)
            } else {
                try app.createMenu(draft)
            }
            let saved = app.menu(draft.name)
            if let onSaved, let saved {
                onSaved(saved)
            } else {
                if original == nil {
                    replaceTop(with: .menu(draft.name))
                } else {
                    if original?.name != draft.name {
                        app.renameRoutes(old: original!.name, new: draft.name)
                    }
                    dismiss()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func replaceTop(with route: Route) {
        for keyPath in AppModel.paths {
            if case .newMenu? = app[keyPath: keyPath].last {
                app[keyPath: keyPath][app[keyPath: keyPath].count - 1] = route
                return
            }
        }
        dismiss()
    }
}

struct FieldsPicker: View {
    @Binding var fields: [Field]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Field.allCases) { field in
                let on = fields.contains(field)
                Button {
                    if on { fields.removeAll { $0 == field } } else { fields = Field.sorted(fields + [field]) }
                } label: {
                    Text(field.label)
                        .font(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(on ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct HealthTypePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let selection: String?
    let onPick: (String?) -> Void
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onPick(nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("None").foregroundStyle(.primary)
                        Spacer()
                        if selection == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(app.packs.catalogOrder.filter { search.isEmpty || app.packs.appleName($0).localizedCaseInsensitiveContains(search) }, id: \.self) { type in
                    Button {
                        onPick(type)
                        dismiss()
                    } label: {
                        HStack {
                            Text(app.packs.appleName(type)).foregroundStyle(.primary)
                            Spacer()
                            if selection == type { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .themed()
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .tint(.primary)
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
