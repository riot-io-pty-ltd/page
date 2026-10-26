import SwiftUI
import UIKit

// Small views shared by the Inbox, Sessions, Reply, History and Settings screens.

struct KindChip: View {
    let kind: InterventionKind
    var subtype: String? = nil

    private var text: String { PageSubtype.chip(kind: kind, subtype: subtype) }

    var body: some View {
        Text(text)
            .font(Theme.Font.chip11)
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(kind.color, lineWidth: 1))
            .foregroundStyle(kind.color)
            .accessibilityLabel(kind.accessibilityName)
    }
}

struct BackendPill: View {
    private let badge: String
    private let name: String
    private let tint: Color
    private let surface: String
    private let spokenSurface: String

    init(backend: InterventionBackend, source: InterventionSource?) {
        badge = backend.badge
        name = backend.displayName
        tint = backend.tint
        surface = source?.label ?? InterventionSource.unknown.label
        spokenSurface = source?.label ?? "unknown surface"
    }

    /// A live session: any backend (unknown ones get a neutral tint), and
    /// the terminal or app hosting it.
    init(agent: AgentBackend, host: String) {
        badge = agent.badge
        name = agent.displayName
        tint = agent.tint
        surface = host
        spokenSurface = host
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(badge)
                .font(Theme.Font.chip11)
                .tracking(0.5)
            Text(surface)
                .font(Theme.Font.caption12)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(spokenSurface)")
    }
}

/// A live session's state: dot plus label, in the state's colour.
struct SessionStateChip: View {
    let state: LiveSessionState

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: state.color)
            Text(state.label.uppercased())
                .font(Theme.Font.chip11)
                .tracking(0.5)
                .lineLimit(1)
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(state.color.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("State: \(state.label)")
    }
}

/// Section title used across tabs ("YOUR MAC", "TOP PROJECTS" …).
struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Font.caption12)
            .tracking(0.5)
            .foregroundStyle(Theme.Colour.textMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Raised card: surface, hairline border, rounded corners.
    func cardStyle(padding: CGFloat = Theme.Space.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colour.surfaceRaised)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colour.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: - Mac presence

extension MacPresence {
    /// One-line status, e.g. "Online · heartbeat 12s ago".
    func summary(now: Date) -> String {
        switch self {
        case .unknown:
            return "Checking…"
        case .online(let seen):
            guard let seen else { return "Online" }
            return "Online · heartbeat \(RelativeTime.ago(since: seen, now: now))"
        case .stale(let seen):
            return "Not responding · last heartbeat \(RelativeTime.ago(since: seen, now: now))"
        case .offline(let seen):
            guard let seen else { return "Offline" }
            return "Offline · last seen \(RelativeTime.ago(since: seen, now: now))"
        case .neverConnected:
            return "Never connected with this pairing"
        }
    }

    var dotColor: Color {
        switch self {
        case .online: return Theme.Colour.success
        case .stale: return Theme.Colour.warning
        case .offline, .neverConnected: return Theme.Colour.destructiveText
        case .unknown: return Theme.Colour.textMuted
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

// MARK: - Banners

/// A problem the user should know about, with a way to fix it when there is
/// one. Shown at the top of the Inbox so "All quiet" is never a false promise.
struct StatusBanner: View {
    enum Tone { case warning, error, info }

    let tone: Tone
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    private var tint: Color {
        switch tone {
        case .warning: return Theme.Colour.warning
        case .error: return Theme.Colour.destructiveText
        case .info: return Theme.Colour.textMuted
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.system(.body, design: .default, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(Theme.Colour.text)
                Text(message)
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(Theme.Font.bodyEm)
                        .foregroundStyle(Theme.Colour.text)
                        .padding(.top, 2)
                        .frame(minHeight: 32)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Reply controls

// Shared by the reply screen and a live session's composer.

enum QuickButtonStyle { case accent, destructive, outline }

/// Full-width action button (Approve, Deny, Carry on, Close).
struct QuickButton: View {
    let label: String
    let style: QuickButtonStyle
    let enabled: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var buttonHeight: CGFloat = 44

    init(_ label: String, style: QuickButtonStyle, enabled: Bool, action: @escaping () -> Void) {
        self.label = label
        self.style = style
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.button17)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(minHeight: buttonHeight)
                .background {
                    let shape = RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    switch style {
                    case .accent: shape.fill(Theme.Colour.pulseGradient(scheme))
                    case .destructive: shape.fill(Theme.Colour.destructive)
                    case .outline: shape.strokeBorder(Theme.Colour.hairline, lineWidth: 1)
                    }
                }
                .foregroundStyle(style == .outline ? Theme.Colour.text : Theme.Colour.onAccent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// Growing text field with a round send button. `onSend` gets the trimmed
/// text; the button is enabled only when there is some.
struct ReplyField: View {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    var sendLabel: String = "Send reply"
    let onSend: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 36

    var body: some View {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(Theme.Font.body15)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
                .disabled(!enabled)
            Button { onSend(text.trimmingCharacters(in: .whitespacesAndNewlines)) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(.body, design: .default, weight: .bold))
                    .foregroundStyle(Theme.Colour.onAccent)
                    .frame(width: sendSize, height: sendSize)
                    .background(
                        hasText && enabled
                            ? AnyShapeStyle(Theme.Colour.pulseGradient(scheme))
                            : AnyShapeStyle(Theme.Colour.textMuted.opacity(0.5))
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
            .disabled(!enabled || !hasText)
            .accessibilityLabel(sendLabel)
        }
        .background(Theme.Colour.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.input).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.input))
    }
}

/// One-line delivery or resolution state above the reply controls. No icon
/// means "in progress" and shows a spinner.
struct StatusStrip: View {
    let icon: String?
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            if let icon {
                Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .stripStyle()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The status strip's raised box, inset like the reply controls.
    func stripStyle() -> some View {
        self
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colour.surfaceRaised)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.s)
    }
}
