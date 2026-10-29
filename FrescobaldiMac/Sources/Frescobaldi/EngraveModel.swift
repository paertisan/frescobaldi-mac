import AppKit
import Combine
import FrescobaldiCore
import SwiftUI

/// State of the document's engraving, shown by the toolbar status, the
/// issues/log panel and the editor ruler.
final class EngraveModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case running(EngraveJob.Mode)
        case finished(succeeded: Bool, errors: Int, warnings: Int, duration: TimeInterval)
        case cancelled
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var log = ""
    @Published var messages: [LilyPondMessage] = []
    @Published var pdfs: [URL] = []
    @Published var midis: [URL] = []
    @Published var selectedTab: PanelTab = .issues

    /// Set by the window: jump to an issue.
    var onSelectMessage: ((LilyPondMessage) -> Void)?

    enum PanelTab: String, CaseIterable, Identifiable {
        case issues = "Issues"
        case log = "Log"
        var id: String { rawValue }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var errorCount: Int { messages.filter { $0.severity.isError }.count }
    var warningCount: Int { messages.count - errorCount }
}

// MARK: - Toolbar status

/// The centered toolbar item: what the engraver is doing.
struct EngraveStatusView: View {
    @ObservedObject var model: EngraveModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.status {
            case .idle:
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                Text("Ready to engrave")
                    .foregroundStyle(.secondary)
            case let .running(mode):
                ProgressView()
                    .controlSize(.small)
                Text(mode == .publish ? "Engraving for publishing…" : "Engraving…")
            case let .finished(succeeded, errors, warnings, duration):
                Image(systemName: succeeded && errors == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(succeeded && errors == 0 ? Color.green : Color.red)
                Text(succeeded && errors == 0 ? "Engraved in \(duration.formatted(.number.precision(.fractionLength(1)))) s"
                                              : "Engraving failed")
                if errors > 0 { IssueBadge(count: errors, error: true) }
                if warnings > 0 { IssueBadge(count: warnings, error: false) }
            case .cancelled:
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
                Text("Stopped")
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(minWidth: 220, maxWidth: 380)
        .contentShape(Rectangle())
        .onTapGesture {
            if !model.messages.isEmpty { model.selectedTab = .issues }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct IssueBadge: View {
    let count: Int
    let error: Bool

    var body: some View {
        Label("\(count)", systemImage: error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(error ? Color.red : Color.yellow)
            .font(.caption.weight(.semibold))
            .accessibilityLabel(error ? "\(count) errors" : "\(count) warnings")
    }
}

// MARK: - Issues and log panel

struct EngravePanelView: View {
    @ObservedObject var model: EngraveModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $model.selectedTab) {
                    ForEach(EngraveModel.PanelTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if model.selectedTab == .log {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.log, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Log")
                    .disabled(model.log.isEmpty)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            switch model.selectedTab {
            case .issues: issues
            case .log: logView
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var issues: some View {
        if model.messages.isEmpty {
            ContentUnavailableView {
                Label(model.isRunning ? "Engraving…" : "No Issues", systemImage: "checkmark.circle")
            } description: {
                Text(model.isRunning ? "Errors and warnings will appear here." : "LilyPond reported no errors or warnings.")
            }
        } else {
            List(model.messages) { message in
                Button {
                    model.onSelectMessage?(message)
                } label: {
                    IssueRow(message: message)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.log.isEmpty ? " " : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: model.log) {
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }
}

private struct IssueRow: View {
    let message: LilyPondMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: message.severity.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(message.severity.isError ? Color.red : Color.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.message)
                    .lineLimit(2)
                Text("\(URL(fileURLWithPath: message.file).lastPathComponent):\(message.line):\(message.column)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let source = message.context.first, !source.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(message.context.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
