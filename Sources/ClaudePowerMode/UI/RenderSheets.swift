import AppKit
import SwiftUI

/// Every component on one sheet, for the harness. Not shipped UI.
struct NWComponentSheet: View {
    @State private var segment = 1
    private let model = NowModel.build(NightWatchFixtures.needsYou())

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("CHIPS") {
                HStack(spacing: 18) { ForEach(ChipKind.allCases, id: \.self) { NWChip(kind: $0) } }
                HStack(spacing: 10) { ForEach([ChipKind.irreversible, .undoable, .looksStuck, .considered], id: \.self) { NWChip(kind: $0, pill: true) } }
            }
            section("KEY CAPS") {
                HStack(spacing: 8) {
                    NWKeyCap(label: "hold 1"); NWKeyCap(label: "esc"); NWKeyCap(label: "↵", emphasised: true)
                    NWKeyCap(label: "1"); NWKeyCap(label: "O"); NWKeyCap(label: "T"); NWKeyCap(label: "⌘N")
                }
            }
            section("TOGGLE · SEGMENTED") {
                HStack(spacing: 24) {
                    NWSwitch(isOn: true); NWSwitch(isOn: false)
                    NWSegmented(options: [(0, "5%"), (1, "10%"), (2, "15%"), (3, "20%")], selection: $segment)
                    NWSegmented(options: [(0, "Pause"), (1, "After step"), (2, "Off")], selection: $segment)
                }
            }
            section("RINGS") {
                NWRingsRow(rings: DayStats(unblockedFast: 11, decisions: 12, shipped: 7, finished: 10,
                                           calmSeconds: 15_000).rings, ringSize: 28, showsDetail: true)
            }
            section("RUNWAY") {
                NWRunwayBar(model: model.runway).frame(width: 380)
                NWRunwayBar(model: NowModel.build(NightWatchFixtures.onBattery()).runway).frame(width: 380)
                NWRunwayBar(model: NowModel.build(NightWatchFixtures.allQuiet()).runway).frame(width: 380)
            }
            section("RECEIPT LINE") {
                NWReceiptLine(text: "Approved npm test → cmux › page · verified 23:47:12").frame(width: 380)
                NWReceiptLine(text: "swift test · Didn't confirm in time · Check on Mac", failed: true).frame(width: 380)
            }
            section("AURORA HEADERS") {
                HStack(spacing: 12) {
                    ForEach([("Needs you", NightWatch.AuroraPalette.needsYou, NWPulseOrb.Style.needsYou),
                             ("Working", .working, .working), ("Quiet", .quiet, .quiet), ("Dusk", .dusk, .dusk)], id: \.0) { item in
                        NWAuroraHeader(palette: item.1, headline: item.0, subline: "palette", pulse: item.2, height: 92)
                            .frame(width: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 760, alignment: .leading)
        .background(NWBackdrop())
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).nwLabel()
            content()
        }
    }
}

/// Status-bar glyph states on a dark and a light menu bar, at native size and 5x.
struct NWGlyphSheet: View {
    struct Entry { let title: String; let state: GlyphState }

    static let entries: [Entry] = [
        Entry(title: "Working", state: GlyphState(mode: .working(agents: 5))),
        Entry(title: "Needs you · 2", state: GlyphState(mode: .needsYou(count: 2))),
        Entry(title: "Quiet", state: GlyphState(mode: .quiet)),
        Entry(title: "Keep-awake off", state: GlyphState(mode: .off)),
        Entry(title: "Lid closed awake", state: GlyphState(mode: .working(agents: 3), lidClosedAwake: true)),
        Entry(title: "Headroom 61%", state: GlyphState(mode: .working(agents: 3), headroom: 0.61)),
        Entry(title: "Headroom 12%", state: GlyphState(mode: .working(agents: 3), headroom: 0.12)),
        Entry(title: "Paused for battery", state: GlyphState(mode: .paused)),
        Entry(title: "Phone armed", state: GlyphState(mode: .working(agents: 3), phoneArmed: true)),
        Entry(title: "Everything", state: GlyphState(mode: .needsYou(count: 12), lidClosedAwake: true, headroom: 0.4, phoneArmed: true))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([GlyphDrawing.Appearance.dark, .light], id: \.self) { appearance in
                let bar = appearance == .dark ? Color(red: 0.11, green: 0.11, blue: 0.13) : Color(red: 0.90, green: 0.90, blue: 0.92)
                VStack(alignment: .leading, spacing: 8) {
                    Text(appearance == .dark ? "DARK MENU BAR" : "LIGHT MENU BAR").nwLabel()
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(Self.entries.enumerated()), id: \.offset) { _, e in
                            let d = GlyphDrawing.make(e.state, appearance: appearance, phase: 0.2, reduceMotion: false)
                            VStack(spacing: 8) {
                                Image(nsImage: StatusGlyphRenderer.image(d, scale: 1))
                                    .frame(width: CGFloat(d.width), height: 18)
                                Image(nsImage: StatusGlyphRenderer.image(d, scale: 3))
                                    .frame(width: CGFloat(d.width) * 3, height: 54)
                                Text(e.title)
                                    .font(Font.system(size: 9, weight: .medium))
                                    .foregroundColor(appearance == .dark ? Color.white.opacity(0.6) : Color.black.opacity(0.6))
                                    .multilineTextAlignment(.center)
                                    .frame(width: 100)
                            }
                            .frame(width: 100)
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bar))
                }
            }
        }
        .padding(28)
        .frame(width: 1140, alignment: .leading)
        .background(NWBackdrop())
    }
}

/// The Tower in a window-shaped frame with traffic lights drawn on (the
/// harness has no title bar), as on board 41. Not shipped UI.
struct NWTowerWindow: View {
    static let size = CGSize(width: 1120, height: 760)
    var store: TowerStore
    var height: CGFloat = NWTowerWindow.size.height

    var body: some View {
        NWTowerView(store: store)
            .frame(width: Self.size.width, height: height)
            .overlay(
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 12, height: 12)
                    }
                }
                .padding(.leading, 14).padding(.top, 14),
                alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}
