import Foundation
import Observation
import SelfcareCore

struct PendingPermission: Identifiable {
    let id = UUID()
    let call: ToolCall
    let permission: ToolPermission
    let continuation: CheckedContinuation<Bool, Never>
}

@Observable
final class ChatSession {
    unowned let app: AppModel
    var conversation: Conversation
    var input = ""
    var attachments: [String] = []
    var running = false
    var error: String?
    var permission: PendingPermission?
    private var task: Task<Void, Never>?

    init(app: AppModel, conversation: Conversation = Conversation()) {
        self.app = app
        self.conversation = conversation
    }

    var visibleMessages: [ChatMessage] {
        conversation.messages.filter { $0.role != .system && !$0.hidden }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !text.isEmpty || !attachments.isEmpty else { return }
        var body = text
        var images: [ChatImage] = []
        for path in attachments {
            if VaultTools.isImage(path) {
                if let data = try? app.vault.readData(path), let image = ImageScaler.chatImage(data) {
                    images.append(image)
                    body += "\n\n[Attached image: \(path)]"
                }
            } else if let content = try? app.vault.read(path) {
                body += "\n\n<file path=\"\(path)\">\n\(content)\n</file>"
            } else {
                body += "\n\n[Attached file not found: \(path)]"
            }
        }
        var message = ChatMessage(role: .user, text: body, images: images, attachments: attachments)
        message.text = body
        if conversation.title.isEmpty {
            conversation.title = String((text.isEmpty ? attachments.joined(separator: ", ") : text).prefix(60))
        }
        conversation.messages.append(message)
        displayTexts[message.id] = text
        input = ""
        attachments = []
        start()
    }

    var displayTexts: [UUID: String] = [:]

    func displayText(_ message: ChatMessage) -> String {
        if let t = displayTexts[message.id] { return t }
        guard message.role == .user else { return message.text }
        var t = message.text
        if let r = t.range(of: "\n\n<file path=") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: "\n\n[Attached") { t = String(t[..<r.lowerBound]) }
        return t
    }

    func start() {
        guard let client = app.ai.client() else {
            error = "Set up AI in Settings"
            return
        }
        error = nil
        running = true
        var messages = conversation.messages.filter { $0.role != .system }
        messages.insert(ChatMessage(role: .system, text: app.ai.systemPrompt()), at: 0)
        let runner = AgentRunner(client: client, model: app.ai.resolvedModel, tools: VaultTools(vault: app.vault), specs: VaultTools.specs(imageGeneration: app.ai.imageGenerationAvailable), context: app.ai.toolContext(), askPermission: true, messages: messages)
        runner.permit = { [weak self] call, permission in
            guard let self else { return false }
            return await withCheckedContinuation { continuation in
                self.permission = PendingPermission(call: call, permission: permission, continuation: continuation)
            }
        }
        runner.onChange = { [weak self] messages in
            self?.conversation.messages = messages
        }
        task = Task {
            do {
                try await runner.run()
            } catch is CancellationError {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if let p = self.permission {
                self.permission = nil
                p.continuation.resume(returning: false)
            }
            self.conversation.messages = runner.messages
            self.cleanupEmptyAssistant()
            self.running = false
            self.conversation.updated = Date()
            self.app.ai.save(self.conversation)
            self.app.vaultChanged()
        }
    }

    private func cleanupEmptyAssistant() {
        while let last = conversation.messages.last, last.role == .assistant, last.text.isEmpty, last.toolCalls.isEmpty {
            conversation.messages.removeLast()
        }
    }

    func stop() {
        task?.cancel()
        if let p = permission {
            permission = nil
            p.continuation.resume(returning: false)
        }
    }

    func answer(_ allow: Bool) {
        guard let p = permission else { return }
        permission = nil
        p.continuation.resume(returning: allow)
    }

    func resend() {
        guard !running, let lastUser = conversation.messages.lastIndex(where: { $0.role == .user && !$0.hidden }) else { return }
        conversation.messages.removeSubrange((lastUser + 1)...)
        start()
    }

    var canResend: Bool {
        !running && (error != nil || conversation.messages.last?.role != .assistant || conversation.messages.last?.toolCalls.isEmpty == false) && conversation.messages.contains { $0.role == .user }
    }
}
