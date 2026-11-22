import SwiftUI
import UIKit

/// Renders Markdown prose alongside syntax-styled fenced code blocks with one-tap Copy buttons.
public struct MarkdownMessageView: View {
    public let content: String

    public init(content: String) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks(content).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .prose(text):
                    if let attributed = try? AttributedString(
                        markdown: text,
                        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attributed)
                            .textSelection(.enabled)
                    } else {
                        Text(text)
                            .textSelection(.enabled)
                    }
                case let .code(language, code):
                    CodeBlockCard(language: language, code: code)
                }
            }
        }
    }

    private enum MarkdownBlock {
        case prose(String)
        case code(language: String, code: String)
    }

    private func parseBlocks(_ raw: String) -> [MarkdownBlock] {
        let lines = raw.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var proseBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false
        var currentLang = ""

        func flushProse() {
            let joined = proseBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.prose(joined))
            }
            proseBuffer.removeAll()
        }

        for line in lines {
            if line.hasPrefix("```") {
                if !inCode {
                    flushProse()
                    inCode = true
                    currentLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeBuffer.removeAll()
                } else {
                    blocks.append(.code(language: currentLang.isEmpty ? "code" : currentLang, code: codeBuffer.joined(separator: "\n")))
                    inCode = false
                    currentLang = ""
                    codeBuffer.removeAll()
                }
            } else if inCode {
                codeBuffer.append(line)
            } else {
                proseBuffer.append(line)
            }
        }

        if inCode && !codeBuffer.isEmpty {
            blocks.append(.code(language: currentLang.isEmpty ? "code" : currentLang, code: codeBuffer.joined(separator: "\n")))
        } else {
            flushProse()
        }

        return blocks.isEmpty ? [.prose(raw)] : blocks
    }
}

private struct CodeBlockCard: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ZinoTheme.surfaceTertiary)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(ZinoTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ZinoTheme.border, lineWidth: 0.75))
    }
}
