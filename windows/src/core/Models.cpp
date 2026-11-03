#include "core/Models.h"

#include <algorithm>
#include <charconv>
#include <chrono>

#include "core/Url.h"
#include "core/Uuid.h"

namespace kite {

Timestamp Now() {
    using namespace std::chrono;
    return FromUnixTime(duration<double>(system_clock::now().time_since_epoch()).count());
}

std::string Tab::DisplayTitle() const {
    if (customTitle && !customTitle->empty()) return *customTitle;
    if (!title.empty()) return title;
    if (url) {
        if (auto host = url::Host(*url); host && !host->empty()) return *host;
        return *url;
    }
    return "New Tab";
}

bool Folder::operator==(const Folder& o) const {
    return id == o.id && name == o.name && isExpanded == o.isExpanded && items == o.items && live == o.live &&
           ephemeral == o.ephemeral && extra == o.extra;
}

const std::string& PinnedItem::Id() const {
    return std::visit([](const auto& v) -> const std::string& { return v.id; }, value);
}

bool PinnedItem::operator==(const PinnedItem& o) const { return value == o.value; }

std::vector<Tab> TabsIn(const std::vector<PinnedItem>& items) {
    std::vector<Tab> out;
    for (const auto& item : items) {
        if (auto* tab = std::get_if<Tab>(&item.value)) {
            out.push_back(*tab);
        } else {
            auto nested = TabsIn(std::get<Folder>(item.value).items);
            out.insert(out.end(), nested.begin(), nested.end());
        }
    }
    return out;
}

Tab* FindTab(std::vector<PinnedItem>& items, const std::string& id) {
    for (auto& item : items) {
        if (auto* tab = std::get_if<Tab>(&item.value)) {
            if (tab->id == id) return tab;
        } else if (Tab* found = FindTab(std::get<Folder>(item.value).items, id)) {
            return found;
        }
    }
    return nullptr;
}

ThemeColor ThemeColor::FromHex(uint32_t hex) {
    return {static_cast<float>((hex >> 16) & 0xFF) / 255.f, static_cast<float>((hex >> 8) & 0xFF) / 255.f,
            static_cast<float>(hex & 0xFF) / 255.f};
}

Theme Theme::Make(std::vector<ThemeColor> colors, float grain, float tint) {
    if (colors.size() > kMaxColors) colors.resize(kMaxColors);
    return Theme{std::move(colors), std::clamp(grain, 0.f, 1.f), std::clamp(tint, 0.f, 1.f)};
}

const std::vector<Theme>& Theme::Presets() {
    // Theme.presets in Theme.swift, in the same order.
    static const std::vector<Theme> presets = {
        Make({{0.1f, 0.1f, 0.1f}}, 0, kDefaultTint * 0.8f),
        Make({ThemeColor::FromHex(0xFF9A6C), ThemeColor::FromHex(0xF0629B), ThemeColor::FromHex(0x8A5CF5)}),
        Make({ThemeColor::FromHex(0x5FD3E6), ThemeColor::FromHex(0x2BA39A), ThemeColor::FromHex(0x2F6FE0)}),
        Make({ThemeColor::FromHex(0xD4F7E2), ThemeColor::FromHex(0xA6E3C8)}, 0.25f),
        Make({ThemeColor::FromHex(0x3B4049), ThemeColor::FromHex(0x1F2329)}, 0.45f),
        Make({ThemeColor::FromHex(0xFFE38A), ThemeColor::FromHex(0xFFB45C)}, 0.3f),
        Make({ThemeColor::FromHex(0x8E2BB0), ThemeColor::FromHex(0xD8256A), ThemeColor::FromHex(0x3A4BC0),
              ThemeColor::FromHex(0x10B0C8)}),
    };
    return presets;
}

std::vector<Tab> Space::AllTabs() const {
    auto all = Pinned();
    all.insert(all.end(), tabs.begin(), tabs.end());
    return all;
}

// MARK: BrowserState

BrowserState BrowserState::MakeDefault(std::optional<std::string> seedURL) {
    Space personal{NewUuid(), "Personal", "\xF0\x9F\x8F\xA0", Theme::Presets()[0], {}, {}, std::nullopt, {}};  // 🏠
    if (seedURL) {
        Tab tab;
        tab.id = NewUuid();
        tab.url = *seedURL;
        tab.lastActiveAt = Now();
        personal.selectedTabID = tab.id;
        personal.tabs.push_back(std::move(tab));
    }
    Space work{NewUuid(), "Work", "\xF0\x9F\x92\xBC", Theme::Presets()[1], {}, {}, std::nullopt, {}};  // 💼
    BrowserState state;
    state.selectedSpaceID = personal.id;
    state.spaces = {std::move(personal), std::move(work)};
    return state;
}

size_t BrowserState::SelectedSpaceIndex() const { return SpaceIndex(selectedSpaceID).value_or(0); }

const Tab* BrowserState::SelectedTab() const {
    const Space& space = SelectedSpace();
    if (!space.selectedTabID) return nullptr;
    auto location = Location(*space.selectedTabID);
    if (!location || (location->space && *location->space != SelectedSpaceIndex())) return nullptr;
    return FindTabByID(*space.selectedTabID);
}

std::vector<Tab> BrowserState::SidebarTabs(size_t space) const {
    auto out = favorites;
    auto rest = spaces[space].AllTabs();
    out.insert(out.end(), rest.begin(), rest.end());
    return out;
}

std::optional<size_t> BrowserState::SpaceIndex(const std::string& id) const {
    for (size_t i = 0; i < spaces.size(); ++i) {
        if (spaces[i].id == id) return i;
    }
    return std::nullopt;
}

std::optional<TabLocation> BrowserState::Location(const std::string& id) const {
    for (size_t i = 0; i < favorites.size(); ++i) {
        if (favorites[i].id == id) return TabLocation{std::nullopt, TabSection::Favorite, i};
    }
    for (size_t s = 0; s < spaces.size(); ++s) {
        auto pinned = spaces[s].Pinned();
        for (size_t i = 0; i < pinned.size(); ++i) {
            if (pinned[i].id == id) return TabLocation{s, TabSection::Pinned, i};
        }
        for (size_t i = 0; i < spaces[s].tabs.size(); ++i) {
            if (spaces[s].tabs[i].id == id) return TabLocation{s, TabSection::Unpinned, i};
        }
    }
    return std::nullopt;
}

const Tab* BrowserState::FindTabByID(const std::string& id) const {
    auto location = Location(id);
    if (!location) return nullptr;
    return const_cast<BrowserState*>(this)->MutableTab(*location);
}

Tab* BrowserState::MutableTab(const TabLocation& location) {
    switch (location.section) {
    case TabSection::Favorite: return &favorites[location.index];
    case TabSection::Unpinned: return &spaces[*location.space].tabs[location.index];
    case TabSection::Pinned: {
        auto pinned = spaces[*location.space].Pinned();
        return FindTab(spaces[*location.space].pinnedItems, pinned[location.index].id);
    }
    }
    return nullptr;
}

std::string BrowserState::OpenTab(std::optional<std::string> tabURL, std::optional<std::string> spaceID, bool select,
                                  Timestamp now, std::string id) {
    size_t s = spaceID ? SpaceIndex(*spaceID).value_or(SelectedSpaceIndex()) : SelectedSpaceIndex();
    if (id.empty()) id = NewUuid();
    Tab tab;
    tab.id = id;
    tab.url = std::move(tabURL);
    tab.lastActiveAt = now;
    spaces[s].tabs.insert(spaces[s].tabs.begin(), std::move(tab));
    if (select) {
        spaces[s].selectedTabID = id;
        selectedSpaceID = spaces[s].id;
    }
    return id;
}

void BrowserState::Select(const std::string& tabID, Timestamp now) {
    auto location = Location(tabID);
    if (!location) return;
    size_t s = location->space.value_or(SelectedSpaceIndex());
    spaces[s].selectedTabID = tabID;
    selectedSpaceID = spaces[s].id;
    MutableTab(*location)->lastActiveAt = now;
}

void BrowserState::SelectSpace(const std::string& id) {
    if (SpaceIndex(id)) selectedSpaceID = id;
}

void BrowserState::SelectAdjacentSpace(int offset) {
    const long count = static_cast<long>(spaces.size());
    long next = ((static_cast<long>(SelectedSpaceIndex()) + offset) % count + count) % count;
    selectedSpaceID = spaces[static_cast<size_t>(next)].id;
}

std::string BrowserState::AddSpace(std::string name, std::string icon, Theme theme) {
    Space space{NewUuid(), std::move(name), std::move(icon), std::move(theme), {}, {}, std::nullopt, {}};
    selectedSpaceID = space.id;
    spaces.push_back(std::move(space));
    return selectedSpaceID;
}

// MARK: JSON

namespace {

using json::Array;
using json::Object;
using json::Value;

// A Float as Swift writes it ("0.55", not 0.550000011920929).
Value FloatValue(float f) {
    char buffer[32];
    auto [end, ec] = std::to_chars(buffer, buffer + sizeof(buffer), f);
    double d = f;
    if (ec == std::errc()) std::from_chars(buffer, end, d);
    return Value(d);
}

const std::string* String(const Value& object, std::string_view key) {
    const Value* v = object.Find(key);
    return v ? v->AsString() : nullptr;
}

std::optional<std::string> OptionalString(const Value& object, std::string_view key) {
    if (auto* s = String(object, key)) return *s;
    return std::nullopt;
}

void Put(Object& o, const char* key, Value v) { o.insert_or_assign(key, std::move(v)); }

void PutIf(Object& o, const char* key, const std::optional<std::string>& v) {
    if (v) Put(o, key, *v);
}

// Members of `object` not in `known`, kept so they're written back unchanged.
Object Extra(const Value& object, std::initializer_list<std::string_view> known) {
    Object extra;
    for (const auto& [key, value] : *object.AsObject()) {
        if (std::find(known.begin(), known.end(), key) == known.end()) extra.emplace(key, value);
    }
    return extra;
}

template <typename T, typename Decode>
std::optional<std::vector<T>> DecodeArray(const Value* value, Decode decode) {
    if (!value || !value->AsArray()) return std::nullopt;
    std::vector<T> out;
    for (const auto& element : *value->AsArray()) {
        auto decoded = decode(element);
        if (!decoded) return std::nullopt;
        out.push_back(std::move(*decoded));
    }
    return out;
}

template <typename T>
Value EncodeArray(const std::vector<T>& items) {
    Array array;
    for (const auto& item : items) array.push_back(Encode(item));
    return Value(std::move(array));
}

std::optional<Folder> DecodeFolder(const Value& v) {
    auto* id = String(v, "id");
    auto* name = String(v, "name");
    const Value* expanded = v.Find("isExpanded");
    if (!id || !name || !expanded || !expanded->AsBool()) return std::nullopt;
    auto items = DecodeArray<PinnedItem>(v.Find("items"), DecodePinnedItem);
    if (!items) return std::nullopt;
    Folder folder;
    folder.id = *id;
    folder.name = *name;
    folder.isExpanded = *expanded->AsBool();
    folder.items = std::move(*items);
    if (const Value* live = v.Find("live"); live && !live->IsNull()) folder.live = *live;
    if (const Value* e = v.Find("ephemeral"); e && e->AsBool()) folder.ephemeral = *e->AsBool();
    folder.extra = Extra(v, {"id", "name", "isExpanded", "items", "live", "ephemeral"});
    return folder;
}

}  // namespace

Value Encode(const Tab& tab) {
    Object o = tab.extra;
    Put(o, "id", tab.id);
    PutIf(o, "url", tab.url);
    Put(o, "title", tab.title);
    PutIf(o, "faviconURL", tab.faviconURL);
    Put(o, "lastActiveAt", tab.lastActiveAt);
    PutIf(o, "pinnedURL", tab.pinnedURL);
    PutIf(o, "customTitle", tab.customTitle);
    if (tab.splitPane) Put(o, "splitPane", *tab.splitPane);
    return Value(std::move(o));
}

std::optional<Tab> DecodeTab(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    auto* id = String(v, "id");
    auto* title = String(v, "title");
    const Value* lastActive = v.Find("lastActiveAt");
    if (!id || !title || !lastActive || !lastActive->AsNumber()) return std::nullopt;
    Tab tab;
    tab.id = *id;
    tab.url = OptionalString(v, "url");
    tab.title = *title;
    tab.faviconURL = OptionalString(v, "faviconURL");
    tab.lastActiveAt = *lastActive->AsNumber();
    tab.pinnedURL = OptionalString(v, "pinnedURL");
    tab.customTitle = OptionalString(v, "customTitle");
    if (const Value* split = v.Find("splitPane"); split && split->AsBool()) tab.splitPane = *split->AsBool();
    tab.extra = Extra(v, {"id", "url", "title", "faviconURL", "lastActiveAt", "pinnedURL", "customTitle", "splitPane"});
    return tab;
}

Value Encode(const Folder& folder) {
    Object o = folder.extra;
    Put(o, "id", folder.id);
    Put(o, "name", folder.name);
    Put(o, "isExpanded", folder.isExpanded);
    Put(o, "items", EncodeArray(folder.items));
    if (folder.live) Put(o, "live", *folder.live);
    if (folder.ephemeral) Put(o, "ephemeral", *folder.ephemeral);
    return Value(std::move(o));
}

// Swift's synthesized enum coding: {"tab": {"_0": {...}}} or {"folder": {"_0": {...}}}.
Value Encode(const PinnedItem& item) {
    const char* key = std::holds_alternative<Tab>(item.value) ? "tab" : "folder";
    Value payload = std::visit([](const auto& v) { return Encode(v); }, item.value);
    return Value(Object{{key, Value(Object{{"_0", std::move(payload)}})}});
}

std::optional<PinnedItem> DecodePinnedItem(const Value& v) {
    const Object* o = v.AsObject();
    if (!o || o->size() != 1) return std::nullopt;
    const auto& [key, wrapper] = *o->begin();
    const Value* payload = wrapper.Find("_0");
    if (!payload) return std::nullopt;
    if (key == "tab") {
        if (auto tab = DecodeTab(*payload)) return PinnedItem{std::move(*tab)};
    } else if (key == "folder") {
        if (auto folder = DecodeFolder(*payload)) return PinnedItem{std::move(*folder)};
    }
    return std::nullopt;
}

Value Encode(const Theme& theme) {
    Array colors;
    for (const auto& c : theme.colors) {
        colors.push_back(Value(Object{{"r", FloatValue(c.r)}, {"g", FloatValue(c.g)}, {"b", FloatValue(c.b)}}));
    }
    return Value(Object{{"colors", Value(std::move(colors))}, {"grain", FloatValue(theme.grain)}, {"tint", FloatValue(theme.tint)}});
}

std::optional<Theme> DecodeTheme(const Value& v) {
    const Value* colorsValue = v.Find("colors");
    const Value* grain = v.Find("grain");
    if (!colorsValue || !colorsValue->AsArray() || !grain || !grain->AsNumber()) return std::nullopt;
    std::vector<ThemeColor> colors;
    for (const auto& c : *colorsValue->AsArray()) {
        const Value *r = c.Find("r"), *g = c.Find("g"), *b = c.Find("b");
        if (!r || !g || !b || !r->AsNumber() || !g->AsNumber() || !b->AsNumber()) return std::nullopt;
        colors.push_back({static_cast<float>(*r->AsNumber()), static_cast<float>(*g->AsNumber()), static_cast<float>(*b->AsNumber())});
    }
    if (colors.empty()) return std::nullopt;  // the Mac requires at least one color
    float tint = Theme::kDefaultTint;  // sessions from before `tint`
    if (const Value* t = v.Find("tint"); t && t->AsNumber()) tint = static_cast<float>(*t->AsNumber());
    return Theme::Make(std::move(colors), static_cast<float>(*grain->AsNumber()), tint);
}

Value Encode(const Space& space) {
    Object o = space.extra;
    Put(o, "id", space.id);
    Put(o, "name", space.name);
    Put(o, "icon", space.icon);
    Put(o, "theme", Encode(space.theme));
    Put(o, "pinnedItems", EncodeArray(space.pinnedItems));
    Put(o, "tabs", EncodeArray(space.tabs));
    PutIf(o, "selectedTabID", space.selectedTabID);
    return Value(std::move(o));
}

std::optional<Space> DecodeSpace(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    auto* id = String(v, "id");
    auto* name = String(v, "name");
    auto* icon = String(v, "icon");
    const Value* themeValue = v.Find("theme");
    auto theme = themeValue ? DecodeTheme(*themeValue) : std::nullopt;
    auto tabs = DecodeArray<Tab>(v.Find("tabs"), DecodeTab);
    if (!id || !name || !icon || !theme || !tabs) return std::nullopt;
    Space space;
    space.id = *id;
    space.name = *name;
    space.icon = *icon;
    space.theme = std::move(*theme);
    space.tabs = std::move(*tabs);
    if (const Value* items = v.Find("pinnedItems")) {
        auto decoded = DecodeArray<PinnedItem>(items, DecodePinnedItem);
        if (!decoded) return std::nullopt;
        space.pinnedItems = std::move(*decoded);
    } else if (const Value* legacy = v.Find("pinned")) {
        // Sessions from before folders stored a flat `pinned` array of tabs.
        auto decoded = DecodeArray<Tab>(legacy, DecodeTab);
        if (!decoded) return std::nullopt;
        for (auto& tab : *decoded) space.pinnedItems.push_back(PinnedItem{std::move(tab)});
    }
    space.selectedTabID = OptionalString(v, "selectedTabID");
    space.extra = Extra(v, {"id", "name", "icon", "theme", "pinnedItems", "pinned", "tabs", "selectedTabID"});
    return space;
}

Value Encode(const BrowserState& state) {
    Object o = state.extra;
    Put(o, "spaces", EncodeArray(state.spaces));
    Put(o, "selectedSpaceID", state.selectedSpaceID);
    Put(o, "favorites", EncodeArray(state.favorites));
    Put(o, "searchEngine", state.searchEngine);
    return Value(std::move(o));
}

std::optional<BrowserState> DecodeBrowserState(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    auto spaces = DecodeArray<Space>(v.Find("spaces"), DecodeSpace);
    if (!spaces || spaces->empty()) return std::nullopt;
    BrowserState state;
    state.spaces = std::move(*spaces);
    auto selected = OptionalString(v, "selectedSpaceID");
    state.selectedSpaceID = selected && state.SpaceIndex(*selected) ? *selected : state.spaces[0].id;
    if (const Value* favorites = v.Find("favorites")) {
        auto decoded = DecodeArray<Tab>(favorites, DecodeTab);
        if (!decoded) return std::nullopt;
        state.favorites = std::move(*decoded);
    }
    if (auto engine = OptionalString(v, "searchEngine")) state.searchEngine = *engine;
    state.extra = Extra(v, {"spaces", "selectedSpaceID", "favorites", "searchEngine"});
    return state;
}

}  // namespace kite
