import AVFoundation
import SelfcareCore
import SwiftUI

struct SyncSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var confirmDisconnect = false

    var sync: SyncService { app.sync }

    var body: some View {
        Group {
            if let config = sync.config, !editing {
                List {
                    Section {
                        LabeledContent(config.kindLabel, value: config.label)
                        if let last = sync.state.lastSuccess {
                            LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let error = sync.state.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                    }
                    if let preview = sync.pendingPreview {
                        Section {
                            LabeledContent("On this iPhone", value: "\(preview.localCount)")
                            LabeledContent("On the server", value: "\(preview.remoteCount)")
                            LabeledContent("Conflicts", value: "\(preview.conflictCount)")
                            Button("Start sync") { Task { await sync.confirmInitial() } }
                            Button("Cancel", role: .destructive) { sync.disconnect() }
                        }
                    }
                    if !sync.conflicts.isEmpty {
                        Section {
                            Button {
                                app.show(.conflicts)
                            } label: {
                                LabeledContent("Conflicts", value: "\(sync.conflicts.count)")
                            }
                        }
                    }
                    Section {
                        Button { editing = true } label: { Text("Change connection") }
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                    }
                }
                .themed()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        if sync.running {
                            ProgressView()
                        } else {
                            Button("Sync now") { Task { await sync.run(trigger: .manual) } }
                                .disabled(sync.pendingPreview != nil)
                        }
                    }
                }
                .refreshable { await sync.run(trigger: .manual) }
                .confirmationDialog("Disconnect sync?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) { sync.disconnect() }
                }
            } else {
                SyncConnectForm(initial: editing ? sync.config : nil) {
                    editing = false
                }
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SyncConnectForm: View {
    @Environment(AppModel.self) private var app
    let initial: SyncConfig?
    let onDone: () -> Void
    @State private var kind = 0
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var endpoint = ""
    @State private var region = "auto"
    @State private var bucket = ""
    @State private var prefix = ""
    @State private var accessKey = ""
    @State private var secret = ""
    @State private var scanning = false
    @State private var connecting = false
    @State private var error: String?
    @State private var folders: [String]?
    @State private var chosenURL: String?
    @State private var creates: [String] = []
    @State private var loaded = false

    var folderReady: Bool { chosenURL == url }

    var folderPath: String { URL(string: url)?.path.removingPercentEncoding ?? url }

    var config: SyncConfig {
        kind == 0
            ? .webdav(WebDAVConfig(url: url.trimmingCharacters(in: .whitespaces), username: username, password: password))
            : .s3(S3Config(endpoint: endpoint.trimmingCharacters(in: .whitespaces), region: region.trimmingCharacters(in: .whitespaces), bucket: bucket.trimmingCharacters(in: .whitespaces), prefix: prefix.trimmingCharacters(in: .whitespaces), accessKey: accessKey.trimmingCharacters(in: .whitespaces), secret: secret))
    }

    var body: some View {
        Form {
            Section {
                Picker("", selection: $kind) {
                    Text("WebDAV").tag(0)
                    Text("S3").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if kind == 0 {
                Section {
                    TextField("URL", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Section {
                    Button("Choose folder") { Task { await loadFolders() } }
                        .disabled(url.isEmpty)
                    if let folders {
                        Button("This folder") { Task { await choose("") } }
                        ForEach(folders, id: \.self) { folder in
                            Button(folder) { Task { await choose(folder) } }
                        }
                    }
                }
                if folderReady {
                    Section {
                        LabeledContent("Folder", value: folderPath)
                        if !creates.isEmpty {
                            LabeledContent("Will create", value: creates.map { "\($0)/" }.joined(separator: ", "))
                        }
                    }
                }
            } else {
                Section {
                    TextField("Endpoint", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Region", text: $region).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Bucket", text: $bucket).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Prefix", text: $prefix).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Access key", text: $accessKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Secret", text: $secret)
                }
            }
            Section {
                Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .themed()
        .toolbar {
            if initial != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
            }
            ToolbarItem(placement: .confirmationAction) {
                if connecting {
                    ProgressView()
                } else {
                    Button("Connect") { Task { await connect() } }
                        .disabled(kind == 0 ? url.isEmpty || !folderReady : bucket.isEmpty)
                }
            }
        }
        .sheet(isPresented: $scanning) {
            QRScannerSheet { text in
                scanning = false
                if let c = SyncConfig.fromQR(text) { fill(c) } else { error = "Unknown QR code" }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let initial {
                fill(initial)
                if case let .webdav(w) = initial {
                    chosenURL = w.url
                    Task { await loadCreates() }
                }
            }
        }
    }

    func fill(_ c: SyncConfig) {
        switch c {
        case let .webdav(w):
            kind = 0
            url = w.url
            username = w.username
            password = w.password
        case let .s3(s):
            kind = 1
            endpoint = s.endpoint
            region = s.region
            bucket = s.bucket
            prefix = s.prefix
            accessKey = s.accessKey
            secret = s.secret
        }
    }

    func loadFolders() async {
        error = nil
        do {
            let p = try WebDAVProvider(config: WebDAVConfig(url: url, username: username, password: password))
            folders = try await p.folders(at: "")
            if folders?.isEmpty == true { error = "No folders" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func choose(_ folder: String) async {
        var base = url
        if !base.hasSuffix("/") { base += "/" }
        let encoded = folder.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        url = base + encoded + (encoded.isEmpty ? "" : "/")
        chosenURL = url
        folders = nil
        await loadCreates()
    }

    func loadCreates() async {
        creates = []
        do {
            let p = try WebDAVProvider(config: WebDAVConfig(url: url, username: username, password: password))
            let remote = Set(try await p.folders(at: ""))
            let local = Set(app.vault.list().compactMap { path -> String? in
                let parts = path.split(separator: "/")
                return parts.count > 1 ? String(parts[0]) : nil
            })
            creates = local.subtracting(remote).sorted()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect() async {
        connecting = true
        error = nil
        defer { connecting = false }
        do {
            try await app.sync.connect(config)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ConflictsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List(app.sync.conflicts) { c in
            NavigationLink(value: Route.conflict(c.path)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.path)
                    if c.localDeleted { Text("Deleted on this iPhone").font(.caption).foregroundStyle(.secondary) }
                    if c.remoteDeleted { Text("Deleted on the server").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .themed()
        .navigationTitle("Conflicts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConflictResolveView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var remote: String?
    @State private var local: String?
    @State private var merged = ""
    @State private var mode = 0
    @State private var loaded = false

    var isText: Bool { path.hasSuffix(".md") || path.hasSuffix(".tcx") || path.hasSuffix(".txt") }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("This iPhone").tag(0)
                Text("Server").tag(1)
                if isText { Text("Edit").tag(2) }
            }
            .pickerStyle(.segmented)
            .padding()
            switch mode {
            case 0:
                ScrollView { Text(local ?? "—").font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding() }
            case 1:
                ScrollView { Text(remote ?? "—").font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding() }
            default:
                CodeEditor(text: $merged, menuNames: app.menus.map(\.name), marks: EditorMarks(problems: [], missing: []))
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Menu("Resolve") {
                    Button("Keep this iPhone") { resolve(.local) }
                    Button("Keep server") { resolve(.remote) }
                    if isText && mode == 2 {
                        Button("Save edited") { resolve(.merged(Data(VaultText.normalized(merged).utf8))) }
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            local = app.vault.readIfExists(path)
            remote = await app.sync.remoteText(path)
            merged = local ?? remote ?? ""
        }
    }

    func resolve(_ r: SyncEngine.Resolution) {
        Task {
            await app.sync.resolve(path, r)
            dismiss()
        }
    }
}

struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    var body: some View {
        NavigationStack {
            QRScannerView(onScan: onScan)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        let session = AVCaptureSession()
        var preview: AVCaptureVideoPreviewLayer?
        var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.setup() }
                }
            }
        }

        func setup() {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
            nonisolated(unsafe) let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            nonisolated(unsafe) let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            Task { @MainActor in
                guard !self.done else { return }
                self.done = true
                self.onScan?(text)
            }
        }
    }
}
