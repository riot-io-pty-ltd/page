import SwiftUI

struct ReplyView: View {
    let intervention: Intervention
    let onDismiss: () -> Void

    @EnvironmentObject var api: APIClient
    @Environment(\.colorScheme) private var scheme
    @State private var replyText: String = ""
    @State private var sending: Bool = false

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        kindChip
                        Text(headline)
                            .font(Theme.Font.display22)
                            .foregroundStyle(Theme.Colour.text)
                        contextBlock
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.l)
                }
                actionRow
                replyField
            }
        }
        .ignoresSafeArea(.keyboard, edges: .top)
    }

    // MARK: header

    private var topBar: some View {
        HStack(spacing: Theme.Space.m) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Colour.text)
                    .frame(width: 36, height: 36)
            }
            VStack(spacing: 2) {
                Text(intervention.projectName)
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
                Text("Session \(intervention.sessionId.prefix(8))")
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(Theme.Colour.text)
            }
            .frame(maxWidth: .infinity)
            Spacer().frame(width: 36)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
        .overlay(Rectangle().fill(Theme.Colour.hairline).frame(height: 0.5), alignment: .bottom)
    }

    private var kindChip: some View {
        Text(intervention.kind.label + " REQUEST")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(Theme.Colour.pulseGradient(scheme), lineWidth: 1))
            .foregroundStyle(Theme.Colour.textMuted)
    }

    private var headline: String {
        switch intervention.kind {
        case .approval:
            if intervention.subtype == "plan" { return "Approve the plan?" }
            return "Run this command?"
        case .userInput:
            return intervention.context.split(separator: ".").first.map(String.init) ?? "Your input?"
        case .idle:
            return "Session is waiting"
        case .rateLimit:
            return "Rate-limited"
        }
    }

    private var contextBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(intervention.context)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colour.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Working directory: \(intervention.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
        }
    }

    // MARK: actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            quickButton("Approve", filled: true, color: Theme.Colour.pulseGradient(scheme)) { reply(action: "approve") }
            quickButton("Deny", filled: true, color: AnyShapeStyle(Theme.Colour.destructive)) { reply(action: "deny") }
            quickButton("Carry on", filled: false, color: AnyShapeStyle(Theme.Colour.text)) { reply(action: "carry_on") }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
    }

    private func quickButton<S: ShapeStyle>(_ label: String, filled: Bool, color: S, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Group {
                        if filled {
                            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(color)
                        } else {
                            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                .strokeBorder(Theme.Colour.hairline, lineWidth: 1)
                        }
                    }
                )
                .foregroundStyle(filled ? AnyShapeStyle(Color.black) : AnyShapeStyle(Theme.Colour.text))
        }
        .buttonStyle(.plain)
        .disabled(sending)
    }

    private var replyField: some View {
        VStack(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                TextField("Or type a reply…", text: $replyText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body15)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                Button(action: { reply(action: replyText.isEmpty ? nil : "custom") }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 36, height: 36)
                        .background(
                            replyText.isEmpty
                                ? AnyShapeStyle(Theme.Colour.textMuted)
                                : AnyShapeStyle(Theme.Colour.pulseGradient(scheme))
                        )
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .disabled(sending || replyText.isEmpty)
            }
            .background(Theme.Colour.surfaceRaised)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.input).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.input))
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)

            Text("Reply goes to session \(intervention.sessionId.prefix(8)) · injected via tmux")
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
                .padding(.bottom, Theme.Space.l)
        }
    }

    private func reply(action: String?) {
        sending = true
        Task {
            await api.reply(interventionId: intervention.id, text: replyText, action: action)
            sending = false
            onDismiss()
        }
    }
}
