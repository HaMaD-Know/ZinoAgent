import Foundation

/// Formats multi-turn chat messages into model-family prompt formats when a GGUF model
/// lacks a built-in `llama_chat_apply_template`-compatible Jinja template.
public enum ChatTemplateFormatter {
    public struct PromptMessage: Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public static func fallbackFormat(messages: [PromptMessage], architecture: String) -> (prompt: String, stopSequences: [String]) {
        let arch = architecture.lowercased()
        if arch.contains("gemma") {
            return formatGemma(messages)
        } else if arch.contains("phi") {
            return formatPhi3(messages)
        } else if arch == "llama" || arch == "llama4" {
            return formatLlama3(messages)
        } else {
            // ChatML is standard across Qwen2, Qwen3, SmolLM, Mistral-ChatML, and many GGUF models.
            return formatChatML(messages)
        }
    }

    private static func formatChatML(_ messages: [PromptMessage]) -> (String, [String]) {
        var out = ""
        for msg in messages {
            out += "<|im_start|>\(msg.role)\n\(msg.content)<|im_end|>\n"
        }
        out += "<|im_start|>assistant\n"
        return (out, ["<|im_end|>", "<|endoftext|>"])
    }

    private static func formatLlama3(_ messages: [PromptMessage]) -> (String, [String]) {
        var out = ""
        for msg in messages {
            out += "<|start_header_id|>\(msg.role)<|end_header_id|>\n\n\(msg.content)<|eot_id|>"
        }
        out += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return (out, ["<|eot_id|>", "<|end_of_text|>"])
    }

    private static func formatGemma(_ messages: [PromptMessage]) -> (String, [String]) {
        var out = ""
        var systemPrefix = ""
        for msg in messages {
            if msg.role == "system" {
                systemPrefix += msg.content + "\n\n"
                continue
            }
            let role = msg.role == "assistant" ? "model" : "user"
            let content = (role == "user" && !systemPrefix.isEmpty) ? (systemPrefix + msg.content) : msg.content
            if role == "user" { systemPrefix = "" }
            out += "<start_of_turn>\(role)\n\(content)<end_of_turn>\n"
        }
        out += "<start_of_turn>model\n"
        return (out, ["<end_of_turn>"])
    }

    private static func formatPhi3(_ messages: [PromptMessage]) -> (String, [String]) {
        var out = ""
        for msg in messages {
            out += "<|\(msg.role)|>\n\(msg.content)<|end|>\n"
        }
        out += "<|assistant|>\n"
        return (out, ["<|end|>", "<|endoftext|>"])
    }
}
