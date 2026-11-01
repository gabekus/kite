import AppKit
import KiteCore
import SwiftUI

/// A space's icon wherever it shows: an emoji, an SF Symbol in the theme's colour (Arc tints its Icon-tab
/// icons with the space's colour), or nothing.
struct SpaceIconView: View {
    let icon: String
    let theme: Theme
    var size: CGFloat = 15
    var greyed = false

    var body: some View {
        if icon.hasPrefix(Space.symbolPrefix) {
            Image(systemName: String(icon.dropFirst(Space.symbolPrefix.count)))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(greyed ? AnyShapeStyle(.primary.opacity(0.45)) : AnyShapeStyle(Color(theme: theme.accent)))
        } else {
            Text(icon)
                .font(.system(size: size))
                .grayscale(greyed ? 1 : 0)
                .opacity(greyed ? 0.45 : 1)
        }
    }
}

extension Color {
    init(theme c: ThemeColor) { self.init(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b)) }
}

/// Arc's Change Space Icon popover: Emoji and Icon tabs, a search field and a grid of emoji by category,
/// or a grid of icons; once the space has an icon, a bin to take it off. Hangs under the header's icon
/// with an arrow (Arc 1.169 captures, 1 Nov 2026: 272 wide; 7 emoji to a row 33.5 apart, 8 icons to a
/// row 31 apart, the category bar along the bottom).
struct SpaceIconPicker: View {
    private typealias M = ArcMetrics.SpaceIconPicker
    let store: BrowserStore
    let spaceID: UUID
    @State private var tab = Tab.emoji
    @State private var query = ""
    @State private var category = 0

    enum Tab: String, CaseIterable { case emoji = "Emoji", icon = "Icon" }

    private var space: Space? { store.state.spaces.first { $0.id == spaceID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let icon = space?.icon, !icon.isEmpty {
                    Button { store.mutate { $0.setSpaceIcon(spaceID, to: "") } } label: {
                        Image(systemName: "trash").font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Remove Icon")
                }
            }
            .padding(.horizontal, M.inset)
            .padding(.top, M.inset)
            if tab == .emoji {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, M.inset)
                    .padding(.top, 10)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(M.emojiPitch), spacing: 0), count: M.emojiColumns), spacing: 0) {
                            ForEach(Array(emoji.enumerated()), id: \.offset) { _, e in
                                cell { Text(e).font(.system(size: 22)) } action: { pick(e) }
                                    .id(e)
                            }
                        }
                    }
                    .frame(height: M.emojiGridHeight)
                    .onChange(of: category) { _, c in proxy.scrollTo(EmojiCatalog.categories[c].emoji.first, anchor: .top) }
                }
                Divider().padding(.horizontal, M.inset)
                HStack(spacing: 0) {
                    ForEach(Array(EmojiCatalog.categories.enumerated()), id: \.offset) { i, c in
                        Button { query = ""; category = i } label: {
                            Image(systemName: c.symbol).font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.plain)
                        .opacity(category == i ? 1 : 0.6)
                        .help(c.name)
                    }
                }
                .padding(.horizontal, M.inset)
                .padding(.bottom, 6)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(M.iconPitch), spacing: 0), count: M.iconColumns), spacing: 0) {
                    ForEach(EmojiCatalog.symbols, id: \.self) { name in
                        cell { Image(systemName: name).font(.system(size: 16, weight: .semibold)) } action: {
                            pick(Space.symbolPrefix + name)
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, M.inset)
            }
        }
        .frame(width: M.width)
    }

    private var emoji: [String] {
        let all = EmojiCatalog.categories.flatMap(\.emoji)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { EmojiCatalog.name(of: $0).contains(q) }
    }

    private func pick(_ icon: String) {
        store.mutate { $0.setSpaceIcon(spaceID, to: icon) }
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content().frame(width: M.emojiPitch, height: M.rowPitch).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    static func present(store: BrowserStore, spaceID: UUID, from view: NSView, onClose: @escaping () -> Void = {}) {
        shown?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        closeHandler = onClose
        popover.delegate = delegate
        popover.contentViewController = NSHostingController(rootView: SpaceIconPicker(store: store, spaceID: spaceID))
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        shown = popover
    }

    @MainActor private static weak var shown: NSPopover?
    @MainActor private static var closeHandler: () -> Void = {}
    @MainActor private static let delegate = Delegate()

    private final class Delegate: NSObject, NSPopoverDelegate {
        func popoverDidClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                SpaceIconPicker.closeHandler()
                SpaceIconPicker.closeHandler = {}
            }
        }
    }
}

/// The emoji and icons the picker offers.
enum EmojiCatalog {
    struct Category { let name: String; let symbol: String; let emoji: [String] }

    static let categories: [Category] = [
        Category(name: "Smileys & People", symbol: "face.smiling", emoji: chars("😀😃😄😁😆😅🤣😂🙂🙃🫠😉😊😇🥰😍🤩😘😗☺️😚😙🥲😋😛😜🤪😝🤑🤗🤭🫢🫣🤫🤔🫡🤐🤨😐😑😶😏😒🙄😬😮‍💨🤥😌😔😪🤤😴😷🤒🤕🤢🤮🥵🥶🥴😵🤯🤠🥳🥸😎🤓🧐😕😟🙁😮😯😲😳🥺😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱😤😡😠🤬😈👿💀☠️💩🤡👹👺👻👽👾🤖👋🤚🖐️✋🖖👌🤌🤏✌️🤞🫰🤟🤘🤙👈👉👆👇☝️👍👎✊👊🤛🤜👏🙌🫶👐🤲🤝🙏✍️💪🧠👀👶🧒👦👧🧑👱👨🧔👩🧓👴👵🏃🚶💃🕺🧘")),
        Category(name: "Animals & Nature", symbol: "sun.max", emoji: chars("🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🐔🐧🐦🐤🦆🦅🦉🦇🐺🐗🐴🦄🐝🪱🐛🦋🐌🐞🐜🪰🐢🐍🦎🐙🦑🦐🦀🐡🐠🐟🐬🐳🐋🦈🐊🐅🐆🦓🦍🐘🦛🦏🐪🦒🦘🐃🐄🐎🐖🐏🐑🦙🐐🦌🐕🐈🐓🦃🦚🦜🦢🦩🕊️🐇🦝🦨🦡🦫🦦🦥🐁🐀🐿️🦔🌵🎄🌲🌳🌴🌱🌿☘️🍀🎍🪴🎋🍃🍂🍁🍄🌾💐🌷🌹🥀🌺🌸🌼🌻🌞🌝🌛🌜🌚🌕🌙🌎🪐💫⭐️🌟✨⚡️☄️💥🔥🌪️🌈☀️⛅️☁️🌧️⛈️❄️☃️⛄️🌬️💨💧💦🌊")),
        Category(name: "Food & Drink", symbol: "cup.and.saucer", emoji: chars("🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍈🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🥬🥒🌶️🫑🌽🥕🧄🧅🥔🍠🥐🥯🍞🥖🥨🧀🥚🍳🧈🥞🧇🥓🥩🍗🍖🌭🍔🍟🍕🫓🥪🥙🧆🌮🌯🥗🥘🍝🍜🍲🍛🍣🍱🥟🍤🍙🍚🍘🍥🥠🍢🍡🍧🍨🍦🥧🧁🍰🎂🍮🍭🍬🍫🍿🍩🍪🌰🥜🍯🥛🍼☕️🍵🧃🥤🧋🍶🍺🍻🥂🍷🥃🍸🍹🧉🍾🧊")),
        Category(name: "Activity", symbol: "rosette", emoji: chars("⚽️🏀🏈⚾️🥎🎾🏐🏉🥏🎱🪀🏓🏸🏒🏑🥍🏏🪃🥅⛳️🪁🏹🎣🤿🥊🥋🎽🛹🛼🛷⛸️🥌🎿⛷️🏂🪂🏋️🤸⛹️🤺🤾🏌️🏇🧗🚵🚴🏆🥇🥈🥉🏅🎖️🎗️🎫🎟️🎪🎭🎨🎬🎤🎧🎼🎹🥁🪘🎷🎺🪗🎸🪕🎻🎲♟️🎯🎳🎮🎰🧩")),
        Category(name: "Travel & Places", symbol: "car", emoji: chars("🚗🚕🚙🚌🚎🏎️🚓🚑🚒🚐🛻🚚🚛🚜🛵🏍️🛺🚲🛴🚨🚔🚍🚘🚖🚡🚠🚟🚃🚋🚞🚝🚄🚅🚈🚂🚆🚇🚊🚉✈️🛫🛬🛩️💺🛰️🚀🛸🚁🛶⛵️🚤🛥️🛳️⛴️🚢⚓️🚧⛽️🚏🗺️🗿🗽🗼🏰🏯🏟️🎡🎢🎠⛲️⛱️🏖️🏝️🏜️🌋⛰️🏔️🗻🏕️⛺️🏠🏡🏘️🏚️🏗️🏭🏢🏬🏣🏤🏥🏦🏨🏪🏫🏩💒🏛️⛪️🕌🕍🛕🕋⛩️🌅🌄🌠🎇🎆🌇🌆🏙️🌃🌌🌉🌁")),
        Category(name: "Objects", symbol: "lightbulb", emoji: chars("⌚️📱💻⌨️🖥️🖨️🖱️🕹️💽💾💿📀📷📸📹🎥📞☎️📺📻🎙️⏱️⏰🕰️⌛️⏳📡🔋🔌💡🔦🕯️🧯💸💵💴💶💷🪙💰💳💎⚖️🧰🔧🔨⚒️🛠️⛏️🔩⚙️🧱⛓️🧲🔫💣🧨🪓🔪🗡️⚔️🛡️🔮📿🧿💈⚗️🔭🔬💊💉🧬🦠🧫🧪🌡️🧹🧺🧻🚽🛁🧼🪥🧽🛎️🔑🗝️🚪🛋️🛏️🧸🖼️🛍️🛒🎁🎈🎏🎀🎊🎉✉️📩📨📧💌📦🏷️📪📫📬📭📮📜📃📄📑🧾📊📈📉🗒️🗓️📆📅🗑️📇🗃️🗳️🗄️📋📁📂🗂️🗞️📰📓📔📒📕📗📘📙📚📖🔖🧷🔗📎🖇️📐📏🧮📌📍✂️🖊️🖋️✒️🖌️🖍️📝✏️🔍🔎🔏🔐🔒🔓")),
        Category(name: "Symbols", symbol: "heart", emoji: chars("❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝💟☮️✝️☪️🕉️☸️✡️🔯🕎☯️☦️🛐⛎♈️♉️♊️♋️♌️♍️♎️♏️♐️♑️♒️♓️🆔⚛️🉑☢️☣️📴📳🈶🈚️🈸🈺🈷️✴️🆚💮🉐㊙️㊗️🈴🈵🈹🈲🅰️🅱️🆎🆑🅾️🆘❌⭕️🛑⛔️📛🚫💯💢♨️🚷🚯🚳🚱🔞📵🚭❗️❕❓❔‼️⁉️🔅🔆〽️⚠️🚸🔱⚜️🔰♻️✅🈯️💹❇️✳️❎🌐💠Ⓜ️🌀💤🏧🚾♿️🅿️🛗🈳🈂️🛂🛃🛄🛅🚹🚺🚼⚧🚻🚮🎦📶🈁🔣ℹ️🔤🔡🔠🆖🆗🆙🆒🆕🆓0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟🔢#️⃣*️⃣⏏️▶️⏸️⏯️⏹️⏺️⏭️⏮️⏩️⏪️⏫️⏬️◀️🔼🔽➡️⬅️⬆️⬇️↗️↘️↙️↖️↕️↔️↪️↩️⤴️⤵️🔀🔁🔂🔄🔃🎵🎶➕➖➗✖️🟰♾️💲💱™️©️®️〰️➰➿🔚🔙🔛🔝🔜✔️☑️🔘🔴🟠🟡🟢🔵🟣⚫️⚪️🟤🔺🔻🔸🔹🔶🔷🔳🔲▪️▫️◾️◽️◼️◻️🟥🟧🟨🟩🟦🟪⬛️⬜️🟫🔈🔇🔉🔊🔔🔕📣📢💬💭🗯️♠️♣️♥️♦️🃏🎴🀄️")),
        Category(name: "Flags", symbol: "flag", emoji: chars("🏳️🏴🏁🚩🏳️‍🌈🏳️‍⚧️🏴‍☠️🇺🇸🇬🇧🇨🇦🇫🇷🇩🇪🇮🇹🇪🇸🇵🇹🇳🇱🇧🇪🇨🇭🇦🇹🇸🇪🇳🇴🇩🇰🇫🇮🇮🇪🇵🇱🇨🇿🇬🇷🇹🇷🇺🇦🇮🇱🇯🇵🇰🇷🇨🇳🇹🇼🇭🇰🇮🇳🇵🇰🇧🇩🇹🇭🇻🇳🇮🇩🇵🇭🇲🇾🇸🇬🇦🇺🇳🇿🇧🇷🇦🇷🇨🇱🇨🇴🇲🇽🇵🇪🇿🇦🇳🇬🇪🇬🇰🇪🇲🇦🇸🇦🇦🇪")),
    ]

    /// Kite's own set for the Icon tab, eight to a row.
    static let symbols: [String] = [
        "star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill",
        "lightbulb.fill", "square.on.circle.fill", "square.grid.2x2.fill", "circle.grid.3x3.fill", "square.3.layers.3d", "cylinder.split.1x2.fill", "tray.fill", "square.on.square.fill",
        "folder.fill", "archivebox.fill", "calendar", "envelope.fill", "checkmark.square.fill", "doc.fill", "book.fill", "ellipsis.bubble.fill",
        "person.2.fill", "terminal.fill", "wrench.and.screwdriver.fill", "square.fill", "drop.fill", "circle.fill", "moon.fill", "sun.max.fill",
        "globe.americas.fill", "leaf.fill", "cloud.fill", "pawprint.fill", "basket.fill", "gift.fill", "bed.double.fill", "fork.knife",
        "dumbbell.fill", "airplane", "music.note", "paintpalette.fill", "video.fill", "bandage.fill", "chevron.left.forwardslash.chevron.right", "baseball.fill",
        "cloud", "map.fill", "flame.fill", "takeoutbag.and.cup.and.straw.fill", "theatermasks.fill", "scroll.fill", "hand.thumbsup.fill", "tram.fill",
    ]

    private static func chars(_ s: String) -> [String] { s.map(String.init) }

    private static var names: [String: String] = [:]
    /// The emoji's Unicode name, lowercased, for search.
    static func name(of emoji: String) -> String {
        if let cached = names[emoji] { return cached }
        let name = (emoji.applyingTransform(.toUnicodeName, reverse: false) ?? "").lowercased()
        names[emoji] = name
        return name
    }
}
