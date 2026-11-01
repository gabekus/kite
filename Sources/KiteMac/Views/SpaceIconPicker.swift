import AppKit
import SwiftUI

/// Arc's space icon picker (CustomInfoPicker: `EmojiAndIconPicker`, `EmojiGridCollection`), shown in
/// a popover on the space's header instead of a dialog. Arc's grid is the full emoji set with skin
/// tones and SF Symbol icons; Kite shows a grid of common emoji and hands the rest to the system's
/// Emoji & Symbols palette, typed into the field at the top. Layout not yet measured against Arc.
struct SpaceIconPicker: View {
    let current: String
    let pick: (String) -> Void
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private static let emoji = Array(
        "😀😎🤓🥳😴🤖👾👻🔥⭐️🌙☀️🌈⚡️❄️🌊🌱🌸🍀🍁🍎🍕☕️🍷🎧🎮🎨🎬📚✏️📝📌📎💼💻🖥️📱🔧🧪🔬💡🔒🔑💰📈🛒🎁✈️🚀🏠🏢🏖️⛰️⚽️🏀🎾🏋️🧘🎵❤️💜💙💚💛🧡🖤🐶🐱🦊🐼🐸🦄🐙🦋🌍🗂️📦🧠💬📮🗓️✅"
    ).map(String.init)

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Type an emoji", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onChange(of: typed) { _, text in
                        if let first = text.first, first.unicodeScalars.contains(where: \.properties.isEmojiPresentation)
                            || first.unicodeScalars.count > 1 {
                            pick(String(first))
                        }
                    }
                Button {
                    fieldFocused = true
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Image(systemName: "face.smiling")
                }
                .buttonStyle(.borderless)
                .help("Emoji & Symbols")
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Self.emoji, id: \.self) { emoji in
                    Button { pick(emoji) } label: {
                        Text(emoji)
                            .font(.system(size: 18))
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(emoji == current ? Color.accentColor.opacity(0.25) : .clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(emoji)
                }
            }
        }
        .padding(12)
        .frame(width: 9 * 28 + 8 * 4 + 24)
    }
}
