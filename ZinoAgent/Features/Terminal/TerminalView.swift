import SwiftUI

public struct TerminalView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var terminal: ZinoTerminalService

    @State private var commandInput: String = ""
    @State private var historyIndex: Int?
    @State private var isExecuting: Bool = false
    @State private var mountedFolders: [MountedFolder] = []

    private let quickCommands = [
        "help", "ls -la", "pwd", "tree", "serve 8080", "server status", "inspect", "skills", "gh repos", "cf zones", "sysinfo", "clear"
    ]

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.terminal = coordinator.terminalService
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topStatusAndQuickBar
                Divider()
                transcriptArea
                Divider()
                commandComposer
            }
            .background(Color(red: 0.07, green: 0.08, blue: 0.10))
            .navigationTitle("Workspace Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !mountedFolders.isEmpty {
                        Menu {
                            ForEach(mountedFolders) { folder in
                                Button(folder.displayName) {
                                    terminal.switchMountedFolder(folder)
                                }
                            }
                        } label: {
                            Label(terminal.activeFolder?.displayName ?? "Folder", systemImage: "folder")
                        }
                    }
                    Button {
                        terminal.clearTranscript()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
            }
            .onAppear {
                terminal.syncActiveFolder()
                mountedFolders = (try? coordinator.bookmarkManager.loadFolders()) ?? []
            }
        }
    }

    private var topStatusAndQuickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickCommands, id: \.self) { cmd in
                    Button {
                        runCommand(cmd)
                    } label: {
                        Text(cmd)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08))
                            .foregroundStyle(Color(red: 0.72, green: 0.86, blue: 1.0))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color(red: 0.10, green: 0.11, blue: 0.14))
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(terminal.transcript) { line in
                        Text(line.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: terminal.transcript.count) { _, _ in
                if let last = terminal.transcript.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var commandComposer: some View {
        HStack(spacing: 10) {
            Text(terminal.promptDisplay)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color(red: 0.35, green: 0.90, blue: 0.55))
                .lineLimit(1)

            TextField("Enter command (ls, cat, write, serve, open snake.html, js 1+1, gh, cf)...", text: $commandInput)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    runCommand(commandInput)
                }

            Button {
                navigateHistory(up: true)
            } label: {
                Image(systemName: "arrow.up")
                    .foregroundStyle(.secondary)
            }
            .disabled(terminal.commandHistory.isEmpty)

            Button {
                runCommand(commandInput)
            } label: {
                if isExecuting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "return")
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isExecuting || commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14))
    }

    private func runCommand(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commandInput = ""
        historyIndex = nil
        isExecuting = true
        Task {
            _ = await terminal.execute(trimmed)
            isExecuting = false
        }
    }

    private func navigateHistory(up: Bool) {
        let hist = terminal.commandHistory
        guard !hist.isEmpty else { return }
        if let idx = historyIndex {
            let next = up ? max(0, idx - 1) : min(hist.count - 1, idx + 1)
            historyIndex = next
            commandInput = hist[next]
        } else {
            historyIndex = hist.count - 1
            commandInput = hist.last ?? ""
        }
    }

    private func color(for kind: TerminalTranscriptLine.Kind) -> Color {
        switch kind {
        case .command: return Color(red: 0.45, green: 0.92, blue: 0.62)
        case .output: return Color(white: 0.92)
        case .error: return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .system: return Color(red: 0.58, green: 0.78, blue: 1.0)
        }
    }
}
