import Foundation
import PageWidgetSupport

/// Turns what the popover shows into the small file Page's widgets read.
/// Everything that came from an agent (what a page asks, the step a session is
/// on) is redacted here, with the same rules as a phone page, and clipped by
/// `WidgetSnapshot.bounded()`. Nothing else leaves: no transcript, no path
/// beyond what the step line says, no token, no relay address.
enum WidgetSnapshotBuilder {
    /// Pure.
    static func build(model: NowModel, snapshot: Coordinator.Snapshot, cardGlow: CardGlow, now: Date,
                      running: Bool = true) -> WidgetSnapshot {
        let mood: WidgetSnapshot.Mood
        switch model.mood {
        case .needsYou: mood = .needsYou
        case .working: mood = .working
        case .quiet: mood = .quiet
        case .dusk: mood = .dusk
        }
        let p = snapshot.power
        let battery = p.hasBattery && p.percent >= 0
            ? WidgetSnapshot.Battery(percent: p.percent, onAC: p.onAC, charging: p.isCharging) : nil
        // Decisions and looks (not finished sessions), most urgent first, as the popover lists them.
        let decisions = model.rows.filter { $0.section == .decide || $0.section == .look }
            .prefix(WidgetSnapshot.Limits.maxDecisions).map { row in
                WidgetSnapshot.Decision(
                    id: row.id, project: row.projectName, chip: row.chip.rawValue,
                    summary: redacted(row.summary, limit: WidgetSnapshot.Limits.maxSummary))
            }
        let flight = model.flight.prefix(WidgetSnapshot.Limits.maxInFlight).map { row in
            WidgetSnapshot.Flight(
                id: row.id, project: row.project,
                doing: row.doing == InFlightRows.workingText ? "" : redacted(row.doing, limit: WidgetSnapshot.Limits.maxDoing))
        }
        var usage: WidgetSnapshot.Usage?
        if let u = snapshot.usage, u.fiveHour != nil || u.sevenDay != nil {
            usage = WidgetSnapshot.Usage(
                fiveHour: u.fiveHour.map { .init(pct: $0.pct, resetsAt: $0.resetsAt) },
                sevenDay: u.sevenDay.map { .init(pct: $0.pct, resetsAt: $0.resetsAt) },
                updatedAt: u.updatedAt)
        }
        return WidgetSnapshot(
            writtenAt: now, running: running, macName: model.macName, mood: mood,
            needYou: model.needYouCount, look: model.lookCount, working: model.workingCount,
            subline: model.subline, clearUntil: model.runway.clearUntil.map(roundedToMinute), battery: battery,
            decisions: Array(decisions), inFlight: Array(flight), usage: usage, cardGlow: cardGlow.rawValue
        ).bounded()
    }

    /// Pure. The runway's end to the minute: the widgets show it as HH:mm, and on battery it is
    /// re-estimated at every tick, so unrounded it would look like a change every time.
    static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// Redact first, collapse file paths to their last part, then clip: a clip can leave a fragment of a
    /// secret too short for its pattern, and the widgets sit on the desktop where a screen share shows them.
    static func redacted(_ text: String, limit: Int) -> String {
        let safe = ContextRedactor.redactedPrefix(text, max(limit, 400))
        return WidgetSnapshot.clean(collapsingPaths(safe), limit: limit)
    }

    /// Pure. Every absolute (`/Users/me/clients/plan/notes.md`) or home (`~/clients/notes.md`) path in
    /// `text` becomes its last part (`notes.md`); a bare folder or a lone `~` becomes `~`.
    static func collapsingPaths(_ text: String) -> String {
        // A path starts at the beginning or after whitespace/quote/bracket/`=`/`:`, so a URL's `//` and a
        // fraction such as `1/2` are left alone.
        let pattern = #"(?<![\w/.:~-])(?:~|/)[^\s'"`<>()\[\]{},;|&]*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let token = ns.substring(with: m.range)
            out += collapsedPath(token)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func collapsedPath(_ token: String) -> String {
        // "~" or "/" alone, or "~user" without a slash, is not a path to a file.
        guard token.contains("/") else { return token }
        let parts = token.split(separator: "/", omittingEmptySubsequences: true)
        // A single-segment absolute path ("/dev", "/tmp") is short and carries nothing private: keep it.
        if token.hasPrefix("/"), parts.count <= 1 { return token }
        guard let last = parts.last, last != "~" else { return "~" }
        // A trailing slash was a folder: keep the slash so it still reads as one.
        return token.hasSuffix("/") ? String(last) + "/" : String(last)
    }
}
