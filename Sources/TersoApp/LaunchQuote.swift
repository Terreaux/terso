// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// A line about writing, shown at launch when the writer opts in.
struct WritingQuote: Equatable {
    let text: String
    let author: String

    static let all: [WritingQuote] = [
        WritingQuote(text: "I have made this letter longer than usual, because I have not had time to make it shorter.", author: "Blaise Pascal"),
        WritingQuote(text: "The difference between the almost right word and the right word is really a large matter — 'tis the difference between the lightning-bug and the lightning.", author: "Mark Twain"),
        WritingQuote(text: "Vigorous writing is concise.", author: "William Strunk Jr."),
        WritingQuote(text: "Either write something worth reading or do something worth writing.", author: "Benjamin Franklin"),
        WritingQuote(text: "Fill your paper with the breathings of your heart.", author: "William Wordsworth"),
        WritingQuote(text: "Brevity is the soul of wit.", author: "William Shakespeare"),
        WritingQuote(text: "True ease in writing comes from art, not chance, as those move easiest who have learned to dance.", author: "Alexander Pope"),
        WritingQuote(text: "Look in thy heart, and write.", author: "Philip Sidney"),
        WritingQuote(text: "Proper words in proper places make the true definition of a style.", author: "Jonathan Swift"),
        WritingQuote(text: "No day without a line.", author: "Pliny the Elder, after Apelles"),
        WritingQuote(text: "What is written without effort is in general read without pleasure.", author: "Samuel Johnson"),
        WritingQuote(text: "Read over your compositions, and wherever you meet with a passage which you think is particularly fine, strike it out.", author: "Samuel Johnson"),
        WritingQuote(text: "Have something to say, and say it as clearly as you can. That is the only secret of style.", author: "Matthew Arnold"),
        WritingQuote(text: "Words are, of course, the most powerful drug used by mankind.", author: "Rudyard Kipling"),
        WritingQuote(text: "Learn as much by writing as by reading.", author: "Lord Acton"),
    ]

    /// A random quote, never the one shown at the previous launch.
    static func next(defaults: UserDefaults = .standard) -> WritingQuote {
        let last = defaults.object(forKey: "lastLaunchQuote") as? Int
        let choices = all.indices.filter { $0 != last }
        let index = choices.randomElement() ?? 0
        defaults.set(index, forKey: "lastLaunchQuote")
        return all[index]
    }
}

/// Floats over the front window at launch; any click or key dismisses it,
/// and it fades on its own after a few seconds.
struct LaunchQuoteView: View {
    let quote: WritingQuote
    let dismiss: () -> Void
    @FocusState private var focused: Bool
    private var theme: EditorTheme { Preferences.shared.theme }

    var body: some View {
        ZStack {
            Color(nsColor: theme.background).opacity(0.92)
            VStack(spacing: 14) {
                Text("\u{201C}\(quote.text)\u{201D}")
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                Text("— \(quote.author)")
                    .font(.system(.body, design: .serif).italic())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520)
            .padding(40)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress { _ in dismiss(); return .handled }
        .onAppear { focused = true }
        .task {
            try? await Task.sleep(for: .seconds(6))
            dismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismisses the quote")
    }
}
