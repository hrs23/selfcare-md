import Foundation
import SelfcareCore
import UIKit

nonisolated final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var originals: [String: Data?] = [:]
    let vault: Vault

    init(vault: Vault) {
        self.vault = vault
    }

    func record(_ path: String) {
        lock.withLock {
            if originals.keys.contains(path) { return }
            originals[path] = vault.exists(path) ? (try? vault.readData(path)) : nil
        }
    }

    func created(_ path: String) -> Bool {
        lock.withLock {
            guard let original = originals[path] else { return false }
            return original == nil
        }
    }

    var snapshot: [String: Data?] {
        lock.withLock { originals }
    }
}

enum ImageScaler {
    static func chatImage(_ data: Data, maxSide: CGFloat = 1024) -> ChatImage? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return ChatImage(mime: "image/jpeg", base64: jpeg.base64EncodedString())
    }
}

enum AgentError: LocalizedError {
    case contextFull

    var errorDescription: String? {
        switch self {
        case .contextFull: "This conversation is too long. Start a new conversation."
        }
    }
}

@MainActor
final class AgentRunner {
    let client: ChatClient
    let model: String
    let tools: VaultTools
    let specs: [ToolSpec]
    let context: ToolContext
    let askPermission: Bool
    var permit: (ToolCall, ToolPermission) async -> Bool = { _, _ in true }
    var onChange: ([ChatMessage]) -> Void = { _ in }
    var messages: [ChatMessage]
    var contextLimit = 110_000

    init(client: ChatClient, model: String, tools: VaultTools, specs: [ToolSpec], context: ToolContext, askPermission: Bool, messages: [ChatMessage]) {
        self.client = client
        self.model = model
        self.tools = tools
        self.specs = specs
        self.context = context
        self.askPermission = askPermission
        self.messages = messages
    }

    func estimated() -> Int {
        messages.reduce(0) { $0 + $1.estimatedTokens } + specs.count * 120
    }

    func trimContext() throws {
        var total = estimated()
        guard total > contextLimit * 3 / 4 else { return }
        let lastUser = messages.lastIndex { $0.role == .user && !$0.hidden } ?? messages.count
        for i in messages.indices where i < lastUser {
            let before = messages[i].estimatedTokens
            if messages[i].role == .tool && !messages[i].omitted {
                messages[i].omitted = true
            }
            if messages[i].hidden && !messages[i].images.isEmpty {
                messages[i].images = []
                messages[i].text = "[Omitted images]"
            }
            total += messages[i].estimatedTokens - before
            if total <= contextLimit * 6 / 10 { break }
        }
        onChange(messages)
        if estimated() > contextLimit { throw AgentError.contextFull }
    }

    func run() async throws {
        var imageRetry = false
        while true {
            try Task.checkCancellation()
            try trimContext()
            let requestMessages = messages
            messages.append(ChatMessage(role: .assistant, text: ""))
            let index = messages.count - 1
            onChange(messages)
            do {
                for try await event in client.stream(model: model, messages: requestMessages, tools: specs) {
                    switch event {
                    case let .text(t):
                        messages[index].text += t
                        onChange(messages)
                    case let .toolCalls(calls):
                        messages[index].toolCalls = calls
                        onChange(messages)
                    case .finished:
                        break
                    }
                }
            } catch AIError.imagesUnsupported where !imageRetry {
                imageRetry = true
                messages.remove(at: index)
                stripImages()
                continue
            }
            let calls = messages[index].toolCalls
            if calls.isEmpty { break }
            var images: [ChatImage] = []
            var imagePaths: [String] = []
            for call in calls {
                try Task.checkCancellation()
                var result: String
                if askPermission && VaultTools.writeTools.contains(call.name) {
                    let allowed = await permit(call, tools.permission(call))
                    if !allowed {
                        messages.append(ChatMessage(role: .tool, text: "The user declined this action.", toolCallId: call.id, toolName: call.name))
                        onChange(messages)
                        continue
                    }
                }
                do {
                    switch try await tools.execute(call, context: context) {
                    case let .text(t):
                        result = t
                    case let .image(path, data):
                        if let image = ImageScaler.chatImage(data) {
                            images.append(image)
                            imagePaths.append(path)
                            result = "The image \(path) is attached in the next message."
                        } else {
                            result = "Error: cannot decode image \(path)"
                        }
                    }
                } catch {
                    result = "Error: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
                messages.append(ChatMessage(role: .tool, text: result, toolCallId: call.id, toolName: call.name))
                onChange(messages)
            }
            if !images.isEmpty {
                messages.append(ChatMessage(role: .user, text: "Images: " + imagePaths.joined(separator: ", "), images: images, hidden: true))
                onChange(messages)
            }
        }
        onChange(messages)
    }

    private func stripImages() {
        for i in messages.indices where messages[i].hidden && !messages[i].images.isEmpty {
            messages[i].images = []
            messages[i].text = "Error: this model cannot read images."
        }
        for i in messages.indices where messages[i].role == .tool && messages[i].text.contains("is attached in the next message") {
            messages[i].text = "Error: this model cannot read images."
        }
        for i in messages.indices where messages[i].role == .user && !messages[i].hidden && !messages[i].images.isEmpty {
            messages[i].images = []
            messages[i].text += "\n\n[Images removed: this model cannot read images.]"
        }
        onChange(messages)
    }
}
