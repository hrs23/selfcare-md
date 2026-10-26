import SelfcareCore
import SwiftUI

struct LibraryScreen: View {
    @Environment(AppModel.self) private var app
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var exportName = ""
    @State private var askingName = false
    @State private var shareURL: URL?

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.libraryPath) {
            MenuListView(picking: false, includePacks: false, filter: nil, onPick: { menu in
                app.show(.menu(menu.name))
            }, onCreate: { name in
                app.show(.newMenu(name))
            }, selection: $selection, selecting: selecting)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selecting {
                        Button("Cancel") {
                            selecting = false
                            selection = []
                        }
                        Button("Export") { askingName = true }
                            .disabled(selection.isEmpty)
                            .fontWeight(.semibold)
                    } else {
                        Menu {
                            Button { app.show(.packs) } label: { Label("Packs", systemImage: "shippingbox") }
                            Button { selecting = true } label: { Label("Export Menus…", systemImage: "square.and.arrow.up") }
                            Button {
                                app.openChat(attachments: [], text: "Help me organize my Menus.")
                            } label: { Label("Organize with AI", systemImage: "bubble.left.and.text.bubble.right") }
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button { app.show(.newMenu("")) } label: { Image(systemName: "plus") }
                    }
                }
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
            .alert("Pack name", isPresented: $askingName) {
                TextField("Name", text: $exportName)
                Button("Export") { export() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $shareURL) { url in
                ShareSheet(items: [url])
            }
        }
    }

    func export() {
        let name = exportName.trimmingCharacters(in: .whitespaces).isEmpty ? "My Menus" : exportName.trimmingCharacters(in: .whitespaces)
        do {
            let data = try PackInstaller.export(name: name, menus: selection.sorted(), vault: app.vault)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
            try data.write(to: url, options: .atomic)
            shareURL = url
            selecting = false
            selection = []
        } catch {
            app.alert = error.localizedDescription
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
