import SwiftUI

/// Tabs drawn as plain words, the chosen one in the primary color: a quieter
/// switch than a segmented control for the sidebar and the issues panel.
struct TextTabs<Value: Hashable>: View {
    struct Tab {
        var value: Value
        var title: String
        /// A count after the title, such as the number of issues.
        var detail: String? = nil
    }

    @Binding var selection: Value
    let tabs: [Tab]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(tabs.indices, id: \.self) { index in
                let tab = tabs[index]
                let selected = tab.value == selection
                Button {
                    selection = tab.value
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.title)
                        if let detail = tab.detail {
                            Text(detail)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .font(.callout.weight(.medium))
    }
}

/// Shows its content only while the pointer is over `hovering`'s view, or
/// when `always` is true; it stays in place (and for VoiceOver) either way.
struct RevealOnHover: ViewModifier {
    var hovering: Bool
    var always = false

    func body(content: Content) -> some View {
        content
            .opacity(hovering || always ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A small error or warning symbol: the shapes differ as well as the
/// colors, so the difference doesn't rest on color alone.
struct SeverityMark: View {
    var isError: Bool

    var body: some View {
        Image(systemName: isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(isError ? Color.red : Color.orange)
            .accessibilityLabel(isError ? "Error" : "Warning")
    }
}

/// An empty pane: a small symbol, a serif title and one line of help.
struct QuietEmptyState: View {
    var title: String
    var symbol: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.title3)
                .fontDesign(.serif)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
