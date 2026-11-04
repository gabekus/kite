// Port of KiteCore ArcImport.swift (and BrowserImport.merge(imported:), PinnedURL.syncPinnedURLs);
// see ArcImport.h.

#include "core/ArcImport.h"

#include <algorithm>
#include <cmath>
#include <ctime>

#include "core/Profiles.h"
#include "core/SpaceIcon.h"
#include "core/Unicode.h"
#include "core/Url.h"
#include "core/Uuid.h"

namespace kite::arc_import {

namespace {

using json::Value;

constexpr size_t kMaxSplitPanes = 4;  // SplitView.maxPanes

const Value* Member(const Value* object, std::string_view key) { return object ? object->Find(key) : nullptr; }
const json::Object* ObjectAt(const Value* object, std::string_view key) {
    const Value* v = Member(object, key);
    return v ? v->AsObject() : nullptr;
}
const std::string* StringAt(const Value* object, std::string_view key) {
    const Value* v = Member(object, key);
    return v ? v->AsString() : nullptr;
}
// A non-empty string member, as `(x as? String).flatMap { $0.isEmpty ? nil : $0 }`.
std::optional<std::string> NonEmpty(const Value* object, std::string_view key) {
    const std::string* s = StringAt(object, key);
    if (!s || s->empty()) return std::nullopt;
    return *s;
}

// Arc's profile key: {"default": …} or {"custom": {"_0": {"directoryBasename": "Profile 1"}}}.
std::optional<std::string> ProfileKey(const Value* raw) {
    if (!raw || !raw->AsObject()) return std::nullopt;
    // Arc's Default profile lives in User Data/Default, as Kite's does.
    if (raw->Find("default")) return std::string(Profile::kDefaultDirectory);
    const Value* custom = Member(raw, "custom");
    const Value* inner = custom && custom->AsObject() ? custom->Find("_0") : nullptr;
    const std::string* basename = inner && inner->AsObject() ? StringAt(inner, "directoryBasename") : nullptr;
    if (!basename) return std::nullopt;
    return *basename;
}

// An enum case written as Swift encodes it ({"pinned": {}}) or bare ("pinned"): its name.
std::optional<std::string> CaseName(const Value& v) {
    if (auto* s = v.AsString()) return *s;
    if (auto* o = v.AsObject(); o && !o->empty()) return o->begin()->first;
    return std::nullopt;
}

constexpr const char* kFallbackIcons[] = {"\xF0\x9F\x8C\x80", "\xF0\x9F\x8C\xBF", "\xF0\x9F\x8E\xA8",
                                          "\xF0\x9F\x93\x9A", "\xF0\x9F\x8E\xA7", "\xF0\x9F\xA7\xAA"};  // 🌀🌿🎨📚🎧🧪

float Clamp(double x) { return static_cast<float>(std::min(std::max(x, 0.0), 1.0)); }

class Parser {
public:
    explicit Parser(Timestamp now) : now_(now) {}

    // Arc stores most collections as flat [id, object, id, object, ...] arrays.
    void Collect(const json::Array& containers) {
        std::set<std::string> seenSpaces;
        for (const Value& container : containers) {
            if (!container.AsObject()) continue;
            if (const Value* spaces = container.Find("spaces"); spaces && spaces->AsArray()) {
                for (const Value& space : *spaces->AsArray()) {
                    const std::string* id = space.AsObject() ? StringAt(&space, "id") : nullptr;
                    if (!id || !seenSpaces.insert(*id).second) continue;
                    spaceObjects_.push_back(&space);
                }
            }
            if (const Value* items = container.Find("items"); items && items->AsArray()) {
                for (const Value& item : *items->AsArray()) {
                    if (!item.AsObject()) continue;
                    if (const std::string* id = StringAt(&item, "id")) items_[*id] = &item;
                }
            }
            if (const Value* favorites = container.Find("topAppsContainerIDs"); favorites && favorites->AsArray()) {
                const json::Array& list = *favorites->AsArray();
                for (size_t i = 0; i + 1 < list.size(); i += 2) {
                    auto key = ProfileKey(&list[i]);
                    if (key && list[i + 1].AsString()) favoritesContainers_[*key] = *list[i + 1].AsString();
                }
            }
        }
    }

    Result BuildSpaces() {
        Result result;
        for (const Value* object : spaceObjects_) {
            if (auto space = BuildSpace(*object, result.spaces.size())) result.spaces.push_back(std::move(*space));
        }
        // Favorites: a grid per profile, in Arc and in Kite. Default's too: Kite always has it.
        for (const std::string& profile : WithDefault(profiles_)) {
            auto container = favoritesContainers_.find(profile);
            if (container == favoritesContainers_.end()) continue;
            // A split in the favorites grid can't stay one: favorites belong to no space.
            spaceSplits_.clear();
            std::vector<Tab> tabs;
            for (const Value* child : Children(container->second)) {
                for (Tab& tab : FlatTabs(*child)) tabs.push_back(std::move(tab));
            }
            spaceSplits_.clear();
            std::vector<Tab> grid;
            for (Tab& tab : tabs) {
                if (std::none_of(grid.begin(), grid.end(), [&](const Tab& t) { return t.url == tab.url; })) grid.push_back(std::move(tab));
            }
            if (!grid.empty()) result.favoritesByProfile[profile] = std::move(grid);
        }

        if (verticalSplits_ > 0) {
            const bool one = verticalSplits_ == 1;
            result.notes.push_back(std::to_string(verticalSplits_) + " split view" + (one ? " is" : "s are") +
                                   " stacked top to bottom in Arc. Kite shows " + (one ? "it" : "them") +
                                   " side by side until it has that layout.");
        }
        if (!skippedKinds_.empty()) {
            std::string kinds;
            for (const auto& [kind, count] : skippedKinds_) kinds += (kinds.empty() ? "" : ", ") + kind;
            result.notes.push_back("Skipped unsupported sidebar items: " + kinds + ".");
        }
        if (iconsReplaced_ > 0) {
            const bool one = iconsReplaced_ == 1;
            result.notes.push_back(std::to_string(iconsReplaced_) + " space icon" + (one ? " is" : "s are") +
                                   " from Arc's own icon set, which Kite doesn't have, so " + (one ? "it gets" : "they get") +
                                   " a stand-in.");
        }
        result.profiles = profiles_;
        result.tabCount = tabCount_;
        result.folderCount = folderCount_;
        result.splitCount = splitCount_;
        result.untitledSpaceIDs = untitled_;
        result.skippedKinds = skippedKinds_;
        result.iconsReplaced = iconsReplaced_;
        return result;
    }

private:
    // A space's "pinned" and "unpinned" container ids: Mac Arc's `containerIDs` ["pinned", id,
    // "unpinned", id], and Arc for Windows' `newContainerIDs`, whose keys are enum cases.
    static std::map<std::string, std::string> Containers(const Value& object) {
        std::map<std::string, std::string> result;
        for (const char* key : {"containerIDs", "newContainerIDs"}) {
            const Value* raw = object.Find(key);
            if (!raw || !raw->AsArray()) continue;
            const json::Array& list = *raw->AsArray();
            for (size_t i = 0; i + 1 < list.size(); i += 2) {
                // containerIDs takes only string keys, as the Mac's pairs(_:).
                auto name = key[0] == 'c' ? (list[i].AsString() ? std::optional(*list[i].AsString()) : std::nullopt) : CaseName(list[i]);
                if (name && list[i + 1].AsString()) result.emplace(*name, *list[i + 1].AsString());
            }
        }
        return result;
    }

    std::optional<Space> BuildSpace(const Value& object, size_t index) {
        const auto containers = Containers(object);
        spaceSplits_.clear();
        std::vector<PinnedItem> pinned;
        if (auto it = containers.find("pinned"); it != containers.end()) {
            for (const Value* child : Children(it->second)) {
                for (PinnedItem& item : PinnedItems(*child)) pinned.push_back(std::move(item));
            }
        }
        std::vector<Tab> unpinned;
        if (auto it = containers.find("unpinned"); it != containers.end()) {
            for (const Value* child : Children(it->second)) {
                for (Tab& tab : FlatTabs(*child)) unpinned.push_back(std::move(tab));
            }
        }
        const std::string profile = ProfileKey(object.Find("profile")).value_or(Profile::kDefaultDirectory);
        const auto name = NonEmpty(&object, "title");
        if (!name && pinned.empty() && unpinned.empty()) return std::nullopt;
        if (std::find(profiles_.begin(), profiles_.end(), profile) == profiles_.end()) profiles_.push_back(profile);

        splitCount_ += static_cast<int>(spaceSplits_.size());
        verticalSplits_ += static_cast<int>(std::count_if(spaceSplits_.begin(), spaceSplits_.end(),
                                                          [](const SplitView& s) { return s.orientation == "vertical"; }));
        const Value* customInfo = object.Find("customInfo");
        if (customInfo && !customInfo->AsObject()) customInfo = nullptr;
        Space space;
        space.id = UniqueID(object.Find("id"));
        if (!name) untitled_.insert(space.id);
        space.name = name.value_or("Arc Space");
        const auto& presets = Theme::Presets();
        space.icon = Icon(Member(customInfo, "iconType")).value_or(kFallbackIcons[index % std::size(kFallbackIcons)]);
        space.theme = ThemeFrom(Member(customInfo, "windowTheme")).value_or(presets[index % presets.size()]);
        space.pinnedItems = std::move(pinned);
        space.tabs = std::move(unpinned);
        if (!space.tabs.empty()) space.selectedTabID = space.tabs.front().id;
        space.splits = spaceSplits_;
        if (profile != Profile::kDefaultDirectory) SetSpaceProfile(space, profile);
        return space;
    }

    std::vector<const Value*> Children(const std::string& id) const {
        std::vector<const Value*> out;
        auto item = items_.find(id);
        if (item == items_.end()) return out;
        const Value* ids = item->second->Find("childrenIds");
        if (!ids || !ids->AsArray()) return out;
        // `as? [String]`: one id that isn't a string and there are none.
        for (const Value& child : *ids->AsArray()) {
            if (!child.AsString()) return {};
        }
        for (const Value& child : *ids->AsArray()) {
            if (auto found = items_.find(*child.AsString()); found != items_.end()) out.push_back(found->second);
        }
        return out;
    }

    static const Value* Data(const Value& item) {
        const Value* data = item.Find("data");
        return data && data->AsObject() ? data : nullptr;
    }

    // A pinned tab, a folder, or a split view's tabs side by side (the split itself is recorded
    // in spaceSplits_).
    std::vector<PinnedItem> PinnedItems(const Value& item) {
        const Value* data = Data(item);
        if (data && data->Find("list")) {
            ++folderCount_;
            const std::string id = StringAt(&item, "id") ? *StringAt(&item, "id") : std::string();
            std::vector<PinnedItem> contents;
            for (const Value* child : Children(id)) {
                for (PinnedItem& inner : PinnedItems(*child)) contents.push_back(std::move(inner));
            }
            Folder folder;
            folder.name = NonEmpty(&item, "title").value_or("Folder");
            folder.items = std::move(contents);
            folder.id = UniqueID(item.Find("id"));
            return {PinnedItem{std::move(folder)}};
        }
        std::vector<PinnedItem> out;
        for (Tab& tab : FlatTabs(item)) out.push_back(PinnedItem{std::move(tab)});
        return out;
    }

    // Tabs in an item, flattening split views and (outside the pinned section) folders.
    std::vector<Tab> FlatTabs(const Value& item) {
        const Value* data = Data(item);
        if (ObjectAt(data, "tab")) {
            ++tabCount_;
            const Value* tabValue = data->Find("tab");
            Tab imported;
            imported.id = UniqueID(item.Find("id"));
            if (const std::string* saved = StringAt(tabValue, "savedURL"); saved && IsURL(*saved)) imported.url = *saved;
            if (const std::string* title = StringAt(tabValue, "savedTitle")) imported.title = *title;
            // Arc's timestamps would trip Kite's 12-hour auto-archive right away.
            imported.lastActiveAt = now_;
            // An item title is the user's rename; it stays when the page's title changes.
            imported.customTitle = NonEmpty(&item, "title");
            return {std::move(imported)};
        }
        const std::string id = StringAt(&item, "id") ? *StringAt(&item, "id") : std::string();
        if (const Value* split = Member(data, "splitView"); split && split->AsObject()) return SplitTabs(id, *split);
        if (data && data->Find("list")) {
            std::vector<Tab> out;
            for (const Value* child : Children(id)) {
                for (Tab& tab : FlatTabs(*child)) out.push_back(std::move(tab));
            }
            return out;
        }
        if (data && !data->AsObject()->empty()) ++skippedKinds_[data->AsObject()->begin()->first];
        return {};
    }

    // A split view's tabs, in pane order, recording the split for the space. Arc's
    // itemWidthFactors is a flat [itemID, factor, ...] list and may leave panes out.
    std::vector<Tab> SplitTabs(const std::string& id, const Value& split) {
        std::map<std::string, double> widths;
        if (const Value* list = split.Find("itemWidthFactors"); list && list->AsArray()) {
            const json::Array& a = *list->AsArray();
            for (size_t i = 0; i + 1 < a.size(); i += 2) {
                if (a[i].AsString() && a[i + 1].AsNumber()) widths[*a[i].AsString()] = *a[i + 1].AsNumber();
            }
        }
        std::vector<Tab> tabs;
        std::vector<std::optional<double>> factors;
        for (const Value* child : Children(id)) {
            std::vector<Tab> childTabs = FlatTabs(*child);
            std::optional<double> factor;
            if (const std::string* childID = StringAt(child, "id")) {
                if (auto it = widths.find(*childID); it != widths.end()) factor = it->second;
            }
            for (size_t i = 0; i < childTabs.size(); ++i) factors.push_back(i == 0 ? factor : std::nullopt);
            for (Tab& tab : childTabs) tabs.push_back(std::move(tab));
        }
        const size_t panes = std::min(tabs.size(), kMaxSplitPanes);
        if (panes < 2) return tabs;
        SplitView view;
        const Value idValue(id);
        view.id = UniqueID(&idValue);
        for (size_t i = 0; i < panes; ++i) view.tabIDs.push_back(tabs[i].id);
        factors.resize(panes);
        if (auto stored = SplitWidthFactors(factors)) view.widthFactors = *stored;
        else view.widthFactors.assign(panes, 1.0 / static_cast<double>(panes));
        const std::string* orientation = StringAt(&split, "layoutOrientation");
        view.orientation = orientation && (*orientation == "horizontal" || *orientation == "vertical") ? *orientation : "horizontal";
        spaceSplits_.push_back(std::move(view));
        return tabs;
    }

    // Reuses Arc's UUIDs where it can (so importing again updates the same spaces) but never
    // hands out the same id twice.
    std::string UniqueID(const Value* raw) {
        if (raw && raw->AsString()) {
            if (auto id = NormalizeUuid(*raw->AsString()); id && usedIDs_.insert(*id).second) return *id;
        }
        std::string id = NewUuid();
        while (!usedIDs_.insert(id).second) id = NewUuid();
        return id;
    }

    std::optional<std::string> Icon(const Value* raw) {
        if (!raw || !raw->AsObject()) return std::nullopt;
        if (auto emoji = NonEmpty(raw, "emoji_v2")) return emoji;
        if (const Value* code = raw->Find("emoji")) {
            if (auto n = code->AsInt(); n && *n >= 0 && *n <= 0x10FFFF && !(*n >= 0xD800 && *n <= 0xDFFF)) {
                return unicode::Encode(std::u32string(1, static_cast<char32_t>(*n)));
            }
        }
        // Arc for Windows: a name from Arc's icon set. One Kite's Icon tab has too is that
        // symbol; any other gets the stand-in.
        if (auto name = NonEmpty(raw, "icon")) {
            for (const std::string& candidate : {*name, *name + ".fill"}) {
                if (SymbolGlyphFor(candidate)) return std::string(kSymbolIconPrefix) + candidate;
            }
            ++iconsReplaced_;
        }
        return std::nullopt;
    }

    // Every colour in the theme's background, whatever the variant (single colour, gradient,
    // ...), in a stable order.
    static std::optional<Theme> ThemeFrom(const Value* raw) {
        const Value* background = raw && raw->AsObject() ? raw->Find("background") : nullptr;
        if (!background) return std::nullopt;
        std::vector<ThemeColor> colors;
        std::optional<double> noise;
        auto walk = [&](auto&& self, const Value& value) -> void {
            if (const json::Object* dict = value.AsObject()) {
                const Value* r = value.Find("red");
                const Value* g = value.Find("green");
                const Value* b = value.Find("blue");
                if (r && g && b && r->AsNumber() && g->AsNumber() && b->AsNumber()) {
                    ThemeColor color{Clamp(*r->AsNumber()), Clamp(*g->AsNumber()), Clamp(*b->AsNumber())};
                    if (std::find(colors.begin(), colors.end(), color) == colors.end()) colors.push_back(color);
                    return;
                }
                if (const Value* n = value.Find("noiseFactor"); n && n->AsNumber()) noise = *n->AsNumber();
                for (const auto& [key, member] : *dict) self(self, member);
            } else if (const json::Array* list = value.AsArray()) {
                for (const Value& member : *list) self(self, member);
            }
        };
        walk(walk, *background);
        if (colors.empty()) return std::nullopt;
        std::optional<double> intensity;
        std::optional<std::string> translucency;
        auto settings = [&](auto&& self, const Value& value) -> void {
            if (const json::Object* dict = value.AsObject()) {
                if (const Value* i = value.Find("intensityFactor"); i && i->AsNumber()) intensity = *i->AsNumber();
                // Either a bare case name or Swift's enum encoding, {"opaque": {}}.
                if (const Value* t = value.Find("translucencyStyle")) translucency = CaseName(*t);
                for (const auto& [key, member] : *dict) self(self, member);
            } else if (const json::Array* list = value.AsArray()) {
                for (const Value& member : *list) self(self, member);
            }
        };
        settings(settings, *raw);
        // Arc draws the theme at its intensity over the window's material; "opaque" hides it.
        const float tint = translucency == "opaque" ? 1.f : Theme::kDefaultTint * static_cast<float>(intensity.value_or(1));
        return Theme::Make(std::move(colors), static_cast<float>(noise.value_or(0.35)), tint);
    }

    Timestamp now_;
    std::vector<const Value*> spaceObjects_;
    std::map<std::string, const Value*> items_;
    std::map<std::string, std::string> favoritesContainers_;  // Arc profile folder → favorites container id
    std::set<std::string> usedIDs_;
    int tabCount_ = 0, folderCount_ = 0, splitCount_ = 0, verticalSplits_ = 0, iconsReplaced_ = 0;
    std::vector<SplitView> spaceSplits_;  // splits found while building the current space
    std::set<std::string> untitled_;
    std::map<std::string, int> skippedKinds_;
    std::vector<std::string> profiles_;
};

}  // namespace

std::vector<std::string> WithDefault(std::vector<std::string> profiles) {
    if (std::find(profiles.begin(), profiles.end(), Profile::kDefaultDirectory) == profiles.end()) {
        profiles.push_back(Profile::kDefaultDirectory);
    }
    return profiles;
}

std::vector<Tab> Result::FavoritesIn(const std::vector<std::string>& wanted) const {
    std::vector<Tab> out;
    for (const std::string& profile : WithDefault(wanted)) {
        if (auto it = favoritesByProfile.find(profile); it != favoritesByProfile.end()) out.insert(out.end(), it->second.begin(), it->second.end());
    }
    return out;
}

std::vector<std::string> Result::NamedSpaceProfiles() const {
    std::vector<std::string> out;
    for (const Space& space : spaces) {
        if (untitledSpaceIDs.contains(space.id)) continue;
        const std::string profile = SpaceProfile(space).value_or(Profile::kDefaultDirectory);
        if (std::find(out.begin(), out.end(), profile) == out.end()) out.push_back(profile);
    }
    return out;
}

const char* Name(Failure failure) {
    switch (failure) {
    case Failure::NotJSON: return "notJSON";
    case Failure::NotArcSidebar: return "notArcSidebar";
    case Failure::NoSpaces: return "noSpaces";
    }
    return "";
}

std::variant<Result, Failure> Parse(std::string_view text, Timestamp now) {
    auto parsed = json::Parse(text);
    auto* root = std::get_if<Value>(&parsed);
    if (!root) return Failure::NotJSON;
    const Value* sidebar = root->AsObject() ? root->Find("sidebar") : nullptr;
    const Value* containers = sidebar && sidebar->AsObject() ? sidebar->Find("containers") : nullptr;
    if (!containers || !containers->AsArray()) return Failure::NotArcSidebar;
    Parser parser(now);
    parser.Collect(*containers->AsArray());
    Result result = parser.BuildSpaces();
    if (result.spaces.empty()) return Failure::NoSpaces;
    return result;
}

std::vector<std::string> SidebarCandidates(const std::vector<std::string>& fileNames) {
    std::vector<std::string> backups;
    for (const std::string& name : fileNames) {
        if (name.starts_with("StorableSidebar.") && name.ends_with(".json") && name != "StorableSidebar.json") backups.push_back(name);
    }
    std::sort(backups.begin(), backups.end(), std::greater<>());
    backups.insert(backups.begin(), "StorableSidebar.json");
    return backups;
}

bool TriesBackup(std::optional<Failure> failure) { return failure != Failure::NoSpaces; }

std::optional<Timestamp> BackupDate(std::string_view fileName) {
    constexpr std::string_view prefix = "StorableSidebar.", suffix = ".json";
    if (!fileName.starts_with(prefix) || !fileName.ends_with(suffix)) return std::nullopt;
    std::string_view stamp = fileName.substr(prefix.size(), fileName.size() - prefix.size() - suffix.size());
    // yyyy-MM-dd-HH-mm-ss-SSS: 23 characters, digits but for the dashes.
    if (stamp.size() != 23) return std::nullopt;
    int parts[7] = {};
    const size_t widths[7] = {4, 2, 2, 2, 2, 2, 3};
    size_t at = 0;
    for (int i = 0; i < 7; ++i) {
        if (i > 0 && stamp[at++] != '-') return std::nullopt;
        for (size_t k = 0; k < widths[i]; ++k, ++at) {
            if (stamp[at] < '0' || stamp[at] > '9') return std::nullopt;
            parts[i] = parts[i] * 10 + (stamp[at] - '0');
        }
    }
    if (parts[1] < 1 || parts[1] > 12 || parts[2] < 1 || parts[2] > 31 || parts[3] > 23 || parts[4] > 59 || parts[5] > 59) return std::nullopt;
    std::tm tm{};
    tm.tm_year = parts[0] - 1900;
    tm.tm_mon = parts[1] - 1;
    tm.tm_mday = parts[2];
    tm.tm_hour = parts[3];
    tm.tm_min = parts[4];
    tm.tm_sec = parts[5];
    tm.tm_isdst = -1;
    const std::time_t local = std::mktime(&tm);
    if (local == static_cast<std::time_t>(-1)) return std::nullopt;
    // DateFormatter refuses a date that doesn't exist (31 April): mktime would roll it over.
    if (tm.tm_mday != parts[2] || tm.tm_mon != parts[1] - 1) return std::nullopt;
    return FromUnixTime(static_cast<double>(local) + parts[6] / 1000.0);
}

std::optional<std::vector<double>> SplitWidthFactors(const std::vector<std::optional<double>>& known) {
    std::vector<double> stored;
    for (const auto& f : known) {
        if (f) stored.push_back(*f);
    }
    if (stored.empty() || std::any_of(stored.begin(), stored.end(), [](double f) { return !(f > 0); })) return std::nullopt;
    const size_t missing = known.size() - stored.size();
    double sum = 0;
    for (double f : stored) sum += f;
    const double rest = 1 - sum;
    if (missing == 0) return stored;
    if (!(rest > 0)) return std::nullopt;
    std::vector<double> out;
    for (const auto& f : known) out.push_back(f ? *f : rest / static_cast<double>(missing));
    return out;
}

bool IsURL(std::string_view text) {
    if (text.empty()) return false;
    // Spaces and control characters: URL(string:) fails on them (or, on newer macOS, changes
    // the text), and either way Kite shouldn't store one.
    for (unsigned char c : text) {
        if (c <= 0x20 || c == 0x7F) return false;
    }
    return url::HasValidAuthority(text);
}

}  // namespace kite::arc_import

namespace kite {

std::string ArcProfileName(const std::string& directory, const std::map<std::string, std::string>& names) {
    auto it = names.find(directory);
    const std::string name = it == names.end() ? std::string() : std::string(unicode::Trim(it->second));
    return name.empty() ? directory : name;
}

std::map<std::string, std::string> ExistingProfilesForArc(const BrowserState& state, const std::vector<std::string>& directories,
                                                            const std::map<std::string, std::string>& names) {
    std::map<std::string, std::string> result;
    const auto all = AllProfiles(state);
    const auto earlierMap = ArcProfileMap(state);
    for (const std::string& arc : directories) {
        if (arc == Profile::kDefaultDirectory) {
            result[arc] = Profile::kDefaultDirectory;
            continue;
        }
        // By data store, which is never reused: a deleted profile's folder name is.
        if (auto earlier = earlierMap.find(arc); earlier != earlierMap.end()) {
            auto profile = std::find_if(all.begin(), all.end(), [&](const Profile& p) { return p.dataStoreID == earlier->second; });
            if (profile != all.end()) {
                result[arc] = profile->directory;
                continue;
            }
        }
        const std::string name = ArcProfileName(arc, names);
        auto match = std::find_if(all.begin(), all.end(), [&](const Profile& p) { return SameNameIgnoringCase(p.name, name); });
        if (match != all.end()) result[arc] = match->directory;
    }
    return result;
}

ArcMerge MergeArc(BrowserState& state, const std::vector<Space>& imported, const std::map<std::string, std::vector<Tab>>& newFavorites,
                  const std::map<std::string, std::string>& names) {
    std::vector<std::string> arcProfiles;
    for (const Space& space : imported) {
        const std::string arc = SpaceProfile(space).value_or(Profile::kDefaultDirectory);
        if (std::find(arcProfiles.begin(), arcProfiles.end(), arc) == arcProfiles.end()) arcProfiles.push_back(arc);
    }
    arcProfiles = arc_import::WithDefault(arcProfiles);
    std::map<std::string, std::string> arcMap = ArcProfileMap(state);
    std::set<std::string> placedBefore{Profile::kDefaultDirectory};
    for (const auto& [arc, id] : arcMap) placedBefore.insert(arc);
    std::map<std::string, std::string> map = ExistingProfilesForArc(state, arcProfiles, names);
    ArcMerge merge;
    for (const std::string& arc : arcProfiles) {
        if (map.contains(arc)) continue;
        // Taken by a Kite profile that isn't this one, or by another Arc profile of the same name.
        const std::string name = ArcProfileName(arc, names);
        std::optional<Profile> made;
        for (const std::string& candidate : {name, name + " (Arc)", arc, arc + " (Arc)"}) {
            if (ValidateProfileName(state, candidate)) continue;
            auto created = CreateProfile(state, candidate);
            if (auto* profile = std::get_if<Profile>(&created)) made = *profile;
            break;
        }
        // Only a Kite profile named for each candidate stops this; the spaces stay in Default,
        // not remembered, so a later import tries again.
        map[arc] = made ? made->directory : std::string(Profile::kDefaultDirectory);
        if (made) merge.newProfiles.push_back(made->directory);
        else merge.fellBack.insert(arc);
    }
    for (const auto& [arc, directory] : map) {
        if (arc != Profile::kDefaultDirectory && !merge.fellBack.contains(arc)) arcMap[arc] = ProfileFor(state, directory).dataStoreID;
    }
    SetArcProfileMap(state, arcMap);

    for (const std::string& arc : arcProfiles) {
        auto tabs = newFavorites.find(arc);
        auto directory = map.find(arc);
        if (tabs == newFavorites.end() || directory == map.end()) continue;
        std::vector<Tab> grid;
        if (auto it = state.favoritesByProfile.find(directory->second); it != state.favoritesByProfile.end()) grid = it->second;
        std::set<std::string> existing;
        for (const Tab& tab : grid) {
            if (tab.url) existing.insert(*tab.url);
        }
        for (const Tab& tab : tabs->second) {
            if (tab.url && !existing.contains(*tab.url)) {
                grid.push_back(tab);
                ++merge.favoritesAdded;
            }
        }
        if (grid.empty()) state.favoritesByProfile.erase(directory->second);
        else state.favoritesByProfile[directory->second] = std::move(grid);
    }

    std::vector<Space> spaces = imported;
    for (Space& space : spaces) {
        const std::string arc = SpaceProfile(space).value_or(Profile::kDefaultDirectory);
        if (auto index = state.SpaceIndex(space.id); index && placedBefore.contains(arc)) {
            SetSpaceProfile(space, SpaceProfile(state.spaces[*index]));
        } else {
            auto directory = map.find(arc);
            const std::string kite = directory == map.end() ? std::string(Profile::kDefaultDirectory) : directory->second;
            SetSpaceProfile(space, kite == Profile::kDefaultDirectory ? std::nullopt : std::optional(kite));
        }
    }
    std::tie(merge.added, merge.updated) = MergeImported(state, spaces);
    merge.profiles = std::move(map);
    return merge;
}

std::pair<int, int> MergeImported(BrowserState& state, const std::vector<Space>& imported) {
    int added = 0, updated = 0;
    for (const Space& space : imported) {
        if (auto index = state.SpaceIndex(space.id)) {
            state.spaces[*index] = space;
            ++updated;
        } else {
            state.spaces.push_back(space);
            ++added;
        }
    }
    if (!imported.empty()) state.selectedSpaceID = imported.front().id;
    SyncPinnedURLs(state);
    return {added, updated};
}

namespace {

// InternalPage(url) != nil: kite://history, archive, site-settings, settings, search-engines.
bool IsInternalPage(const std::string& url) {
    static const std::set<std::string, std::less<>> kPages{"history", "archive", "site-settings", "settings", "search-engines"};
    if (url::Scheme(url) != "kite") return false;
    auto host = url::Host(url);
    return host && kPages.contains(unicode::Lowercased(*host));
}

void Adopt(Tab& tab) {
    if (!tab.pinnedURL && tab.url && !IsInternalPage(*tab.url) && *tab.url != "about:blank") tab.pinnedURL = tab.url;
}

void AdoptAll(std::vector<PinnedItem>& items) {
    for (PinnedItem& item : items) {
        if (Tab* tab = std::get_if<Tab>(&item.value)) Adopt(*tab);
        else AdoptAll(std::get<Folder>(item.value).items);
    }
}

}  // namespace

void SyncPinnedURLs(BrowserState& state) {
    for (auto& [profile, tabs] : state.favoritesByProfile) {
        for (Tab& tab : tabs) Adopt(tab);
    }
    for (Space& space : state.spaces) AdoptAll(space.pinnedItems);
}

}  // namespace kite
