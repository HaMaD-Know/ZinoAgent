import SwiftUI

public struct SmartContextDashboardView: View {
    @ObservedObject var contextEngine: SmartContextEngine
    @ObservedObject var settings: SettingsManager
    public let conversationID: String?
    public let onCompactNow: () -> Void
    public let onClearSummaries: () -> Void

    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        let snap = contextEngine.latestSnapshot
        NavigationStack {
            List {
                Section("Context Usage") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(Formatters.tokens(snap.currentTokenCount)) / \(Formatters.tokens(snap.effectiveCapacity)) tokens")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(snap.utilizationRatio * 100))%")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(snap.utilizationRatio > 0.85 ? ZinoTheme.statusWarning : ZinoTheme.statusPositive)
                        }
                        ProgressView(value: snap.utilizationRatio)
                            .tint(snap.utilizationRatio > 0.85 ? ZinoTheme.statusWarning : Color.accentColor)
                        Text("Tokenizer: \(snap.tokenizerSource.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    LabeledContent("Available Context", value: "\(Formatters.tokens(snap.availableContextTokens)) tokens")
                    LabeledContent("Model Context Window", value: "\(Formatters.tokens(snap.modelContextWindow)) tokens")
                    LabeledContent("Messages (Included / Total)", value: "\(snap.includedMessageCount) / \(snap.totalMessageCount)")
                    LabeledContent("Retrieved History", value: "\(snap.retrievedHistoryCount) messages")
                    LabeledContent("Pinned Messages", value: "\(snap.pinnedMessageCount)")
                    LabeledContent("Summary Size", value: "\(Formatters.tokens(snap.summaryTokenCount)) tokens (\(snap.summaryCount) summaries)")
                    LabeledContent("Current Adaptive Batch Size", value: "\(snap.adaptiveBatchSize) messages")
                }

                Section("Engine Controls") {
                    Toggle("Adaptive Batching", isOn: $settings.adaptiveBatchingEnabled)
                    Toggle("Smart History Retrieval", isOn: $settings.smartHistoryRetrievalEnabled)
                    Toggle("Preserve Original Messages", isOn: $settings.preserveOriginalMessages)
                    Toggle("Summary Verification", isOn: $settings.summaryVerificationEnabled)

                    Stepper("Context Target: \(Formatters.tokens(settings.baselineContextTarget))", value: $settings.baselineContextTarget, in: 2048...32768, step: 1024)
                    Stepper("Initial Batch Target: \(settings.initialMessageBatchTarget) msgs", value: $settings.initialMessageBatchTarget, in: 2...12)
                    Stepper("Max Retrieved History: \(settings.maxRetrievedMessages) msgs", value: $settings.maxRetrievedMessages, in: 0...20)
                }
                .onChange(of: settings.adaptiveBatchingEnabled) { _, _ in contextEngine.syncConfiguration(from: settings) }
                .onChange(of: settings.smartHistoryRetrievalEnabled) { _, _ in contextEngine.syncConfiguration(from: settings) }
                .onChange(of: settings.preserveOriginalMessages) { _, _ in contextEngine.syncConfiguration(from: settings) }
                .onChange(of: settings.summaryVerificationEnabled) { _, _ in contextEngine.syncConfiguration(from: settings) }
                .onChange(of: settings.baselineContextTarget) { _, _ in contextEngine.syncConfiguration(from: settings) }
                .onChange(of: settings.initialMessageBatchTarget) { _, _ in contextEngine.syncConfiguration(from: settings) }
                .onChange(of: settings.maxRetrievedMessages) { _, _ in contextEngine.syncConfiguration(from: settings) }

                if conversationID != nil {
                    Section("Manual Actions") {
                        Button {
                            onCompactNow()
                        } label: {
                            Label("Compact Older Messages Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        if !contextEngine.activeSummaries.isEmpty {
                            Button(role: .destructive) {
                                onClearSummaries()
                            } label: {
                                Label("Clear Summaries (Keeps Original Messages)", systemImage: "trash")
                            }
                        }
                    }
                }

                if !contextEngine.activeSummaries.isEmpty {
                    Section("Verified Context Summaries") {
                        ForEach(contextEngine.activeSummaries) { summary in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    StatusBadge(
                                        summary.verificationPassed ? "Verified" : "Partial",
                                        icon: summary.verificationPassed ? "checkmark.seal.fill" : "exclamationmark.triangle",
                                        tint: summary.verificationPassed ? ZinoTheme.statusPositive : ZinoTheme.statusWarning
                                    )
                                    Text("\(summary.coveredMessageCount) msgs • \(summary.tokenCount) tok")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Text(summary.verificationNotes)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(summary.summaryText)
                                    .font(.caption)
                                    .lineLimit(6)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("SmartContextEngine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
