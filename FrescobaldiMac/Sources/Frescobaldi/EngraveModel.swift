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
    /// What's engraved when it isn't the document itself: the project's
    /// main file, a chosen target, a build command.
    @Published var targetName: String?
    /// Engraving several targets: how many are done.
    @Published var progress: (done: Int, total: Int)?
    /// Running a build command instead of LilyPond.
    @Published var commandName: String?
    /// A short message shown in place of the status for a few seconds
    /// (adjusting objects in the preview).
    @Published private(set) var notice: String?
    private var noticeTimer: Timer?

    func show(notice text: String, seconds: TimeInterval = 4) {
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.notice = nil }
        }
    }

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

/// The centered toolbar item: what the engraver is doing, as quiet text.
/// Success is the normal case, so only problems get color.
struct EngraveStatusView: View {
    @ObservedObject var model: EngraveModel

    var body: some View {
        HStack(spacing: 8) {
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            } else {
                status
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 220, maxWidth: 380)
        .contentShape(Rectangle())
        .onTapGesture {
            if !model.messages.isEmpty { model.selectedTab = .issues }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch model.status {
        case .idle:
            Text("⌘R to engrave")
                .foregroundStyle(.tertiary)
        case let .running(mode):
            ProgressView()
                .controlSize(.mini)
            Group {
                if let command = model.commandName {
                    Text("Running \(command)…")
                } else if let progress = model.progress {
                    Text("Engraving \(progress.total) targets (\(progress.done) done)…")
                } else {
                    Text(model.targetName.map { "Engraving \($0)…" }
                         ?? (mode == .publish ? "Engraving for publishing…" : "Engraving…"))
                }
            }
            .foregroundStyle(.secondary)
        case let .finished(succeeded, errors, warnings, duration):
            let time = "\(duration.formatted(.number.precision(.fractionLength(1)))) s"
            let what = model.progress.map { " \($0.total) targets" } ?? model.targetName.map { " \($0)" } ?? ""
            Group {
                if let command = model.commandName {
                    Text(succeeded && errors == 0 ? "Ran \(command) in \(time)" : "\(command) failed")
                } else {
                    Text(succeeded && errors == 0 ? "Engraved\(what) in \(time)" : "Engraving\(what) failed")
                }
            }
            .foregroundStyle(succeeded && errors == 0 ? .secondary : .primary)
            if errors > 0 { IssueCount(count: errors, error: true) }
            if warnings > 0 { IssueCount(count: warnings, error: false) }
        case .cancelled:
            Text("Stopped")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// "2 errors" in plain text after a small symbol.
private struct IssueCount: View {
    let count: Int
    let error: Bool

    var body: some View {
        HStack(spacing: 4) {
            SeverityMark(isError: error)
                .accessibilityHidden(true)
            Text(error ? (count == 1 ? "1 error" : "\(count) errors") : (count == 1 ? "1 warning" : "\(count) warnings"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Issues and log panel

struct EngravePanelView: View {
    @ObservedObject var model: EngraveModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextTabs(selection: $model.selectedTab, tabs: [
                    .init(value: .issues, title: "Issues", detail: model.messages.isEmpty ? nil : "\(model.messages.count)"),
                    .init(value: .log, title: "Log"),
                ])
                Spacer()
                if model.selectedTab == .log {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.log, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy Log")
                    .disabled(model.log.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            switch model.selectedTab {
            case .issues: issues
            case .log: logView
            }
        }
        .themedBackground(fallback: Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var issues: some View {
        if model.messages.isEmpty {
            Text(model.isRunning ? "Engraving…" : "No errors or warnings")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.messages) { message in
                Button {
                    model.onSelectMessage?(message)
                } label: {
                    IssueRow(message: message)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.log.isEmpty ? " " : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SeverityMark(isError: message.severity.isError)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.message)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(message.isLocated
                         ? "\(URL(fileURLWithPath: message.file).lastPathComponent):\(message.line)"
                           + (message.column > 0 ? ":\(message.column)" : "")
                         : "Show in Log")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if message.context.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text(message.context.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.severity.isError ? "Error" : "Warning"): \(message.message)")
    }
}
