import Foundation

/// Snapshots for previews, the extension's placeholder and the render harness.
/// Invented, like every fixture: no real project, step or number.
public enum WidgetFixtures {
    public static func needsYou(now: Date, glow: String = "off") -> WidgetSnapshot {
        WidgetSnapshot(
            writtenAt: now, macName: "Studio MBP", mood: .needsYou, needYou: 2, look: 1, working: 5,
            subline: "runway clear till 02:40", clearUntil: now.addingTimeInterval(3 * 3600 + 20 * 60),
            battery: .init(percent: 64, onAC: false, charging: false),
            decisions: [
                .init(id: "sess-bottle-flip-permission-1", project: "bottle-flip", chip: "irreversible",
                      summary: "Run: terraform apply -auto-approve in infra/prod"),
                .init(id: "sess-orchard-permission-2", project: "orchard", chip: "considered",
                      summary: "Edit src/cart/totals.ts (+34 −9)"),
                .init(id: "sess-lantern-stuck-3", project: "lantern", chip: "looksStuck",
                      summary: "Same failing test 4 times"),
            ],
            inFlight: [
                .init(id: "inflight-s1", project: "harbor", doing: "Bash: swift test --filter TowerStoreTests"),
                .init(id: "inflight-s2", project: "kestrel", doing: "Edit: Sources/Router/Match.swift"),
                .init(id: "inflight-s3", project: "meadow", doing: "Reading 14 files"),
            ],
            usage: usage(now: now), cardGlow: glow)
    }

    public static func working(now: Date, glow: String = "off") -> WidgetSnapshot {
        var s = needsYou(now: now, glow: glow)
        s.mood = .working; s.needYou = 0; s.look = 0; s.decisions = []
        s.battery = .init(percent: 100, onAC: true, charging: false)
        return s
    }

    public static func quiet(now: Date, glow: String = "off") -> WidgetSnapshot {
        WidgetSnapshot(writtenAt: now, macName: "Studio MBP", mood: .quiet, needYou: 0, working: 0,
                       battery: .init(percent: 100, onAC: true, charging: false), usage: usage(now: now), cardGlow: glow)
    }

    public static func dusk(now: Date, glow: String = "off") -> WidgetSnapshot {
        WidgetSnapshot(writtenAt: now, macName: "Studio MBP", mood: .dusk, needYou: 1, working: 0,
                       subline: "3 agents summarised · plug in to resume",
                       battery: .init(percent: 10, onAC: false, charging: false),
                       decisions: [.init(id: "sess-harbor-permission-9", project: "harbor", chip: "considered",
                                         summary: "Run: npm install")],
                       usage: usage(now: now), cardGlow: glow)
    }

    public static func usage(now: Date) -> WidgetSnapshot.Usage {
        .init(fiveHour: .init(pct: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)),
              sevenDay: .init(pct: 35, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600)),
              updatedAt: now.addingTimeInterval(-90))
    }

    /// What the Tower previews and the gallery's placeholder show: a bit of everything.
    public static func sample(now: Date = Date()) -> WidgetSnapshot { needsYou(now: now) }
}
