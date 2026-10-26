import Foundation

// The Tower: the sheet that drops from the Mac chip. Power, Budget, Macs,
// Attention, Pairing, Appearance and About, as pure values. The phone can read
// the Mac's power and usage but not change them (those switches live in Page
// on the Mac), so Power is a readout that says where to change it, never a
// switch that does nothing.

enum TowerSection: String, CaseIterable, Identifiable, Equatable {
    case power, budget, macs, attention, pairing, appearance, about

    var id: String { rawValue }

    /// "POWER" etc., as the section label.
    var title: String {
        switch self {
        case .power: return "Power"
        case .budget: return "Budget"
        case .macs: return "Macs"
        case .attention: return "Attention"
        case .pairing: return "Pairing & encryption"
        case .appearance: return "Appearance"
        case .about: return "About"
        }
    }
}

// MARK: - The Mac chip

/// The chip at the top-left of Now: "Studio MBP · on battery · 41%". It turns
/// amber when the cutoff is under 30 minutes, and offline when the Mac isn't
/// answering. Tapping it opens the Tower.
struct MacChipModel: Equatable {
    enum Tone: Equatable { case ok, warn, offline }

    let text: String
    let tone: Tone

    static let warnMinutes = 30

    static func build(macName: String, status: MacStatusSnapshot?, now: Date) -> MacChipModel {
        let name = DeliveryPreview.macLabel(macName)
        switch MacPresence.evaluate(status, now: now) {
        case .offline, .neverConnected: return MacChipModel(text: "\(name) · offline", tone: .offline)
        case .stale: return MacChipModel(text: "\(name) · not checking in", tone: .offline)
        case .unknown: return MacChipModel(text: name, tone: .ok)
        case .online: break
        }
        var parts = [name]
        if status?.onAC == true { parts.append("on AC") } else if status?.onAC == false { parts.append("on battery") }
        if let b = status?.batteryPercent { parts.append("\(b)%") }
        var tone = Tone.ok
        if status?.onAC == false, let f = status?.forecast, f.minutes < warnMinutes { tone = .warn }
        return MacChipModel(text: parts.joined(separator: " · "), tone: tone)
    }
}

// MARK: - Power

struct TowerPower: Equatable {
    /// "41% · cutoff in about 1 h 50 min".
    let headline: String
    /// "on battery", "on power".
    let state: String
    /// "Pause agents at 10% · set in Page on your Mac".
    let note: String
    /// 0...1 battery level, nil when unknown.
    let fraction: Double?
    /// Where the cutoff sits on the bar, 0...1.
    let cutoffFraction: Double?
    let warn: Bool

    static func build(status: MacStatusSnapshot?) -> TowerPower {
        guard let status else {
            return TowerPower(headline: "No reading from your Mac", state: "unknown",
                              note: "Power is read from Page on your Mac.", fraction: nil, cutoffFraction: nil, warn: false)
        }
        let pct = status.batteryPercent
        let cutoff = status.forecast?.cutoff
        let onAC = status.onAC == true
        var headline = pct.map { "\($0)%" } ?? "Battery not reported"
        if onAC {
            headline += " · agents keep running on power"
        } else if let f = status.forecast {
            headline += f.minutes == 0 ? " · at the \(f.cutoff)% cutoff" : " · cutoff in about \(MacBatteryForecast.duration(f.minutes))"
        } else if status.onAC == false {
            headline += " · on battery"
        }
        let note = cutoff.map { "Pause agents at \($0)% · set in Page on your Mac" } ?? "Cutoff and keep-awake are set in Page on your Mac."
        return TowerPower(headline: headline, state: onAC ? "on power" : (status.onAC == false ? "on battery" : "unknown"),
                          note: note, fraction: pct.map { Double($0) / 100 }, cutoffFraction: cutoff.map { Double($0) / 100 },
                          warn: !onAC && (status.forecast?.minutes ?? 99) < MacChipModel.warnMinutes)
    }
}

// MARK: - Macs

struct TowerMacRow: Equatable, Identifiable {
    let id: String
    let name: String
    /// "live · paired 3 Oct", "1 needs you".
    let subtitle: String
    let isActive: Bool
    /// "Active" or "Switch".
    let trailing: String
    let needsYou: Int
    let presence: WidgetStatus.Presence?

    static func build(saved: [SavedMac], activeId: String?, activeStatus: MacStatusSnapshot?, others: [String: WidgetStatus],
                      now: Date, calendar: Calendar = .current) -> [TowerMacRow] {
        saved.map { mac in
            let active = mac.id == activeId
            if active {
                let presence = MacPresence.evaluate(activeStatus, now: now)
                let state: String
                switch presence {
                case .online: state = "live"
                case .stale: state = "not checking in"
                case .offline, .neverConnected: state = "offline"
                case .unknown: state = "checking…"
                }
                return TowerMacRow(id: mac.id, name: mac.name, subtitle: "\(state) · paired \(pairedDate(mac.pairedAt, calendar: calendar))",
                                   isActive: true, trailing: "Active", needsYou: 0, presence: nil)
            }
            let st = others[mac.id]
            let sub = st.map { $0.headline + ($0.detail.map { " · " + $0 } ?? "") } ?? (mac.relayHost ?? "standby")
            return TowerMacRow(id: mac.id, name: mac.name, subtitle: sub, isActive: false, trailing: "Switch",
                               needsYou: st?.needsYou ?? 0, presence: st?.presence)
        }
    }

    /// "3 Oct".
    static func pairedDate(_ d: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }
}

// MARK: - Attention

/// Whether iOS lets Page notify you.
enum NotificationsState: Equatable {
    case allowed, off, notSet, checking

    var text: String {
        switch self {
        case .allowed: return "Allowed"
        case .off: return "Off — you won't be paged"
        case .notSet: return "Not set up yet"
        case .checking: return "Checking…"
        }
    }
}

enum PushStatus: Equatable {
    case registered, registering, problem(String), waitingForApple, needsNotifications

    var text: String {
        switch self {
        case .registered: return "Registered with your relay"
        case .registering: return "Registering…"
        case .problem(let why): return why
        case .waitingForApple: return "Waiting for Apple…"
        case .needsNotifications: return "Needs notifications"
        }
    }
}

enum RelayConnectionText {
    /// "Connected", "Connecting…", "Reconnecting…" or "Offline — <why>".
    static func text(connected: Bool, connecting: Bool, failure: String?) -> String {
        if connected { return "Connected" }
        if connecting { return "Connecting…" }
        if let failure { return "Offline — \(failure)" }
        return "Reconnecting…"
    }
}

// MARK: - Budget

/// The Budget section: the 5-hour and 7-day rings and the verdict line.
struct TowerBudget: Equatable {
    let model: UsageCardModel?
    /// Shown instead of rings when the Mac isn't sending usage.
    let emptyNote: String

    static func build(usage: MacUsage?, now: Date) -> TowerBudget {
        TowerBudget(model: UsageCardModel(usage, now: now),
                    emptyNote: "Turn on usage tracking in Page on your Mac to see your 5-hour and 7-day limits here.")
    }
}

// MARK: - Scroll target

enum TowerScroll {
    /// The Runway opens the Tower at Budget; the Sky's moon opens it at Power.
    static func target(from source: Source) -> TowerSection? {
        switch source {
        case .runway: return .budget
        case .moon: return .power
        case .chip: return nil
        }
    }
    enum Source { case chip, runway, moon }
}
