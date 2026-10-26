import SwiftUI

private typealias P = NightWatch.Palette

// MARK: - Bindings

extension TowerStore {
    /// A binding to a form field.
    func bind<T>(_ keyPath: WritableKeyPath<PreferencesForm, T>) -> Binding<T> {
        Binding(get: { self.form[keyPath: keyPath] }, set: { self.form[keyPath: keyPath] = $0 })
    }

    /// A slider binding to a `Double` field, rounded as the old sliders were.
    func slider(_ keyPath: WritableKeyPath<PreferencesForm, Double>) -> Binding<Double> {
        Binding(get: { self.form[keyPath: keyPath] }, set: { self.form[keyPath: keyPath] = $0.rounded() })
    }
}

/// The selected section's page.
struct NWTowerPageContent: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        switch store.selection {
        case .power: NWPowerPage(store: store)
        case .budget: NWBudgetPage(store: store)
        case .macsPhones: NWMacsPhonesPage(store: store)
        case .attention: NWAttentionPage(store: store)
        case .agents: NWAgentsPage(store: store)
        case .shortcuts: NWShortcutsPage()
        case .pairing: NWPairingPage(store: store)
        case .about: NWAboutPage(store: store)
        }
    }
}

// MARK: - Power

struct NWPowerPage: View {
    @ObservedObject var store: TowerStore

    private var inputs: PowerInputs {
        let f = store.form
        let s = store.snapshot
        return PowerInputs(
            power: s?.power ?? PowerSnapshot(percent: -1, onAC: true, hasBattery: false, isCharging: false),
            forecast: s?.batteryForecast, phase: s?.battery.phase ?? .normal,
            awake: s?.awake ?? .none, lidClosedOnBattery: s?.lidClosedOnBattery ?? false,
            lidBlocker: s?.lidClosedOnBatteryBlocker, cutoff: f.lowBatteryCutoff,
            recoveryThreshold: f.recoveryThreshold, action: f.lowBatteryAction, earlyPause: f.earlyBatteryPause,
            keepAwakeLidClosedOnAC: f.keepAwakeLidClosedOnAC, keepAwakeLidClosedOnBattery: f.keepAwakeLidClosedOnBattery)
    }

    var body: some View {
        let f = store.form
        let pauses = TowerRules.pausesAgents(f.lowBatteryAction)
        NWPage(section: .power) {
            NWPowerHeroCard(hero: PowerPage.hero(inputs))

            HStack(alignment: .top, spacing: 18) {
                NWCard {
                    NWToggleRow(title: "Lid closed on AC", detail: "holds PreventSystemSleep while agents work",
                                isOn: store.bind(\.keepAwakeLidClosedOnAC))
                    NWDivider()
                    NWToggleRowCustom(title: "Lid closed on battery", detail: "needs the power helper · watchdog undoes it",
                                      isOn: f.keepAwakeLidClosedOnBattery, set: { store.setLidClosedOnBattery($0) })
                    NWDivider()
                    NWSegmentedRow(title: "Hold for a waiting page", detail: "so a reply can still land",
                                   options: TowerOptions.holdOptions(current: f.holdAwakeForPendingPageMinutes),
                                   selection: store.slider(\.holdAwakeForPendingPageMinutes))
                }
                NWCard {
                    NWSegmentedRow(title: "Cutoff", detail: "on battery only",
                                   options: TowerOptions.cutoffOptions(current: f.lowBatteryCutoff),
                                   selection: Binding(get: { f.lowBatteryCutoff }, set: { store.setCutoff($0) }))
                    NWDivider()
                    NWSegmentedRow(title: "Agents should", detail: TowerOptions.actionDetail(f.lowBatteryAction),
                                   options: LowBatteryAction.allCases.map { ($0, TowerOptions.actionLabel($0)) },
                                   selection: store.bind(\.lowBatteryAction))
                    NWDivider()
                    NWToggleRow(title: "Pause early", detail: "~\(BatteryForecast.earlyPauseWithin) min before, by forecast",
                                isOn: store.bind(\.earlyBatteryPause), enabled: pauses)
                    NWDivider()
                    NWToggleRow(title: "Resume on power",
                                detail: PowerPage.resumeDetail(recoveryThreshold: f.recoveryThreshold, requiresAC: f.recoveryRequiresAC),
                                isOn: store.bind(\.resumeAfterBatteryRecovery), enabled: pauses)
                }
            }

            NWPowerHelperCard(store: store)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    NWCard(title: "BATTERY, FINE TUNING") {
                        NWSliderRow(title: "Cutoff level", detail: "the battery level where agents are asked to pause",
                                    valueText: "\(f.lowBatteryCutoff)%",
                                    value: Binding(get: { Double(f.lowBatteryCutoff) }, set: { store.setCutoff(Int($0.rounded())) }),
                                    range: 0...50)
                        NWDivider()
                        NWSliderRow(title: "Power counts as back at", detail: nil, valueText: "\(f.recoveryThreshold)%",
                                    value: Binding(get: { Double(f.recoveryThreshold) }, set: { store.setRecovery(Int($0.rounded())) }),
                                    range: 5...100)
                        NWDivider()
                        NWToggleRow(title: "Only while plugged in", detail: "count it as recovered only on AC",
                                    isOn: store.bind(\.recoveryRequiresAC))
                        NWDivider()
                        NWSliderRow(title: "Summary time", detail: "keep the Mac awake for their summary, then let it sleep",
                                    valueText: TowerFormat.duration(f.lowBatteryPauseGraceSeconds),
                                    value: store.slider(\.lowBatteryPauseGraceSeconds),
                                    range: Config.Limits.lowBatteryPauseGrace.lowerBound...300, enabled: pauses)
                    }
                    NWNote(text: "Paused sessions get a phone page each (reply to send them instructions) and are listed in Page’s menu. Never triggers while plugged in, or on a Mac without a battery.")
                        .padding(.horizontal, 4)
                }
                VStack(alignment: .leading, spacing: 10) {
                    NWCard(title: "KEEPING AWAKE, FINE TUNING") {
                        NWSliderRow(title: "Hold for a waiting page", detail: "keep the Mac awake so the reply can be delivered, for up to",
                                    valueText: TowerFormat.holdAwake(minutes: f.holdAwakeForPendingPageMinutes),
                                    value: store.slider(\.holdAwakeForPendingPageMinutes), range: 0...240)
                        NWDivider()
                        NWToggleRow(title: "Only while Claude is writing", detail: "keep awake only while transcripts are being written",
                                    isOn: store.bind(\.requireRecentTranscriptActivity))
                        NWDivider()
                        NWSliderRow(title: "Idle after no transcript writes for", detail: nil,
                                    valueText: TowerFormat.duration(f.transcriptActivityWindowSeconds),
                                    value: store.slider(\.transcriptActivityWindowSeconds), range: 15...600)
                        NWDivider()
                        NWSliderRow(title: "Check every", detail: nil, valueText: TowerFormat.duration(f.checkIntervalSeconds),
                                    value: store.slider(\.checkIntervalSeconds),
                                    range: Config.Limits.checkInterval.lowerBound...120)
                    }
                    NWNote(text: "While Claude Code or Codex is working, Page keeps the Mac from idle-sleeping, and lets it sleep again as soon as they stop.")
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

/// The big battery percentage with the runway bar under it.
struct NWPowerHeroCard: View {
    var hero: PowerHero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hero.bigText)
                .font(Font.system(size: 54, weight: .bold)).kerning(-2)
                .foregroundColor(P.textPrimary.color)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(hero.line)
                    .font(Font.system(size: 14, weight: .regular))
                    .foregroundColor(P.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let lid = hero.lid {
                    NWStateChip(text: lid.text, color: lidColor(lid.tone), symbol: "laptopcomputer")
                }
            }
            if let bar = hero.bar {
                NWBatteryBar(bar: bar).padding(.top, 8)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 20, fill: RGBAHex.card, glowHeight: 14))
        .accessibilityElement(children: .combine)
    }

    private func lidColor(_ t: LidChip.Tone) -> NightWatch.RGBA {
        switch t {
        case .active: return P.teal
        case .blocked: return P.amber
        case .idle: return P.textTertiary
        }
    }
}

/// Charge as a bar, amber at the low end shading to green, with a red tick
/// at the cutoff and an amber one where pausing early would start.
struct NWBatteryBar: View {
    var bar: BatteryBarModel
    private let barHeight: CGFloat = 12
    private let labelWidth: CGFloat = 90

    /// Pure. Where the two labels go: the cutoff label sits left of its tick
    /// when there is room (else right of it), the pause-early label right of
    /// its tick; when they would still collide the second drops a row.
    static func labelLayout(cutoffX: CGFloat, earlyX: CGFloat?) -> (cutoffTrailing: Bool, earlyRow: Int) {
        let trailing = cutoffX >= 70
        guard let earlyX else { return (trailing, 0) }
        let collide = !trailing && earlyX - cutoffX < 100
        return (trailing, collide ? 1 : 0)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cx = w * CGFloat(bar.cutoff)
            let ex = bar.pauseEarly.map { w * CGFloat($0) }
            let layout = Self.labelLayout(cutoffX: cx, earlyX: ex)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: w, height: barHeight)
                Capsule()
                    .fill(LinearGradient(colors: [P.amber.color, P.green.opacity(0.95).color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(barHeight, w * CGFloat(bar.fill)), height: barHeight)
                tick(at: cx, color: P.red, opacity: 1)
                label(bar.cutoffLabel, color: P.red, x: cx, trailing: layout.cutoffTrailing, row: 0)
                if let ex, bar.pauseEarly != nil {
                    tick(at: ex, color: P.amber, opacity: bar.pauseEarlyOn ? 1 : 0.45)
                    label(bar.pauseEarlyLabel, color: P.amber.opacity(bar.pauseEarlyOn ? 1 : 0.55), x: ex, trailing: false, row: layout.earlyRow)
                }
            }
        }
        .frame(height: barHeight + 24 + 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery \(Int((bar.fill * 100).rounded()))%, \(bar.cutoffLabel)"))
    }

    private func tick(at x: CGFloat, color: NightWatch.RGBA, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color.color.opacity(opacity))
            .frame(width: 2, height: barHeight + 10)
            .offset(x: x - 1, y: -5)
    }

    private func label(_ text: String, color: NightWatch.RGBA, x: CGFloat, trailing: Bool, row: Int) -> some View {
        Text(text)
            .font(Font.system(size: 11, weight: .bold))
            .foregroundColor(color.color)
            .lineLimit(1)
            .frame(width: labelWidth, alignment: trailing ? .trailing : .leading)
            .offset(x: trailing ? x - labelWidth - 7 : x + 7, y: barHeight + 6 + CGFloat(row) * 14)
    }
}

/// Whether the sudo rule behind "lid closed on battery" is installed, with
/// Install (admin prompt) and Check again.
struct NWPowerHelperCard: View {
    @ObservedObject var store: TowerStore

    private var status: (text: String, tone: TowerStatusLine.Tone, symbol: String) {
        let wanted = store.form.keepAwakeLidClosedOnBattery
        if store.helperInstalling { return ("Waiting for your password…", .quiet, "lock") }
        switch store.helperStatus {
        case .available: return ("Power helper installed.", .good, "checkmark.circle.fill")
        case .missing:
            return ("Power helper not installed\(wanted ? " — this option does nothing until it is" : "")."
                    + " Click Install and enter your Mac password once.", wanted ? .bad : .quiet, "exclamationmark.circle")
        case .unknown: return ("Checking the power helper…", .quiet, "ellipsis.circle")
        }
    }

    var body: some View {
        let st = status
        NWCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Power helper").font(Font.system(size: 13.5, weight: .semibold)).foregroundColor(P.textPrimary.color)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: st.symbol)
                        Text(st.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Font.system(size: 11.5))
                    .foregroundColor(helperColor(st.tone).color)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if store.helperStatus == .missing && !store.helperInstalling {
                        NWButton(title: "Install…", kind: .primary) { store.installHelper() }
                    }
                    NWButton(title: "Check again", kind: .secondary, enabled: !store.helperInstalling) { store.checkHelper(refresh: true) }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            NWDivider()
            Text("On battery macOS always sleeps when the lid closes, so “lid closed on battery” uses “pmset disablesleep” — only while an agent is actually mid-turn (not while waiting on a rate-limit reset, a page or a prompt) and the Mac isn’t running hot. It turns on only above your low-battery level + 5%, and stays on down to that level so agents can pause and write their summary with the lid closed; then the Mac sleeps. Risk: a closed MacBook in a bag stays awake and warm. Page turns it off the moment any of that changes, when it quits, and a watchdog turns it off within a minute if Page crashes (a few minutes if it hangs).")
                .font(Font.system(size: 11)).foregroundColor(P.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
    }

    private func helperColor(_ t: TowerStatusLine.Tone) -> NightWatch.RGBA {
        switch t {
        case .quiet: return P.textTertiary
        case .good: return P.green
        case .bad: return P.red.mixed(with: P.amber, 0.35)
        }
    }
}

// MARK: - Budget

struct NWBudgetPage: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        let budget = BudgetModel.build(usage: store.snapshot?.usage, hitAt: store.snapshot?.usageHitAt,
                                       now: store.now(), timeZone: store.timeZone)
        NWPage(section: .budget) {
            NWCard(title: "CLAUDE USAGE") {
                if budget.rings.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "speedometer").font(Font.system(size: 22)).foregroundColor(P.textQuiet.color)
                        Text(store.usageCapture.on
                             ? "Numbers appear after Claude Code next draws its status line."
                             : "Turn on usage capture below to see your 5-hour and 7-day limits here.")
                            .font(Font.system(size: 13)).foregroundColor(P.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                } else {
                    HStack(alignment: .center, spacing: 36) {
                        ForEach(budget.rings) { NWBudgetRingView(ring: $0) }
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 6) {
                            if let line = budget.forecastLine {
                                Text(line).font(Font.system(size: 13, weight: .semibold)).foregroundColor(P.amber.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("No limit in sight at this pace").font(Font.system(size: 13, weight: .semibold))
                                    .foregroundColor(P.teal.color)
                            }
                            if let updated = budget.updatedLine {
                                Text(updated).font(Font.system(size: 11.5)).foregroundColor(P.textTertiary.color)
                            }
                        }
                        .frame(maxWidth: 230, alignment: .leading)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                }
                NWDivider()
                NWToggleRowCustom(title: "Show my Claude usage", detail: "5-hour and 7-day numbers, and a forecast of the limit",
                                  isOn: store.usageCapture.on, set: { store.setUsageCapture($0) })
                if !store.usageCapture.text.isEmpty {
                    NWNote(text: store.usageCapture.text, tone: store.usageCapture.failed ? .bad : .quiet)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            NWNote(text: "Claude Code only gives these numbers to your status line, so Page wraps it: a small script saves them, then runs your own status line unchanged. Changes ~/.claude/settings.json (backed up first); turning this off puts it back. This one applies straight away.")
                .padding(.horizontal, 4).padding(.top, -10)

            NWCard(title: "WHEN CLAUDE HITS A RATE LIMIT") {
                NWToggleRow(title: "Watch for rate-limit events", detail: "reads Claude’s transcripts for “limit reached”",
                            isOn: store.bind(\.rateLimitWatcherEnabled))
                NWDivider()
                NWToggleRow(title: "Auto-schedule a resume", detail: "at the reset time, so the work carries on without you",
                            isOn: store.bind(\.autoResumeEnabled))
                NWDivider()
                NWFieldRow(title: "Resume prompt", detail: "what Page sends when the limit resets",
                           text: store.bind(\.carryOnPrompt), placeholder: "carry on", monospaced: false)
                NWDivider()
                NWToggleRow(title: "Keep the Mac awake through the reset wait", detail: "so the resume can run",
                            isOn: store.bind(\.holdAssertionUntilReset))
                NWDivider()
                NWToggleRow(title: "Wake the Mac before the resume", detail: "schedules a pmset wake · uses the power helper (see Power)",
                            isOn: store.bind(\.wakeViaPmsetEnabled))
            }
            NWNote(text: "Auto-resume works for Claude sessions only. On your phone you can also reply to a rate-limit page with a message to send when it resets.")
                .padding(.horizontal, 4).padding(.top, -10)
        }
    }
}

struct NWBudgetRingView: View {
    var ring: BudgetRing

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                NWRing(progress: ring.progress, color: ring.isHigh ? P.amber : P.teal, lineWidth: 8, size: 76)
                Text(ring.percentText)
                    .font(Font.system(size: 17, weight: .bold)).kerning(-0.3)
                    .foregroundColor(P.textPrimary.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(ring.kind.rawValue.uppercased()).nwLabel()
                Text(ring.resetText).font(Font.system(size: 12, design: .monospaced)).foregroundColor(P.textSecondary.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(ring.kind.rawValue) limit \(ring.percentText), \(ring.resetText)"))
    }
}

// MARK: - Macs & phones

struct NWMacsPhonesPage: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        let chip = TowerPhone.relayChip(store.snapshot?.relayState)
        let relay = store.relayLine
        NWPage(section: .macsPhones) {
            NWCard(title: "THIS MAC") {
                NWRow(title: store.model?.macName ?? store.macName, detail: "Page runs here and holds the keystrokes") {
                    NWStateChip(text: chip.text, color: chipColor(chip.tone), symbol: "dot.radiowaves.left.and.right")
                }
            }
            NWCard(title: "PHONE RELAY") {
                NWToggleRowCustom(title: "Send pages to my phone", detail: "via your relay, a small Cloudflare Worker you deploy once",
                                  isOn: store.form.relayEnabled, set: { store.form.relayEnabled = $0; store.relayEdited() })
                NWDivider()
                NWFieldRow(title: "Relay URL", detail: nil,
                           text: Binding(get: { store.form.relayURL }, set: { store.form.relayURL = $0; store.relayEdited() }),
                           placeholder: "https://page-relay.<your-account>.workers.dev",
                           trailing: AnyView(NWButton(title: "Test", kind: .secondary, enabled: relay.canTest) { store.testRelay() }))
                if !relay.line.text.isEmpty {
                    NWNote(text: relay.line.text, tone: relay.line.tone)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            NWNote(text: "Deploy the relay Worker once (Cloudflare/README.md), paste its URL here, then use “Pair phone…” under Pairing & encryption.")
                .padding(.horizontal, 4).padding(.top, -10)
            NWCard(title: "WHAT YOUR PHONE MAY DO") {
                NWToggleRow(title: "Show my live sessions on my phone",
                            detail: "and let it type into them or stop them · end-to-end encrypted",
                            isOn: store.bind(\.remoteSessionsEnabled))
                NWDivider()
                NWToggleRow(title: "Let my phone start new Claude sessions",
                            detail: "in cmux, in folders Claude already used in the last 30 days · only from your paired phone",
                            isOn: store.bind(\.phoneStartSessionsEnabled))
                NWDivider()
                NWToggleRow(title: "Deliver replies to an exited session",
                            detail: "with a background “claude --resume” (output goes to a log file)",
                            isOn: store.bind(\.headlessResumeFallbackEnabled))
            }
        }
    }

    private func chipColor(_ t: TowerPhone.RelayChip.Tone) -> NightWatch.RGBA {
        switch t {
        case .good: return P.teal
        case .working: return P.amber
        case .quiet: return P.textTertiary
        case .bad: return P.amber
        }
    }
}

// MARK: - Attention

struct NWAttentionPage: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        let rows = Array((store.model?.rows ?? []).prefix(5))
        NWPage(section: .attention) {
            NWCard(title: "WAITING ON YOU NOW") {
                if rows.isEmpty {
                    NWRow(title: "Nothing is waiting", detail: "Pages show here, and in the Now panel, as they arrive") {
                        Image(systemName: "checkmark.circle").font(Font.system(size: 18)).foregroundColor(P.teal.opacity(0.8).color)
                    }
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { n, row in
                        if n > 0 { NWDivider() }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            NWChip(kind: row.chip).frame(width: 96, alignment: .leading)
                            Text(row.projectName).font(NightWatch.Typo.mono).foregroundColor(P.textPrimary.color)
                            Text(row.summary).font(NightWatch.Typo.monoBody).foregroundColor(P.textTertiary.color)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
            }
            NWCard(title: "WHEN PAGE PAGES YOU") {
                NWToggleRow(title: "Detect sessions that need me", detail: "approvals, questions, finished turns",
                            isOn: store.bind(\.interventionDetectionEnabled))
                NWDivider()
                NWSliderRow(title: "Page about a finished turn only after I’ve been away from the Mac for",
                            detail: nil, valueText: TowerFormat.duration(store.form.idlePageOnlyWhenAwaySeconds, zero: "Always"),
                            value: store.slider(\.idlePageOnlyWhenAwaySeconds), range: 0...900)
                NWDivider()
                NWSliderRow(title: "…and the session has been idle for", detail: nil,
                            valueText: TowerFormat.duration(store.form.idlePageDelaySeconds, zero: "Now"),
                            value: store.slider(\.idlePageDelaySeconds), range: 0...900)
            }
            NWNote(text: "Approvals and questions always page right away — they block the agent.")
                .padding(.horizontal, 4).padding(.top, -10)
            NWCard(title: "ALERTS") {
                NWToggleRow(title: "Page me when an agent looks stuck",
                            detail: "a failing command on repeat, no progress, a stalled workflow",
                            isOn: store.bind(\.stuckAlertsEnabled))
                NWDivider()
                NWSliderRow(title: "Count it as no progress after", detail: nil,
                            valueText: "\(Int(store.form.stuckAfterMinutes.rounded())) min",
                            value: store.slider(\.stuckAfterMinutes),
                            range: Config.Limits.stuckAfterMinutes.lowerBound...120,
                            enabled: TowerRules.stuckMinutesEnabled(store.form))
                NWDivider()
                NWToggleRow(title: "Start finished-turn pages with what changed",
                            detail: "“Changed 3 files (+120 −14) · tests passed”",
                            isOn: store.bind(\.turnSummaryEnabled))
                NWDivider()
                NWToggleRow(title: "Page me before the battery cutoff",
                            detail: "when it is about 15 minutes away while agents work",
                            isOn: store.bind(\.batteryForecastPageEnabled))
                NWDivider()
                NWToggleRow(title: "Page me before Claude’s 5-hour limit",
                            detail: "when I’m about 30 minutes from it · needs usage capture (Budget)",
                            isOn: store.bind(\.usageForecastPageEnabled))
            }
            NWNote(text: "A loop is the same call failing 3 times in a row, or 5 times in the last 12 steps. Reply to the page to steer it, or Deny to stop it (Esc). Only counts go in a finished-turn page; the file list and diff are sent to your phone end-to-end encrypted when you open them.")
                .padding(.horizontal, 4).padding(.top, -10)
        }
    }
}

// MARK: - Agents

struct NWAgentsPage: View {
    @ObservedObject var store: TowerStore

    private func info(_ id: AgentBackendID) -> Coordinator.BackendInfo? {
        store.snapshot?.backends.first { $0.id == id }
    }

    var body: some View {
        let f = store.form
        NWPage(section: .agents) {
            NWCard(title: "WATCHED") {
                NWRow(title: "Claude Code", detail: "always watched · " + TowerAgents.backendLine(info(.claude), fallback: "sessions appear as they start")) {
                    NWStateChip(text: "On", color: P.teal, symbol: "checkmark.circle.fill")
                }
                NWDivider()
                NWToggleRow(title: "Watch Codex sessions",
                            detail: f.codexBackendEnabled
                                ? (info(.codex)?.enabled == true || info(.codex)?.problem != nil
                                   ? TowerAgents.backendLine(info(.codex), fallback: "waiting for sessions") : "starts watching when you Apply")
                                : nil,
                            isOn: store.bind(\.codexBackendEnabled))
                NWDivider()
                NWFieldRow(title: "codex path", detail: nil, text: store.bind(\.codexPath),
                           placeholder: "Blank = auto-detect", enabled: TowerRules.codexPathEnabled(f))
                if let line = store.codexLine {
                    NWNote(text: line.text, tone: line.tone).padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            NWCard(title: "LOCAL MODELS") {
                NWToggleRow(title: "Keep the Mac awake while local models work",
                            detail: "Ollama, LM Studio, llama.cpp, MLX",
                            isOn: store.bind(\.localModelsEnabled))
                NWNote(text: store.localModelsText, tone: .quiet, mono: f.localModelsEnabled && !store.localLines.isEmpty)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            NWNote(text: "Only while a model is actually generating — a loaded but idle model never keeps the Mac awake. Terminal tools (opencode, aider, goose, crush, ollama run, llama-cli…) count while they're producing output. Page only looks: it never starts, stops or unloads models. Claude Code and Codex pointed at Ollama or LM Studio are detected automatically, and Page won't restart them in the background on your Anthropic account.")
                .padding(.horizontal, 4).padding(.top, -10)
            NWCard(title: "INTEGRATIONS") {
                NWRow(title: "cmux", detail: "lets Page type into your cmux panes, and start sessions there") {
                    NWButton(title: "Set up cmux…", kind: .secondary) { store.env.setUpCmux() }
                }
                NWDivider()
                NWRow(title: "Agent hooks", detail: "phone approvals for Claude Code and Codex, with a diff and a backup first") {
                    NWButton(title: "Install agent hooks…", kind: .secondary) { store.env.installHooks() }
                }
                NWDivider()
                NWRow(title: "Local-model diagnostics", detail: "copies what Page sees, for a bug report") {
                    NWButton(title: "Copy diagnostics", kind: .secondary) { store.env.copyLocalDiagnostics() }
                }
            }
        }
    }
}

// MARK: - Shortcuts

struct NWShortcutsPage: View {
    var body: some View {
        NWPage(section: .shortcuts) {
            ForEach(ShortcutCatalog.groups) { group in
                NWCard(title: group.title) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { n, item in
                        if n > 0 { NWDivider() }
                        NWRow(title: item.title, detail: item.detail) {
                            HStack(spacing: 5) { ForEach(Array(item.keys.enumerated()), id: \.offset) { _, k in NWKeyCap(label: k) } }
                        }
                    }
                }
            }
            NWNote(text: "Page approves by typing option 1, denies with Esc, and sends only what you write. It never presses 2, never offers “Yes, and don’t ask again”, and has no auto-allow or auto-deny.")
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - Pairing & encryption

struct NWPairingPage: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        let chip = TowerPhone.relayChip(store.snapshot?.relayState)
        NWPage(section: .pairing) {
            NWCard(title: "PAIR A PHONE") {
                NWRow(title: "Pair phone…", detail: "scan a QR with Page on your phone. Needs the phone relay (Macs & phones).") {
                    NWButton(title: "Pair phone…", kind: .primary) { store.env.pairPhone() }
                }
                NWDivider()
                NWRow(title: "Relay", detail: nil) {
                    NWStateChip(text: chip.text, color: chip.tone == .good ? P.teal : (chip.tone == .quiet ? P.textTertiary : P.amber), symbol: nil)
                }
            }
            NWCard(title: "WHO CAN READ WHAT") {
                NWRow(title: "Sessions are end-to-end encrypted", detail: "with the key in the pairing QR. The relay carries the messages but can’t read them.") {
                    Image(systemName: "lock.fill").foregroundColor(P.teal.color)
                }
                NWDivider()
                NWRow(title: "Phones paired before encryption", detail: "need to scan the QR again.") {
                    Image(systemName: "qrcode").foregroundColor(P.textTertiary.color)
                }
                NWDivider()
                NWRow(title: "Retire a pairing", detail: "open Pair phone… and choose “Regenerate token…”. Phones on the old token stop receiving pages until they scan the new QR.") {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(P.textTertiary.color)
                }
            }
        }
    }
}

// MARK: - About

struct NWAboutPage: View {
    @ObservedObject var store: TowerStore
    var version: String = TowerAbout.versionText

    var body: some View {
        NWPage(section: .about) {
            NWCard {
                NWRow(title: "Page", detail: version) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(Font.system(size: 20)).foregroundColor(P.teal.color)
                }
            }
            NWCard(title: "APPEARANCE") {
                NWSegmentedRow(title: "Card glow", detail: TowerOptions.cardGlowDetail(store.form.cardGlow),
                               options: CardGlow.allCases.map { ($0, $0.label) },
                               selection: store.bind(\.cardGlow))
            }
            NWCard(title: "FILES") {
                NWRow(title: "Config file", detail: "config.json: every setting here, and a few more") {
                    NWButton(title: "Open Config File…", kind: .secondary) { store.env.openConfigFile() }
                }
                NWDivider()
                NWRow(title: "Log", detail: "everything Page did, in one file (the audit log)") {
                    NWButton(title: "Open Log", kind: .secondary) { store.env.openLog() }
                }
                NWDivider()
                NWRow(title: "Reload config", detail: "re-read config.json after editing it by hand") {
                    NWButton(title: "Reload Config", kind: .secondary) { store.env.reloadFromMenu() }
                }
            }
            NWCard(title: "DEFAULTS") {
                NWRow(title: "Reset to defaults", detail: "everything except the relay URL and Codex path. Nothing is saved until you Apply.") {
                    NWButton(title: "Reset to defaults", kind: .secondary) { store.resetToDefaults() }
                }
            }
        }
    }
}

enum TowerAbout {
    /// "Version 1.4" from the bundle, or a development build when run from `swift build`.
    static var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "Version \($0)" } ?? "Development build"
    }
}
