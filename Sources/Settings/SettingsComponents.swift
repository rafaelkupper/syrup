import AppKit
import SwiftUI

/// Small capsule showing a state with a leading dot, e.g. "● Allowed". Used only for state.
struct StatusPill: View {
    enum Tone {
        case ok
        case warn
        case bad
        case neutral

        var color: Color {
            switch self {
            case .ok:
                .green
            case .warn:
                .orange
            case .bad:
                .red
            case .neutral:
                .secondary
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .foregroundStyle(tone.color)
        .background(tone.color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

extension StatusPill {
    init(_ status: PermissionStatusModel.Status) {
        switch status {
        case .granted:
            self.init(text: "Allowed", tone: .ok)
        case .denied:
            self.init(text: "Denied", tone: .bad)
        case .restricted:
            self.init(text: "Restricted", tone: .bad)
        case .notRequested:
            self.init(text: "Not allowed", tone: .warn)
        case .unknown:
            self.init(text: "Unknown", tone: .neutral)
        }
    }
}

/// Small label that annotates a choice, e.g. "Private · Offline".
struct TagBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A keyboard shortcut shown as text.
struct ShortcutChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Workflow look

/// Color and symbol for a workflow, from what it does. Nothing is stored.
enum WorkflowStyle {
    case translate
    case custom
    case transcribe
    case revise

    init(_ kind: WorkflowKind) {
        switch kind {
        case .translation:
            self = .translate
        case .custom:
            self = .custom
        case .transcribeOnly:
            self = .transcribe
        }
    }

    init(_ record: DictationRecord) {
        switch record.transformation {
        case .translation:
            self = .translate
        case .revision:
            self = .revise
        case .contextual(_, let instruction) where instruction.isEmpty:
            self = .transcribe
        case .custom, .contextual:
            self = .custom
        }
    }

    var color: Color {
        switch self {
        case .translate:
            .blue
        case .custom:
            .purple
        case .transcribe:
            .gray
        case .revise:
            .teal
        }
    }

    var systemImage: String {
        switch self {
        case .translate:
            "globe"
        case .custom:
            "sparkles"
        case .transcribe:
            "waveform"
        case .revise:
            "arrow.uturn.backward"
        }
    }
}

/// The colored square that identifies a workflow everywhere it appears.
struct WorkflowTile: View {
    let style: WorkflowStyle
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: style.systemImage)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(style.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

// MARK: - Sentence

/// Lays out words and controls left to right and wraps them like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                x += item.leading
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, leading: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let attached = subviews[index][AttachesToPrevious.self]
            let gap = rows[rows.count - 1].items.isEmpty || attached ? 0 : spacing
            if rows[rows.count - 1].items.isEmpty == false,
               attached == false,
               rows[rows.count - 1].width + gap + size.width > width {
                rows.append(Row())
            }
            let leading = rows[rows.count - 1].items.isEmpty ? 0 : gap
            rows[rows.count - 1].items.append((index, leading))
            rows[rows.count - 1].width += leading + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// Punctuation that must stay on the same line as the word before it.
struct AttachesToPrevious: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    func attachesToPrevious() -> some View {
        layoutValue(key: AttachesToPrevious.self, value: true)
    }
}

/// One choice in a menu built from a list.
struct MenuChoice<Value: Hashable>: Hashable {
    let value: Value
    let title: String
    /// Draws a separator above this choice.
    var startsGroup = false
}

/// Menu items that pick one value. The current one carries a check mark for VoiceOver;
/// the menu word itself shows the choice, since macOS 27 does not draw icons in these menus.
/// In a button-style `Menu` on macOS 27, an inline `Picker` or a `Toggle` makes the menu show
/// nothing when clicked, so each choice is a plain button.
struct MenuChoiceItems<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [MenuChoice<Value>]

    var body: some View {
        ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
            if choice.startsGroup {
                Divider()
            }
            Button {
                selection = choice.value
            } label: {
                if choice.value == selection {
                    Label(choice.title, systemImage: "checkmark")
                } else {
                    Text(choice.title)
                }
            }
        }
    }
}

/// One word of a workflow sentence that opens a menu of choices.
struct SentenceMenu<Value: Hashable>: View {
    let title: String
    let label: String
    @Binding var selection: Value
    var tint: Color = .accentColor
    let choices: [MenuChoice<Value>]

    var body: some View {
        Menu {
            MenuChoiceItems(selection: $selection, choices: choices)
        } label: {
            HStack(spacing: 2) {
                Text(label)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .opacity(0.7)
            }
            .foregroundStyle(tint)
            .fontWeight(.medium)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(label)
    }
}

// MARK: - Apps

/// Names and icons of installed apps, looked up once per bundle ID.
@MainActor
enum AppInfoCache {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String {
        if let name = names[bundleID] { return name }
        let name: String
        if let url = url(for: bundleID) {
            let bundle = Bundle(url: url)
            name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
        } else {
            name = bundleID
        }
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard let url = url(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        icons[bundleID] = icon
        return icon
    }
}

struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let icon = AppInfoCache.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Confirmation

/// Asks before something that can't be undone. Returns true when the user confirms.
@MainActor
func confirmDestructiveAction(message: String, detail: String, confirmTitle: String) -> Bool {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.alertStyle = .warning
    let confirm = alert.addButton(withTitle: confirmTitle)
    confirm.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
