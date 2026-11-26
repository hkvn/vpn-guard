import SwiftUI

// Building blocks for the Settings window (design canvas: "Redesign · Settings (light mode)").

/// White rounded card with a hairline border.
struct SettingsCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

/// Section title above a card, with optional text on the right.
struct SectionHeading: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

/// Hairline between rows, starting at `leading`.
struct RowDivider: View {
    var leading: CGFloat = 14

    var body: some View {
        Rectangle().fill(Palette.separator).frame(height: 1).padding(.leading, leading)
    }
}

/// A 44 pt row: label on the left, control on the right.
struct ToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Tone.green.fill)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .padding(.vertical, detail == nil ? 0 : 6)
    }
}

/// A row with a label and a value on the right.
struct ValueRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            value()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

/// The macOS +/− bar under a list.
struct ListBar: View {
    var add: (() -> Void)?
    var remove: (() -> Void)?
    var addHelp = "Add"
    var removeHelp = "Remove"
    var caption: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.separator).frame(height: 1)
            HStack(spacing: 0) {
                barButton("plus", action: add, help: addHelp)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
                barButton("minus", action: remove, help: removeHelp)
                Spacer()
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 6)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Palette.listBar)
        }
    }

    private func barButton(_ symbol: String, action: (() -> Void)?, help: String) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(action == nil ? Color.secondary.opacity(0.5) : Color.primary)
        .disabled(action == nil)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The ⓘ button at the end of a row.
struct InfoButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// "● Connected" style status text.
struct DotStatus: View {
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone.fill).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(tone.text)
        }
    }
}

/// Plain white bordered button, like the design's secondary buttons.
struct CardButtonStyle: ButtonStyle {
    var destructive = false
    /// Blue filled, for the main action in a card.
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : (destructive ? Tone.red.text : Color.primary))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(prominent ? Tone.blue.fill : Palette.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(prominent ? Color.clear : Color.primary.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
