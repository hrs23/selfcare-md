import SelfcareCore
import SwiftUI

struct AISettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var keyEdited = false

    var ai: AIService { app.ai }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Provider", selection: Binding(get: { ai.settings.preset }, set: { preset in
                    ai.settings.preset = preset
                    ai.settings.model = nil
                    key = ai.apiKey
                    ai.testResult = nil
                    ai.models = app.settings.prefs.modelCache[ai.cacheKey] ?? []
                    Task { await ai.refreshModels() }
                })) {
                    ForEach(AIPreset.allCases) { Text($0.label).tag($0) }
                }
                if ai.settings.preset == .custom {
                    TextField("Base URL", text: $settings.prefs.ai.customBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                SecureField("API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: key) { _, new in
                        guard new != ai.apiKey else { return }
                        ai.apiKey = new.trimmingCharacters(in: .whitespacesAndNewlines)
                        ai.testResult = nil
                        keyEdited = true
                    }
            }
            Section {
                Button {
                    keyEdited = false
                    Task { await ai.testConnection() }
                } label: {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        if ai.testing { ProgressView() }
                    }
                }
                .disabled(ai.apiKey.isEmpty || ai.testing)
                .buttonStyle(keyEdited ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.automatic))
                if let result = ai.testResult {
                    switch result {
                    case .success:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    case let .failure(error):
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("Model") {
                Picker("Model", selection: Binding(get: { ai.settings.model ?? "" }, set: { ai.settings.model = $0.isEmpty ? nil : $0 })) {
                    if ai.settings.preset != .custom {
                        Text("Default (\(ai.resolvedModel))").tag("")
                    }
                    ForEach(ai.models, id: \.self) { Text($0).tag($0) }
                    if let m = ai.settings.model, !ai.models.contains(m) {
                        Text(m).tag(m)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            if ai.settings.preset.supportsImageGeneration {
                Section {
                    Toggle("Image generation", isOn: $settings.prefs.ai.imageGeneration)
                }
            }
            Section("Custom prompt") {
                TextField("", text: $settings.prefs.ai.customPrompt, axis: .vertical)
                    .lineLimit(3...)
            }
            Section("Quick actions") {
                ForEach(QuickKind.allCases) { kind in
                    if kind != .menuImage || ai.settings.preset.supportsImageGeneration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.label).font(.caption).foregroundStyle(.secondary)
                            TextField("", text: Binding(get: { ai.settings.quickPrompts[kind.rawValue] ?? "" }, set: { ai.settings.quickPrompts[kind.rawValue] = $0 }), axis: .vertical)
                                .lineLimit(1...)
                        }
                    }
                }
            }
            if BuildInfo.showsDebugTools {
                Section {
                    Button("Fill API key (debug)") {
                        ai.applyDebugKey()
                        key = ai.apiKey
                    }
                }
            }
        }
        .themed()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            key = ai.apiKey
            Task { await ai.refreshModels() }
        }
    }
}

struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
