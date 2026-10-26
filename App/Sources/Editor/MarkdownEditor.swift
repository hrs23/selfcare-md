import SelfcareCore
import SwiftUI
import UIKit

struct MarkdownEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var text = ""
    @State private var original = ""
    @State private var baseline: String?
    @State private var loaded = false
    @State private var externalChange = false
    @State private var confirmLeave = false
    @State private var saveError: String?
    @State private var notice: String?

    var dirty: Bool { text != original }

    var body: some View {
        CodeEditor(text: $text, menuNames: app.menus.map(\.name), marks: marks)
            .ignoresSafeArea(.container, edges: .bottom)
            .safeAreaInset(edge: .top) {
                if externalChange {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Changed outside").font(.callout)
                        Spacer()
                        Button("Reload") { reload() }
                        Button("Keep mine") {
                            baseline = diskText()
                            externalChange = false
                        }
                    }
                    .padding(10)
                    .background(.bar)
                } else if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(.bar)
                }
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(dirty)
            .toolbar {
                if dirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            confirmLeave = true
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!dirty)
                }
            }
            .confirmationDialog("Unsaved changes", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Save") {
                    if save() { dismiss() }
                }
                Button("Discard", role: .destructive) {
                    text = original
                    dismiss()
                }
            }
            .alert("Cannot save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") {}
            } message: {
                Text(saveError ?? "")
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                baseline = diskText()
                let initial = baseline ?? defaultText()
                text = initial
                original = initial
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    checkExternal()
                }
            }
    }

    var marks: EditorMarks {
        var problems = Set<Int>()
        var missing = Set<Int>()
        if path.hasPrefix("daily/") || path == Vault.templatePath {
            let doc = DailyDocument(text: text, kind: path == Vault.templatePath ? .template : .daily)
            problems = doc.problemLines
            if doc.fileProblem != nil, let first = doc.lines.indices.first { problems.insert(first) }
            let names = app.menuNamesInVault()
            for e in doc.entries where !names.contains(e.name.lowercased()) && e.marker == nil {
                missing.insert(e.line)
            }
        } else if path.hasPrefix("menus/"), path.hasSuffix(".md") {
            let menu = MenuFile(name: "", text: text, appleHealthTypes: app.packs.appleTypes)
            if menu.hasProblem {
                let lines = text.components(separatedBy: "\n")
                var inFM = false
                for (i, line) in lines.enumerated() {
                    if line.trimmingCharacters(in: .whitespaces) == "---" {
                        if i == 0 { inFM = true; problems.insert(i); continue }
                        if inFM { problems.insert(i); break }
                    }
                    if inFM { problems.insert(i) }
                }
            }
        }
        return EditorMarks(problems: problems, missing: missing)
    }

    func diskText() -> String? {
        try? app.vault.read(path)
    }

    func defaultText() -> String {
        if path.hasPrefix("daily/"), path.hasSuffix(".md") {
            let date = String((path as NSString).lastPathComponent.dropLast(3))
            return app.newDaily(date).text
        }
        if path == Vault.templatePath { return "## Selfcare\n\n" }
        return ""
    }

    func checkExternal() {
        guard loaded, !externalChange else { return }
        let disk = diskText()
        if disk != baseline {
            if dirty {
                externalChange = true
            } else {
                let current = disk ?? defaultText()
                baseline = disk
                text = current
                original = current
                notice = "Reloaded"
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    notice = nil
                }
            }
        }
    }

    func reload() {
        baseline = diskText()
        let disk = baseline ?? defaultText()
        text = disk
        original = disk
        externalChange = false
    }

    @discardableResult
    func save() -> Bool {
        do {
            try app.vault.write(path, text)
            let saved = diskText() ?? text
            baseline = saved
            original = saved
            if text != saved { text = saved }
            externalChange = false
            app.vaultChanged()
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

struct EditorMarks: Equatable {
    var problems: Set<Int>
    var missing: Set<Int>
}

@Observable
final class CompletionModel {
    var suggestions: [String] = []
    var onPick: (String) -> Void = { _ in }
}

struct CompletionBar: View {
    let model: CompletionModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.suggestions, id: \.self) { name in
                    Button(name) { model.onPick(name) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
        .background(.bar)
    }
}

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    let menuNames: [String]
    let marks: EditorMarks

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 40, right: 8)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .systemBackground
        let host = UIHostingController(rootView: CompletionBar(model: context.coordinator.completion))
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        context.coordinator.accessory = host
        context.coordinator.completion.onPick = { [weak tv, weak coordinator = context.coordinator] name in
            guard let tv, let coordinator else { return }
            coordinator.complete(tv, name: name)
        }
        tv.text = text
        context.coordinator.highlight(tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text {
            let selected = tv.selectedRange
            tv.text = text
            tv.selectedRange = NSRange(location: min(selected.location, (text as NSString).length), length: 0)
            context.coordinator.highlight(tv)
        } else if context.coordinator.lastMarks != marks {
            context.coordinator.highlight(tv)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        let completion = CompletionModel()
        var accessory: UIHostingController<CompletionBar>?
        var lastMarks: EditorMarks?
        var prefixRange: NSRange?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            highlight(tv)
            updateCompletion(tv)
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            updateCompletion(tv)
        }

        func updateCompletion(_ tv: UITextView) {
            let ns = tv.text as NSString
            let cursor = tv.selectedRange.location
            guard tv.selectedRange.length == 0, cursor <= ns.length else { return hide(tv) }
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let before = ns.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))
            guard let open = before.range(of: "[[", options: .backwards) else { return hide(tv) }
            let typed = String(before[open.upperBound...])
            if typed.contains("]") || typed.contains("|") { return hide(tv) }
            let start = lineRange.location + (before as NSString).range(of: "[[", options: .backwards).location + 2
            prefixRange = NSRange(location: start, length: cursor - start)
            let q = typed.lowercased()
            let matches = parent.menuNames.filter { q.isEmpty || $0.lowercased().contains(q) }
                .sorted { a, b in
                    let pa = a.lowercased().hasPrefix(q)
                    let pb = b.lowercased().hasPrefix(q)
                    if pa != pb { return pa }
                    return a.localizedStandardCompare(b) == .orderedAscending
                }
            completion.suggestions = Array(matches.prefix(30))
            if matches.isEmpty { return hide(tv) }
            if tv.inputAccessoryView == nil, let view = accessory?.view {
                view.frame = CGRect(x: 0, y: 0, width: tv.bounds.width, height: 44)
                tv.inputAccessoryView = view
                tv.reloadInputViews()
            }
        }

        func hide(_ tv: UITextView) {
            prefixRange = nil
            if tv.inputAccessoryView != nil {
                tv.inputAccessoryView = nil
                tv.reloadInputViews()
            }
        }

        func complete(_ tv: UITextView, name: String) {
            guard let range = prefixRange else { return }
            let ns = tv.text as NSString
            let after = range.location + range.length
            let hasClose = after + 2 <= ns.length && ns.substring(with: NSRange(location: after, length: 2)) == "]]"
            let insert = hasClose ? name : name + "]]"
            if let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
               let end = tv.position(from: start, offset: range.length),
               let textRange = tv.textRange(from: start, to: end) {
                tv.replace(textRange, withText: insert)
                let cursor = range.location + (name as NSString).length + 2
                tv.selectedRange = NSRange(location: min(cursor, (tv.text as NSString).length), length: 0)
            }
            hide(tv)
        }

        func highlight(_ tv: UITextView) {
            lastMarks = parent.marks
            let text = tv.text ?? ""
            let ns = text as NSString
            let base = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular))
            let bold = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedSystemFont(ofSize: 15, weight: .bold))
            let storage = tv.textStorage
            let selected = tv.selectedRange
            storage.beginEditing()
            let full = NSRange(location: 0, length: ns.length)
            storage.setAttributes([.font: base, .foregroundColor: UIColor.label], range: full)
            var lineIndex = 0
            var location = 0
            var inFrontmatter = false
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let length = (line as NSString).length
                let range = NSRange(location: location, length: length)
                if i == 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
                    inFrontmatter = true
                    storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                } else if inFrontmatter {
                    storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                    if let colon = line.firstIndex(of: ":") {
                        let keyLength = (String(line[..<colon]) as NSString).length
                        storage.addAttribute(.foregroundColor, value: UIColor.systemPurple, range: NSRange(location: location, length: keyLength))
                    }
                    if line.trimmingCharacters(in: .whitespaces) == "---" { inFrontmatter = false }
                } else if line.hasPrefix("#") {
                    storage.addAttributes([.font: bold, .foregroundColor: UIColor.tintColor], range: range)
                }
                Self.apply(#"\[[ xX]\]"#, in: line, offset: location, storage: storage, attrs: [.foregroundColor: UIColor.systemGreen])
                Self.apply(#"\[\[[^\]]+\]\]"#, in: line, offset: location, storage: storage, attrs: [.foregroundColor: UIColor.systemBlue])
                Self.apply(#"<!--.*?-->"#, in: line, offset: location, storage: storage, attrs: [.foregroundColor: UIColor.tertiaryLabel])
                if parent.marks.missing.contains(lineIndex) {
                    Self.apply(#"\[\[[^\]]+\]\]"#, in: line, offset: location, storage: storage, attrs: [.foregroundColor: UIColor.systemOrange, .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue])
                }
                if parent.marks.problems.contains(lineIndex) {
                    storage.addAttribute(.backgroundColor, value: UIColor.systemOrange.withAlphaComponent(0.18), range: range)
                }
                location += length + 1
                lineIndex += 1
            }
            storage.endEditing()
            tv.selectedRange = selected
            tv.typingAttributes = [.font: base, .foregroundColor: UIColor.label]
        }

        static func apply(_ pattern: String, in line: String, offset: Int, storage: NSTextStorage, attrs: [NSAttributedString.Key: Any]) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = line as NSString
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                storage.addAttributes(attrs, range: NSRange(location: offset + m.range.location, length: m.range.length))
            }
        }
    }
}
