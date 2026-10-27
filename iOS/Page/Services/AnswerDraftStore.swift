import SwiftUI

/// The answers being picked for each open question, by the ask's id (the
/// question's tool_use id), so the Story, the Screen lens and the Decision
/// sheet show one draft, and a half-answered question survives switching
/// lens or closing the sheet. Memory only: a typed "Other" answer is never
/// written to disk. A new question has a new id, so an old draft can never
/// answer it.
@MainActor
final class AnswerDraftStore: ObservableObject {
    static let shared = AnswerDraftStore()

    @Published private var sheets: [String: AnswerSheet] = [:]

    /// The draft for `ask`: kept while the question is unchanged, else fresh.
    func sheet(for ask: SessionAsk, allowsOther: Bool = true) -> AnswerSheet {
        if let s = sheets[ask.id], s.ask == ask, s.allowsOther == allowsOther { return s }
        return AnswerSheet(ask: ask, allowsOther: allowsOther)
    }

    func binding(for ask: SessionAsk, allowsOther: Bool = true) -> Binding<AnswerSheet> {
        Binding(get: { self.sheet(for: ask, allowsOther: allowsOther) },
                set: { new in
                    // Bounded: a long-lived app never collects drafts.
                    if self.sheets.count > 30, self.sheets[ask.id] == nil { self.sheets.removeAll() }
                    self.sheets[ask.id] = new
                })
    }

    func clear() { sheets.removeAll() }
}
