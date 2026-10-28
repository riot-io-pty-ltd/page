import SwiftUI

/// Everything the History screen draws, as values.
struct HistoryScreenData {
    var model: HistoryScreenModel
    /// What to say while there are no rows (nil when there are some).
    var empty: HistoryEmpty?
    /// The load failed with nothing to show: stats only cover this screen's pages.
    var statsPartial = false
}

struct HistoryScreenActions {
    var close: () -> Void = {}
    var retry: () -> Void = {}
    var refresh: () async -> Void = {}
}

/// History, the Night Watch way: Settled's lines for every page you have
/// resolved, one glass card per day, and the day's numbers (the three rings,
/// four tiles, the busiest projects) under a second segment. Reached from
/// Settled's "See all" and from the Tower.
struct NWHistoryScreen: View {
    enum Segment: String, Hashable { case history, stats }

    var data: HistoryScreenData
    var actions: HistoryScreenActions
    @State private var segment: Segment
    @Environment(\.dynamicTypeSize) private var typeSize

    init(data: HistoryScreenData, actions: HistoryScreenActions = HistoryScreenActions(), segment: Segment = .history) {
        self.data = data
        self.actions = actions
        _segment = State(initialValue: segment)
    }

    var body: some View {
        ZStack {
            NWBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    NWSegmented(options: [(Segment.history, "History"), (.stats, "Stats")], selection: $segment)
                    switch segment {
                    case .history: historyTab
                    case .stats: statsTab
                    }
                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, NightWatch.Space.gutter)
                .padding(.top, 18)
            }
            .refreshable { await actions.refresh() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SETTLED").font(NightWatch.Typo.labelLarge).kerning(2).foregroundColor(NightWatch.Palette.teal.color)
                Text("History").font(.system(size: 34, weight: .bold)).kerning(-0.8)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)
                if segment == .history, data.model.total > 0 {
                    Text("\(data.model.total) resolved page\(data.model.total == 1 ? "" : "s")")
                        .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                }
            }
            Spacer()
            Button(action: actions.close) {
                Image(systemName: "xmark").font(.system(.body, weight: .semibold))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .frame(width: 44, height: 44)
                    .nwChromeGlass(in: Circle()) { Circle().fill(Color.white.opacity(0.08)) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
    }

    // MARK: History

    @ViewBuilder private var historyTab: some View {
        if let empty = data.empty {
            emptyCard(empty)
        } else {
            ForEach(data.model.days) { day in
                VStack(alignment: .leading, spacing: 10) {
                    dayHeader(day)
                    card {
                        ForEach(Array(day.rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { divider }
                            rowView(row)
                        }
                    }
                }
            }
        }
    }

    private func dayHeader(_ day: HistoryDay) -> some View {
        let title = Text(day.title.uppercased()).font(NightWatch.Typo.labelLarge).kerning(1.2)
            .foregroundColor(NightWatch.Palette.textTertiary.color)
        let summary = Text(day.summary).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { title; summary }
            } else {
                HStack(alignment: .firstTextBaseline) { title; Spacer(minLength: 8); summary.multilineTextAlignment(.trailing) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowView(_ row: HistoryRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(row.tone).color).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                if typeSize.isAccessibilitySize {
                    Text(row.text).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textSecondary.color)
                    Text(row.trailing).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textTertiary.color)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.text).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textSecondary.color)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text(row.trailing).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textTertiary.color)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                }
                Text(row.detail).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.spoken))
    }

    private func color(_ t: SettledLine.Tone) -> NightWatch.RGBA {
        switch t {
        case .approved: return NightWatch.Palette.green
        case .sent: return NightWatch.Palette.sky
        case .neutral: return NightWatch.Palette.textQuiet
        }
    }

    // MARK: Empty and failed

    @ViewBuilder private func emptyCard(_ e: HistoryEmpty) -> some View {
        switch e {
        case .loading:
            NWGlassCard {
                HStack(spacing: 12) {
                    ProgressView().tint(NightWatch.Palette.textSecondary.color)
                    Text("Loading history…").font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "wifi.exclamationmark").font(.system(.body)).foregroundColor(NightWatch.Palette.amber.color)
                        .frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn't load history").font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                        Text(message).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(action: actions.retry) { Text("Try again") }.buttonStyle(NWButtonStyle(kind: .quiet))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NWGlassBackground(radius: 24, tint: NightWatch.Palette.amber))
            .accessibilityElement(children: .contain)
        case .none:
            NWGlassCard {
                VStack(spacing: 10) {
                    Image(systemName: "moon.stars").font(.system(.title)).foregroundColor(NightWatch.Palette.teal.color)
                        .accessibilityHidden(true)
                    Text("No history yet").font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                    Text("Pages you've resolved will appear here.").font(NightWatch.Typo.body)
                        .foregroundColor(NightWatch.Palette.textSecondary.color).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Stats

    @ViewBuilder private var statsTab: some View {
        if case .failed(let message)? = data.empty {
            // The history failed to load: say so here too, and that the numbers are partial.
            NWGlassCard(tint: NightWatch.Palette.amber) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Couldn't load history").font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                    Text("\(message) Stats only include pages on this screen.").font(NightWatch.Typo.body)
                        .foregroundColor(NightWatch.Palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
                    Button(action: actions.retry) { Text("Try again") }.buttonStyle(NWButtonStyle(kind: .quiet))
                }
            }
        }
        NWTonightCard(rings: data.model.rings)
        tiles
        topProjects
    }

    private var tiles: some View {
        let s = data.model.stats
        let items: [(String, String, String)] = [
            ("TODAY", "\(s.today)", s.today == 1 ? "page" : "pages"),
            ("THIS WEEK", "\(s.thisWeek)", s.thisWeek == 1 ? "page" : "pages"),
            ("AVG RESPONSE", s.avgResponseSeconds.map { RelativeTime.compact(seconds: $0) } ?? "—",
             s.repliedCount == 0 ? "no replies yet" : "across \(s.repliedCount) repl\(s.repliedCount == 1 ? "y" : "ies")"),
            ("PENDING NOW", "\(data.model.pending)", ""),
        ]
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) { ForEach(items.indices, id: \.self) { tile(items[$0]) } }
            } else {
                VStack(spacing: 12) {
                    HStack(spacing: 12) { tile(items[0]); tile(items[1]) }
                    HStack(spacing: 12) { tile(items[2]); tile(items[3]) }
                }
            }
        }
    }

    private func tile(_ t: (label: String, value: String, sub: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.label).font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
                .foregroundColor(NightWatch.Palette.textTertiary.color)
            Text(t.value).font(.system(.title, weight: .bold)).foregroundColor(NightWatch.Palette.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.6)
            if !t.sub.isEmpty {
                Text(t.sub).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NWGlassBackground(radius: NightWatch.Radius.row))
        .accessibilityElement(children: .combine)
    }

    private var topProjects: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TOP PROJECTS").font(NightWatch.Typo.labelLarge).kerning(1.2)
                .foregroundColor(NightWatch.Palette.textTertiary.color).accessibilityAddTraits(.isHeader)
            let top = data.model.stats.topProjects
            if top.isEmpty {
                NWGlassCard { Text("Nothing yet").font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textTertiary.color) }
            } else {
                card {
                    ForEach(Array(top.enumerated()), id: \.offset) { i, p in
                        if i > 0 { divider }
                        HStack(spacing: 10) {
                            Text(p.name).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(p.count)").font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textPrimary.color)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Shared

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NWGlassBackground(radius: NightWatch.Radius.card))
            .clipShape(RoundedRectangle(cornerRadius: NightWatch.Radius.card, style: .continuous))
            .overlay(NWGlassRim(radius: NightWatch.Radius.card, withGlow: false))
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 33) }
}
