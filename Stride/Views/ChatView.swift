import SwiftUI

/// "Ask the coach": a conversation with the on-device model, which reads the athlete's data through tools.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    var chat: CoachChat
    @State private var draft = ""

    private static let suggestions = [
        "How did my last run go?",
        "Should I train hard today?",
        "How is my sleep trending?",
        "Swap tomorrow for a rest day",
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.messages.isEmpty {
                        intro
                    }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if let activity = chat.activity {
                        Label(activity, systemImage: "magnifyingglass").font(.footnote).foregroundStyle(.secondary)
                    } else if chat.isResponding, chat.messages.last?.text.isEmpty ?? true {
                        ProgressView().padding(.leading, 4)
                    }
                    if let error = chat.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("New conversation", systemImage: "square.and.pencil") { chat.reset() }
                .disabled(chat.messages.isEmpty || chat.isResponding)
        }
        .onAppear { chat.prewarm() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about your training, recovery or plan. The coach looks up your data on this iPhone and can change your plan when you ask.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let blocker = model.onDeviceBlocker {
                Label(blocker, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            FlowSuggestions(suggestions: Self.suggestions) { send($0) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.background.secondary, in: .rect(cornerRadius: 20))
                .onSubmit { send(draft) }
            Button("Send", systemImage: "arrow.up.circle.fill") { send(draft) }
                .labelStyle(.iconOnly)
                .font(.title)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isResponding)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ text: String) {
        draft = ""
        Task { await chat.send(text) }
    }
}

private struct MessageRow: View {
    var message: ChatMessage

    var body: some View {
        switch message.role {
        case .athlete:
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: .rect(cornerRadius: 18))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .coach:
            if !message.text.isEmpty {
                Text(AttributedString(coachMarkdown: message.text))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background.secondary, in: .rect(cornerRadius: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 48)
                    .textSelection(.enabled)
            }
        case .notice:
            Label(message.text, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct FlowSuggestions: View {
    var suggestions: [String]
    var action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button(suggestion) { action(suggestion) }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
            }
        }
    }
}

extension AttributedString {
    /// The coach's reply with its inline Markdown (bold, italics), but without links: the coach reads calendar
    /// titles and Hevy notes, which other people can write, so a link in a reply can't be trusted.
    init(coachMarkdown text: String) {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let linked = string.runs.filter { $0.link != nil }.map(\.range)
        for range in linked { string[range].link = nil }
        self = string
    }
}
