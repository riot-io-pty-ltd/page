import Foundation

/// The little chips on a Review card, read from the Mac's turn-summary line
/// ("Changed 3 files (+120 −14) · tests passed"). Anything the line does not
/// say is simply not drawn: no chip is ever invented.
struct TurnChip: Equatable {
    enum Tone: String, Equatable { case neutral, added, removed, pass, fail }
    let text: String
    let tone: Tone
}

enum TurnSummaryChips {
    /// "3 files", "+120", "−14", "tests ✓" / "tests ✗". Pure.
    static func parse(_ summary: String?) -> [TurnChip] {
        guard let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return [] }
        var chips: [TurnChip] = []
        if let r = s.range(of: #"Changed (\d+) files?"#, options: .regularExpression) {
            let n = Int(s[r].filter(\.isNumber)) ?? 0
            chips.append(TurnChip(text: "\(n) file\(n == 1 ? "" : "s")", tone: .neutral))
        }
        if let r = s.range(of: #"\+(\d+)"#, options: .regularExpression) {
            chips.append(TurnChip(text: String(s[r]), tone: .added))
        }
        if let r = s.range(of: #"[−-](\d+)\)"#, options: .regularExpression) {
            let digits = s[r].filter(\.isNumber)
            chips.append(TurnChip(text: "−\(digits)", tone: .removed))
        }
        if s.contains("tests passed") { chips.append(TurnChip(text: "tests ✓", tone: .pass)) }
        else if s.contains("tests failed") { chips.append(TurnChip(text: "tests ✗", tone: .fail)) }
        return chips
    }
}
