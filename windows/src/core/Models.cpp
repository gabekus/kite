// Port of KiteCore Models.swift and BrowserState.swift; see Models.h.

#include "core/Models.h"

#include <algorithm>
#include <cfloat>
#include <charconv>
#include <cmath>
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

namespace {

void CollectTabs(const std::vector<PinnedItem>& items, std::vector<const Tab*>& out) {
    for (const auto& item : items) {
        if (auto* tab = std::get_if<Tab>(&item.value)) out.push_back(tab);
        else CollectTabs(std::get<Folder>(item.value).items, out);
    }
}

// Shared by the const and non-const overloads, so neither needs a const_cast.
template <typename Items>
auto* FindTabIn(Items& items, const std::string& id) {
    using TabPtr = decltype(std::get_if<Tab>(&items.front().value));
    for (auto& item : items) {
        if (auto* tab = std::get_if<Tab>(&item.value)) {
            if (tab->id == id) return tab;
        } else if (TabPtr found = FindTabIn(std::get<Folder>(item.value).items, id)) {
            return found;
        }
    }
    return TabPtr{nullptr};
}

// The tab at sidebar position `n` (depth first) of the tree; counts `n` down as it goes.
template <typename Items>
auto* NthTabIn(Items& items, size_t& n) {
    using TabPtr = decltype(std::get_if<Tab>(&items.front().value));
    for (auto& item : items) {
        if (auto* tab = std::get_if<Tab>(&item.value)) {
            if (n == 0) return tab;
            --n;
        } else if (TabPtr found = NthTabIn(std::get<Folder>(item.value).items, n)) {
            return found;
        }
    }
    return TabPtr{nullptr};
}

// The sidebar index of the tab `id` in the tree, counting tabs before it; nullopt if absent.
bool IndexOfTab(const std::vector<PinnedItem>& items, const std::string& id, size_t& index) {
    for (const auto& item : items) {
        if (auto* tab = std::get_if<Tab>(&item.value)) {
            if (tab->id == id) return true;
            ++index;
        } else if (IndexOfTab(std::get<Folder>(item.value).items, id, index)) {
            return true;
        }
    }
    return false;
}

}  // namespace

std::vector<const Tab*> TabsIn(const std::vector<PinnedItem>& items) {
    std::vector<const Tab*> out;
    CollectTabs(items, out);
    return out;
}

const Tab* FindTab(const std::vector<PinnedItem>& items, const std::string& id) { return FindTabIn(items, id); }
Tab* FindTab(std::vector<PinnedItem>& items, const std::string& id) { return FindTabIn(items, id); }

ThemeColor ThemeColor::FromHex(uint32_t hex) {
    return {static_cast<float>((hex >> 16) & 0xFF) / 255.f, static_cast<float>((hex >> 8) & 0xFF) / 255.f,
            static_cast<float>(hex & 0xFF) / 255.f};
}

Theme Theme::Make(std::vector<ThemeColor> colors, float grain, float tint) {
    if (colors.empty()) colors = Theme{}.colors;
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

std::vector<const Tab*> Space::AllTabs() const {
    auto all = Pinned();
    all.reserve(all.size() + tabs.size());
    for (const auto& tab : tabs) all.push_back(&tab);
    return all;
}

// MARK: BrowserState

BrowserState BrowserState::MakeDefault(std::optional<std::string> seedURL) {
    Space personal{NewUuid(), "Personal", "\xF0\x9F\x8F\xA0", Theme::Presets()[0], {}, {}, std::nullopt, {}, {}};  // 🏠
    if (seedURL) {
        Tab tab;
        tab.id = NewUuid();
        tab.url = *seedURL;
        tab.lastActiveAt = Now();
        personal.selectedTabID = tab.id;
        personal.tabs.push_back(std::move(tab));
    }
    Space work{NewUuid(), "Work", "\xF0\x9F\x92\xBC", Theme::Presets()[1], {}, {}, std::nullopt, {}, {}};  // 💼
    BrowserState state;
    state.selectedSpaceID = personal.id;
    state.spaces = {std::move(personal), std::move(work)};
    return state;
}

std::string BrowserState::ProfileDirectory(size_t space) const {
    // Profiles.swift: profile(spaces[i].profile).directory, where an unknown profile is the default.
    auto it = spaces[space].extra.find("profile");
    if (it == spaces[space].extra.end() || !it->second.AsString()) return kDefaultProfile;
    const std::string& wanted = *it->second.AsString();
    if (auto profiles = extra.find("profiles"); profiles != extra.end() && profiles->second.AsArray()) {
        for (const auto& profile : *profiles->second.AsArray()) {
            const json::Value* directory = profile.Find("directory");
            if (directory && directory->AsString() && *directory->AsString() == wanted) return wanted;
        }
    }
    return kDefaultProfile;
}

const std::vector<Tab>& BrowserState::Favorites() const {
    static const std::vector<Tab> kNone;
    auto it = favoritesByProfile.find(SelectedProfileDirectory());
    return it == favoritesByProfile.end() ? kNone : it->second;
}

void BrowserState::SetFavorites(std::vector<Tab> tabs) {
    if (tabs.empty()) favoritesByProfile.erase(SelectedProfileDirectory());
    else favoritesByProfile[SelectedProfileDirectory()] = std::move(tabs);
}

size_t BrowserState::SelectedSpaceIndex() const { return SpaceIndex(selectedSpaceID).value_or(0); }

const Tab* BrowserState::SelectedTab() const {
    const Space& space = SelectedSpace();
    if (!space.selectedTabID) return nullptr;
    auto location = Location(*space.selectedTabID);
    if (!location || (location->space && *location->space != SelectedSpaceIndex())) return nullptr;
    return TabAt(*location);
}

std::vector<const Tab*> BrowserState::SidebarTabs(size_t space) const {
    const auto& favorites = Favorites();
    std::vector<const Tab*> out;
    out.reserve(favorites.size() + spaces[space].tabs.size());
    for (const auto& tab : favorites) out.push_back(&tab);
    CollectTabs(spaces[space].pinnedItems, out);
    for (const auto& tab : spaces[space].tabs) out.push_back(&tab);
    return out;
}

std::optional<size_t> BrowserState::SpaceIndex(const std::string& id) const {
    for (size_t i = 0; i < spaces.size(); ++i) {
        if (spaces[i].id == id) return i;
    }
    return std::nullopt;
}

std::optional<TabLocation> BrowserState::Location(const std::string& id) const {
    const auto& favorites = Favorites();
    for (size_t i = 0; i < favorites.size(); ++i) {
        if (favorites[i].id == id) return TabLocation{std::nullopt, TabSection::Favorite, i};
    }
    for (size_t s = 0; s < spaces.size(); ++s) {
        size_t index = 0;
        if (IndexOfTab(spaces[s].pinnedItems, id, index)) return TabLocation{s, TabSection::Pinned, index};
        for (size_t i = 0; i < spaces[s].tabs.size(); ++i) {
            if (spaces[s].tabs[i].id == id) return TabLocation{s, TabSection::Unpinned, i};
        }
    }
    return std::nullopt;
}

const Tab* BrowserState::FindTabByID(const std::string& id) const {
    auto location = Location(id);
    return location ? TabAt(*location) : nullptr;
}

namespace {

// Shared by both TabAt overloads; `State` is BrowserState or const BrowserState.
template <typename State>
auto* TabAtIn(State& state, const TabLocation& location) {
    using TabPtr = decltype(&state.spaces[0].tabs[0]);
    switch (location.section) {
    case TabSection::Favorite: {
        auto it = state.favoritesByProfile.find(state.SelectedProfileDirectory());
        if (it == state.favoritesByProfile.end() || location.index >= it->second.size()) return TabPtr{nullptr};
        return &it->second[location.index];
    }
    case TabSection::Unpinned: {
        if (!location.space || *location.space >= state.spaces.size()) return TabPtr{nullptr};
        auto& tabs = state.spaces[*location.space].tabs;
        return location.index < tabs.size() ? &tabs[location.index] : TabPtr{nullptr};
    }
    case TabSection::Pinned: {
        if (!location.space || *location.space >= state.spaces.size()) return TabPtr{nullptr};
        size_t n = location.index;
        return static_cast<TabPtr>(NthTabIn(state.spaces[*location.space].pinnedItems, n));
    }
    }
    return TabPtr{nullptr};
}

}  // namespace

const Tab* BrowserState::TabAt(const TabLocation& location) const { return TabAtIn(*this, location); }
Tab* BrowserState::TabAt(const TabLocation& location) { return TabAtIn(*this, location); }

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
    if (Tab* tab = TabAt(*location)) tab->lastActiveAt = now;
}

namespace {
bool UpdateFolder(std::vector<PinnedItem>& items, const std::string& id, bool expanded) {
    for (PinnedItem& item : items) {
        Folder* folder = std::get_if<Folder>(&item.value);
        if (!folder) continue;
        if (folder->id == id) {
            folder->isExpanded = expanded;
            return true;
        }
        if (UpdateFolder(folder->items, id, expanded)) return true;
    }
    return false;
}
}  // namespace

void BrowserState::SetFolderExpanded(const std::string& folderID, bool expanded) {
    for (Space& space : spaces) {
        if (UpdateFolder(space.pinnedItems, folderID, expanded)) return;
    }
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
    Space space{NewUuid(), std::move(name), std::move(icon), std::move(theme), {}, {}, std::nullopt, {}, {}};
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

// A UUID member, uppercased. Missing → nullopt; present but not a UUID → `invalid` is set,
// since Swift's decoder fails the whole session on a malformed UUID.
std::optional<std::string> UuidMember(const Value& object, std::string_view key, bool& invalid) {
    const Value* v = object.Find(key);
    if (!v || v->IsNull()) return std::nullopt;
    auto* text = v->AsString();
    auto normalized = text ? NormalizeUuid(*text) : std::nullopt;
    if (!normalized) invalid = true;
    return normalized;
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
    bool invalid = false;
    auto id = UuidMember(v, "id", invalid);
    auto* name = String(v, "name");
    const Value* expanded = v.Find("isExpanded");
    if (!id || invalid || !name || !expanded || !expanded->AsBool()) return std::nullopt;
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
    bool invalid = false;
    auto id = UuidMember(v, "id", invalid);
    auto* title = String(v, "title");
    const Value* lastActive = v.Find("lastActiveAt");
    if (!id || invalid || !title || !lastActive || !lastActive->AsNumber()) return std::nullopt;
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
    // Swift's synthesized enum decoding: exactly one of the case keys, others ignored.
    const Object* o = v.AsObject();
    if (!o) return std::nullopt;
    auto tab = o->find("tab");
    auto folder = o->find("folder");
    if ((tab != o->end()) == (folder != o->end())) return std::nullopt;
    const Value* payload = (tab != o->end() ? tab : folder)->second.Find("_0");
    if (!payload) return std::nullopt;
    if (tab != o->end()) {
        if (auto decoded = DecodeTab(*payload)) return PinnedItem{std::move(*decoded)};
    } else if (auto decoded = DecodeFolder(*payload)) {
        return PinnedItem{std::move(*decoded)};
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

// A Swift Float member: JSONDecoder refuses a number a Float can't hold.
std::optional<float> FloatMember(const Value* v) {
    if (!v || !v->AsNumber() || std::fabs(*v->AsNumber()) > static_cast<double>(FLT_MAX)) return std::nullopt;
    return static_cast<float>(*v->AsNumber());
}

std::optional<Theme> DecodeTheme(const Value& v) {
    const Value* colorsValue = v.Find("colors");
    auto grain = FloatMember(v.Find("grain"));
    if (!colorsValue || !colorsValue->AsArray() || !grain) return std::nullopt;
    std::vector<ThemeColor> colors;
    for (const auto& c : *colorsValue->AsArray()) {
        auto r = FloatMember(c.Find("r")), g = FloatMember(c.Find("g")), b = FloatMember(c.Find("b"));
        if (!r || !g || !b) return std::nullopt;
        colors.push_back({*r, *g, *b});
    }
    if (colors.empty()) return std::nullopt;  // the Mac requires at least one color
    float tint = Theme::kDefaultTint;  // sessions from before `tint`
    if (const Value* t = v.Find("tint"); t && !t->IsNull()) {
        auto value = FloatMember(t);
        if (!value) return std::nullopt;
        tint = *value;
    }
    return Theme::Make(std::move(colors), *grain, tint);
}

// Swift's synthesized Codable: every member required but expandedTabID.
Value Encode(const SplitView& split) {
    Object o = split.extra;
    Put(o, "id", split.id);
    Array ids;
    for (const auto& id : split.tabIDs) ids.push_back(Value(id));
    Put(o, "tabIDs", Value(std::move(ids)));
    Array factors;
    for (double f : split.widthFactors) factors.push_back(Value(f));
    Put(o, "widthFactors", Value(std::move(factors)));
    Put(o, "orientation", split.orientation);
    PutIf(o, "expandedTabID", split.expandedTabID);
    return Value(std::move(o));
}

std::optional<SplitView> DecodeSplitView(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    bool invalid = false;
    auto id = UuidMember(v, "id", invalid);
    auto expanded = UuidMember(v, "expandedTabID", invalid);
    auto* orientation = String(v, "orientation");
    const Value* ids = v.Find("tabIDs");
    const Value* factors = v.Find("widthFactors");
    // SplitOrientation's two cases; JSONDecoder refuses any other.
    if (!id || invalid || !orientation || (*orientation != "horizontal" && *orientation != "vertical") || !ids ||
        !ids->AsArray() || !factors || !factors->AsArray()) {
        return std::nullopt;
    }
    SplitView split;
    split.id = *id;
    for (const auto& element : *ids->AsArray()) {
        auto* text = element.AsString();
        auto normalized = text ? NormalizeUuid(*text) : std::nullopt;
        if (!normalized) return std::nullopt;
        split.tabIDs.push_back(*normalized);
    }
    for (const auto& element : *factors->AsArray()) {
        if (!element.AsNumber()) return std::nullopt;
        split.widthFactors.push_back(*element.AsNumber());
    }
    split.orientation = *orientation;
    split.expandedTabID = expanded;
    split.extra = Extra(v, {"id", "tabIDs", "widthFactors", "orientation", "expandedTabID"});
    return split;
}

Value Encode(const ClosedTab& closed) {
    Object o = closed.extra;
    Put(o, "tab", Encode(closed.tab));
    Put(o, "spaceID", closed.spaceID);
    Put(o, "index", static_cast<double>(closed.index));
    if (closed.archivedAt) Put(o, "archivedAt", *closed.archivedAt);
    if (closed.reason) Put(o, "reason", std::string(*closed.reason == ArchiveReason::Auto ? "auto" : "manual"));
    if (closed.littleKite) Put(o, "littleKite", *closed.littleKite);
    return Value(std::move(o));
}

std::optional<ClosedTab> DecodeClosedTab(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    bool invalid = false;
    auto spaceID = UuidMember(v, "spaceID", invalid);
    const Value* tabValue = v.Find("tab");
    auto tab = tabValue ? DecodeTab(*tabValue) : std::nullopt;
    const Value* index = v.Find("index");
    // An Int: JSONDecoder refuses a fraction or a number past Int's range.
    const std::optional<double> number = index ? index->AsNumber() : std::nullopt;
    if (!spaceID || invalid || !tab || !number) return std::nullopt;
    const double position = number.value();
    if (position != std::floor(position) || std::fabs(position) > 9.0e15) return std::nullopt;
    ClosedTab closed;
    closed.tab = std::move(*tab);
    closed.spaceID = *spaceID;
    closed.index = static_cast<long long>(position);
    if (const Value* at = v.Find("archivedAt"); at && !at->IsNull()) {
        if (!at->AsNumber()) return std::nullopt;
        closed.archivedAt = *at->AsNumber();
    }
    if (const Value* reason = v.Find("reason"); reason && !reason->IsNull()) {
        const std::string* raw = reason->AsString();
        if (!raw || (*raw != "manual" && *raw != "auto")) return std::nullopt;
        closed.reason = *raw == "auto" ? ArchiveReason::Auto : ArchiveReason::Manual;
    }
    if (const Value* little = v.Find("littleKite"); little && !little->IsNull()) {
        if (!little->AsBool()) return std::nullopt;
        closed.littleKite = *little->AsBool();
    }
    closed.extra = Extra(v, {"tab", "spaceID", "index", "archivedAt", "reason", "littleKite"});
    return closed;
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
    // Written only when there are any, as the Mac does.
    if (space.splits.empty()) o.erase("splits");
    else Put(o, "splits", EncodeArray(space.splits));
    return Value(std::move(o));
}

std::optional<Space> DecodeSpace(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    bool invalid = false;
    auto id = UuidMember(v, "id", invalid);
    auto selectedTab = UuidMember(v, "selectedTabID", invalid);
    auto* name = String(v, "name");
    auto* icon = String(v, "icon");
    const Value* themeValue = v.Find("theme");
    auto theme = themeValue ? DecodeTheme(*themeValue) : std::nullopt;
    auto tabs = DecodeArray<Tab>(v.Find("tabs"), DecodeTab);
    if (!id || invalid || !name || !icon || !theme || !tabs) return std::nullopt;
    Space space;
    space.id = *id;
    space.name = *name;
    space.icon = *icon;
    space.theme = std::move(*theme);
    space.tabs = std::move(*tabs);
    if (const Value* items = v.Find("pinnedItems"); items && !items->IsNull()) {
        auto decoded = DecodeArray<PinnedItem>(items, DecodePinnedItem);
        if (!decoded) return std::nullopt;
        space.pinnedItems = std::move(*decoded);
    } else if (const Value* legacy = v.Find("pinned"); legacy && !legacy->IsNull()) {
        // Sessions from before folders stored a flat `pinned` array of tabs.
        auto decoded = DecodeArray<Tab>(legacy, DecodeTab);
        if (!decoded) return std::nullopt;
        for (auto& tab : *decoded) space.pinnedItems.push_back(PinnedItem{std::move(tab)});
    }
    space.selectedTabID = selectedTab;
    if (const Value* splits = v.Find("splits"); splits && !splits->IsNull()) {
        auto decoded = DecodeArray<SplitView>(splits, DecodeSplitView);
        if (!decoded) return std::nullopt;
        space.splits = std::move(*decoded);
    }
    space.extra = Extra(v, {"id", "name", "icon", "theme", "pinnedItems", "pinned", "tabs", "selectedTabID", "splits"});
    return space;
}

Value Encode(const BrowserState& state) {
    Object o = state.extra;
    Put(o, "spaces", EncodeArray(state.spaces));
    Put(o, "selectedSpaceID", state.selectedSpaceID);
    // The default profile's grid keeps the key it had before profiles; the others go under
    // profileFavorites, written only when there are any (BrowserState.encode).
    auto def = state.favoritesByProfile.find(BrowserState::kDefaultProfile);
    Put(o, "favorites", def == state.favoritesByProfile.end() ? Value(Array{}) : EncodeArray(def->second));
    Object others;
    for (const auto& [directory, tabs] : state.favoritesByProfile) {
        if (directory != BrowserState::kDefaultProfile && !tabs.empty()) others.emplace(directory, EncodeArray(tabs));
    }
    if (others.empty()) o.erase("profileFavorites");
    else Put(o, "profileFavorites", Value(std::move(others)));
    Object splits;
    for (const auto& [directory, list] : state.favoriteSplitsByProfile) {
        if (!list.empty()) splits.emplace(directory, EncodeArray(list));
    }
    if (splits.empty()) o.erase("favoriteSplits");
    else Put(o, "favoriteSplits", Value(std::move(splits)));
    Put(o, "recentlyClosed", EncodeArray(state.recentlyClosed));
    Put(o, "archived", EncodeArray(state.archived));
    Put(o, "archiveAfter", state.archiveAfter);
    Put(o, "searchEngine", state.searchEngine);
    return Value(std::move(o));
}

std::optional<BrowserState> DecodeBrowserState(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    auto spaces = DecodeArray<Space>(v.Find("spaces"), DecodeSpace);
    if (!spaces || spaces->empty()) return std::nullopt;
    BrowserState state;
    state.spaces = std::move(*spaces);
    bool invalid = false;
    auto selected = UuidMember(v, "selectedSpaceID", invalid);
    if (invalid) return std::nullopt;
    state.selectedSpaceID = selected && state.SpaceIndex(*selected) ? *selected : state.spaces[0].id;
    if (const Value* byProfile = v.Find("profileFavorites"); byProfile && !byProfile->IsNull()) {
        if (!byProfile->AsObject()) return std::nullopt;
        for (const auto& [directory, tabs] : *byProfile->AsObject()) {
            auto decoded = DecodeArray<Tab>(&tabs, DecodeTab);
            if (!decoded) return std::nullopt;
            if (!decoded->empty()) state.favoritesByProfile[directory] = std::move(*decoded);
        }
    }
    if (const Value* favorites = v.Find("favorites"); favorites && !favorites->IsNull()) {
        auto decoded = DecodeArray<Tab>(favorites, DecodeTab);
        if (!decoded) return std::nullopt;
        if (!decoded->empty()) state.favoritesByProfile[BrowserState::kDefaultProfile] = std::move(*decoded);
    }
    if (const Value* splits = v.Find("favoriteSplits"); splits && !splits->IsNull()) {
        if (!splits->AsObject()) return std::nullopt;
        for (const auto& [directory, list] : *splits->AsObject()) {
            auto decoded = DecodeArray<SplitView>(&list, DecodeSplitView);
            if (!decoded) return std::nullopt;
            if (!decoded->empty()) state.favoriteSplitsByProfile[directory] = std::move(*decoded);
        }
    }
    for (auto [key, list] : {std::pair{"recentlyClosed", &state.recentlyClosed}, std::pair{"archived", &state.archived}}) {
        const Value* value = v.Find(key);
        if (!value || value->IsNull()) continue;
        auto decoded = DecodeArray<ClosedTab>(value, DecodeClosedTab);
        if (!decoded) return std::nullopt;
        *list = std::move(*decoded);
    }
    if (const Value* after = v.Find("archiveAfter"); after && !after->IsNull()) {
        // ArchiveInterval's decoder: the first version's names, and twelve hours for anything
        // else it doesn't know (it never fails).
        const std::string* raw = after->AsString();
        if (!raw) return std::nullopt;
        static const std::map<std::string, std::string, std::less<>> renamed{
            {"day", "twentyFourHours"}, {"week", "sevenDays"}, {"month", "thirtyDays"}};
        auto it = renamed.find(*raw);
        state.archiveAfter = it != renamed.end() ? it->second : *raw;
        if (!state.ArchiveAfterSeconds() && state.archiveAfter != "never") state.archiveAfter = "twelveHours";
    }
    if (auto engine = OptionalString(v, "searchEngine")) state.searchEngine = *engine;
    state.extra = Extra(v, {"spaces", "selectedSpaceID", "favorites", "profileFavorites", "favoriteSplits", "recentlyClosed",
                            "archived", "archiveAfter", "searchEngine"});
    return state;
}

}  // namespace kite
