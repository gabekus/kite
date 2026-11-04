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

// A non-empty string member, as `(x as? String).flatMap { $0.isEmpty ? nil : $0 }`.
std::optional<std::string> NonEmpty(const Value* object, std::string_view key) {
    const std::string* s = json::StringMember(object, key);
    if (!s || s->empty()) return std::nullopt;
    return *s;
}

// Arc's profile key: {"default": …} or {"custom": {"_0": {"directoryBasename": "Profile 1"}}}.
std::optional<std::string> ProfileKey(const Value* raw) {
    if (!raw || !raw->AsObject()) return std::nullopt;
    // Arc's Default profile lives in User Data/Default, as Kite's does.
    if (raw->Find("default")) return std::string(Profile::kDefaultDirectory);
    const Value* custom = json::Member(raw, "custom");
    const Value* inner = custom && custom->AsObject() ? custom->Find("_0") : nullptr;
    const std::string* basename = inner && inner->AsObject() ? json::StringMember(inner, "directoryBasename") : nullptr;
    if (!basename) return std::nullopt;
    return *basename;
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
                    const std::string* id = space.AsObject() ? json::StringMember(&space, "id") : nullptr;
                    if (!id || !seenSpaces.insert(*id).second) continue;
                    spaceObjects_.push_back(&space);
                }
            }
            if (const Value* items = container.Find("items"); items && items->AsArray()) {
                for (const Value& item : *items->AsArray()) {
                    if (!item.AsObject()) continue;
                    if (const std::string* id = json::StringMember(&item, "id")) items_[*id] = &item;
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
        // Where each item a space reaches goes, before any space is built (AssignHomes).
        std::vector<std::string> roots;
        for (const Value* object : spaceObjects_) {
            const auto containers = Containers(*object);
            for (const char* section : {"pinned", "unpinned"}) {
                if (auto it = containers.find(section); it != containers.end()) roots.push_back(it->second);
            }
        }
        std::set<std::string> reserved(roots.begin(), roots.end());
        for (const auto& [profile, container] : favoritesContainers_) reserved.insert(container);
        home_ = AssignHomes(roots, reserved);
        for (const Value* object : spaceObjects_) {
            if (auto space = BuildSpace(*object, result.spaces.size())) result.spaces.push_back(std::move(*space));
        }
        // Favorites: a grid per profile, in Arc and in Kite. Default's too: Kite always has it.
        home_.reset();
        for (const std::string& profile : WithDefault(profiles_)) {
            auto container = favoritesContainers_.find(profile);
            if (container == favoritesContainers_.end()) continue;
            // Each grid is walked on its own: profiles that share a container all get its grid,
            // and a favorite that's also in a space stays in both.
            placed_.clear();
            // A split in the favorites grid can't stay one: favorites belong to no space.
            spaceSplits_.clear();
            std::vector<Tab> tabs;
            for (const Value* child : Children(container->second)) {
                for (Tab& tab : FlatTabs(*child, 0)) tabs.push_back(std::move(tab));
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
        if (tooDeep_ > 0) {
            result.notes.push_back(std::to_string(tooDeep_) + (tooDeep_ == 1 ? " item" : " items") + " nested more than " +
                                   std::to_string(kMaxDepth) + " levels deep " + (tooDeep_ == 1 ? "was" : "were") + " left out.");
        }
        if (repeated_ > 0) {
            result.notes.push_back("Skipped " + std::to_string(repeated_) + " repeated or circular sidebar " +
                                   (repeated_ == 1 ? "entry." : "entries."));
        }
        result.profiles = profiles_;
        result.tabCount = tabCount_;
        result.folderCount = folderCount_;
        result.splitCount = splitCount_;
        result.untitledSpaceIDs = untitled_;
        result.skippedKinds = skippedKinds_;
        result.iconsReplaced = iconsReplaced_;
        result.itemsTooDeep = tooDeep_;
        result.repeatedItems = repeated_;
        return result;
    }

private:
    // A space's "pinned" and "unpinned" container ids: Mac Arc's `containerIDs` ["pinned", id,
    // "unpinned", id], and Arc for Windows' `newContainerIDs`, whose keys are enum cases.
    static std::map<std::string, std::string> Containers(const Value& object) {
        std::map<std::string, std::string> result;
        // A key given twice takes its last value, as the Mac's pairs(_:); containerIDs, the Mac's
        // own list, wins over newContainerIDs.
        for (const char* key : {"newContainerIDs", "containerIDs"}) {
            const Value* raw = object.Find(key);
            if (!raw || !raw->AsArray()) continue;
            const json::Array& list = *raw->AsArray();
            for (size_t i = 0; i + 1 < list.size(); i += 2) {
                // containerIDs takes only string keys, as the Mac's pairs(_:).
                auto name = key[0] == 'c' ? (list[i].AsString() ? std::optional(*list[i].AsString()) : std::nullopt) : SwiftCaseName(&list[i]);
                if (name && list[i + 1].AsString()) result.insert_or_assign(*name, *list[i + 1].AsString());
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
                for (PinnedItem& item : PinnedItems(*child, 0)) pinned.push_back(std::move(item));
            }
        }
        std::vector<Tab> unpinned;
        if (auto it = containers.find("unpinned"); it != containers.end()) {
            for (const Value* child : Children(it->second)) {
                for (Tab& tab : FlatTabs(*child, 0)) unpinned.push_back(std::move(tab));
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
        bool replaced = false;
        space.icon = Icon(json::Member(customInfo, "iconType"), replaced).value_or(kFallbackIcons[index % std::size(kFallbackIcons)]);
        if (replaced) iconsReplaced_.insert(space.id);
        space.theme = ThemeFrom(json::Member(customInfo, "windowTheme")).value_or(presets[index % presets.size()]);
        space.pinnedItems = std::move(pinned);
        space.tabs = std::move(unpinned);
        if (!space.tabs.empty()) space.selectedTabID = space.tabs.front().id;
        space.splits = spaceSplits_;
        if (profile != Profile::kDefaultDirectory) SetSpaceProfile(space, profile);
        return space;
    }

    // An item's childrenIds; none when one isn't a string (`as? [String]`).
    std::vector<std::string> ChildIDs(const std::string& id) const {
        auto item = items_.find(id);
        if (item == items_.end()) return {};
        const Value* ids = item->second->Find("childrenIds");
        if (!ids || !ids->AsArray()) return {};
        std::vector<std::string> out;
        for (const Value& child : *ids->AsArray()) {
            if (!child.AsString()) return {};
            out.push_back(*child.AsString());
        }
        return out;
    }

    // Whether the walk goes into an item's children (besides a space's containers): folders and
    // split views. A tab's, an easel's or an empty item's children stay out (expands).
    bool Expands(const std::string& id) const {
        auto item = items_.find(id);
        if (item == items_.end()) return false;
        const Value* data = Data(*item->second);
        return data && (data->Find("list") || data->Find("splitView"));
    }

    // Whether `childID` goes under `parentID`: under its home in a space, under whatever lists it
    // in a favorites grid (goesUnder).
    bool GoesUnder(const std::string& childID, const std::string& parentID) const {
        if (!home_) return true;
        auto it = home_->find(childID);
        return it != home_->end() && it->second == parentID;
    }

    // The children of item `id` that go here, each placed once (ArcImport.children(of:)). A
    // listing that repeats an item here or loops back to an ancestor is skipped and counted; one
    // whose item has its home under another parent is skipped quietly, since that loses nothing.
    std::vector<const Value*> Children(const std::string& id) {
        placed_.insert(id);
        std::vector<const Value*> out;
        for (const std::string& childID : ChildIDs(id)) {
            auto child = items_.find(childID);
            if (child == items_.end()) continue;
            if (!GoesUnder(childID, id)) {
                if (home_ && IsAtOrBelow(id, childID, *home_)) ++repeated_;
                continue;
            }
            if (!placed_.insert(childID).second) {
                ++repeated_;
                continue;
            }
            out.push_back(child->second);
        }
        return out;
    }

    // Each item's home in the spaces whose containers are `roots` (assignHomes): the first parent
    // that lists it, in the order the walk meets them, so every item a space reaches is placed.
    // Listed under several (a stale or sync-damaged file), it goes to the parent its parentID
    // names instead, if that parent is reached, expands, lists it, and isn't the item or below
    // it. `reserved` ids are never a child. Iterative, so no file overflows the stack here.
    std::map<std::string, std::string> AssignHomes(const std::vector<std::string>& roots, std::set<std::string> claimed) const {
        std::map<std::string, std::string> result;
        std::vector<std::string> order;
        const std::set<std::string> rootSet(roots.begin(), roots.end());
        for (const std::string& root : roots) {
            std::vector<std::string> pending{root};
            while (!pending.empty()) {
                const std::string id = std::move(pending.back());
                pending.pop_back();
                if (!rootSet.contains(id) && !Expands(id)) continue;
                // A parent claims all its children before any is walked, as Children does.
                std::vector<std::string> claimedHere;
                for (const std::string& childID : ChildIDs(id)) {
                    if (!items_.contains(childID) || !claimed.insert(childID).second) continue;
                    result[childID] = id;
                    claimedHere.push_back(childID);
                }
                order.insert(order.end(), claimedHere.begin(), claimedHere.end());
                pending.insert(pending.end(), claimedHere.rbegin(), claimedHere.rend());
            }
        }
        for (const std::string& childID : order) {
            const std::string* parent = json::StringMember(items_.at(childID), "parentID");
            if (!parent || *parent == result[childID]) continue;
            if (!result.contains(*parent) && !rootSet.contains(*parent)) continue;
            if (!rootSet.contains(*parent) && !Expands(*parent)) continue;
            const auto listed = ChildIDs(*parent);
            if (std::find(listed.begin(), listed.end(), childID) == listed.end()) continue;
            if (IsAtOrBelow(*parent, childID, result)) continue;
            result[childID] = *parent;
        }
        return result;
    }

    // Whether `id` is `ancestor` or under it in `home`. Too deep to tell (it would be cut
    // anyway) counts as under, so the first listing stays.
    static bool IsAtOrBelow(const std::string& id, const std::string& ancestor, const std::map<std::string, std::string>& home) {
        std::optional<std::string> current = id;
        // A walked item sits at most kMaxDepth levels under a container, which has no home.
        for (int i = 0; i <= kMaxDepth + 1; ++i) {
            if (!current) return false;
            if (*current == ancestor) return true;
            auto up = home.find(*current);
            current = up == home.end() ? std::nullopt : std::optional(up->second);
        }
        return true;
    }

    // Whether an item `depth` levels down is past kMaxDepth. If so it and everything under it
    // are counted as left out, without recursing (leavesOut).
    bool LeavesOut(const Value& item, int depth) {
        if (depth < kMaxDepth) return false;
        std::vector<const Value*> pending{&item};
        while (!pending.empty()) {
            const Value* next = pending.back();
            pending.pop_back();
            ++tooDeep_;
            const std::string* id = json::StringMember(next, "id");
            if (!id || !Expands(*id)) continue;
            for (const std::string& childID : ChildIDs(*id)) {
                auto child = items_.find(childID);
                if (child == items_.end()) continue;
                if (!GoesUnder(childID, *id) || !placed_.insert(childID).second) continue;
                pending.push_back(child->second);
            }
        }
        return true;
    }

    static const Value* Data(const Value& item) {
        const Value* data = item.Find("data");
        return data && data->AsObject() ? data : nullptr;
    }

    // A pinned tab, a folder, or a split view's tabs side by side (the split itself is recorded
    // in spaceSplits_).
    std::vector<PinnedItem> PinnedItems(const Value& item, int depth) {
        if (LeavesOut(item, depth)) return {};
        const Value* data = Data(item);
        if (data && data->Find("list")) {
            ++folderCount_;
            const std::string id = json::StringMember(&item, "id") ? *json::StringMember(&item, "id") : std::string();
            std::vector<PinnedItem> contents;
            for (const Value* child : Children(id)) {
                for (PinnedItem& inner : PinnedItems(*child, depth + 1)) contents.push_back(std::move(inner));
            }
            Folder folder;
            folder.name = NonEmpty(&item, "title").value_or("Folder");
            folder.items = std::move(contents);
            folder.id = UniqueID(item.Find("id"));
            return {PinnedItem{std::move(folder)}};
        }
        std::vector<PinnedItem> out;
        for (Tab& tab : FlatTabs(item, depth)) out.push_back(PinnedItem{std::move(tab)});
        return out;
    }

    // Tabs in an item, flattening split views and (outside the pinned section) folders.
    std::vector<Tab> FlatTabs(const Value& item, int depth) {
        if (LeavesOut(item, depth)) return {};
        const Value* data = Data(item);
        if (json::ObjectMember(data, "tab")) {
            ++tabCount_;
            const Value* tabValue = data->Find("tab");
            Tab imported;
            imported.id = UniqueID(item.Find("id"));
            if (const std::string* saved = json::StringMember(tabValue, "savedURL"); saved && IsURL(*saved)) imported.url = *saved;
            if (const std::string* title = json::StringMember(tabValue, "savedTitle")) imported.title = *title;
            // Arc's timestamps would trip Kite's 12-hour auto-archive right away.
            imported.lastActiveAt = now_;
            // An item title is the user's rename; it stays when the page's title changes.
            imported.customTitle = NonEmpty(&item, "title");
            return {std::move(imported)};
        }
        const std::string id = json::StringMember(&item, "id") ? *json::StringMember(&item, "id") : std::string();
        if (const Value* split = json::Member(data, "splitView"); split && split->AsObject()) return SplitTabs(id, *split, depth);
        if (data && data->Find("list")) {
            std::vector<Tab> out;
            for (const Value* child : Children(id)) {
                for (Tab& tab : FlatTabs(*child, depth + 1)) out.push_back(std::move(tab));
            }
            return out;
        }
        if (data && !data->AsObject()->empty()) ++skippedKinds_[data->AsObject()->begin()->first];
        return {};
    }

    // A split view's tabs, in pane order, recording the split for the space. Arc's
    // itemWidthFactors is a flat [itemID, factor, ...] list and may leave panes out.
    std::vector<Tab> SplitTabs(const std::string& id, const Value& split, int depth) {
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
            std::vector<Tab> childTabs = FlatTabs(*child, depth + 1);
            std::optional<double> factor;
            if (const std::string* childID = json::StringMember(child, "id")) {
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
        const std::string* orientation = json::StringMember(&split, "layoutOrientation");
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

    std::optional<std::string> Icon(const Value* raw, bool& replaced) {
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
            replaced = true;
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
                if (const Value* t = value.Find("translucencyStyle")) translucency = SwiftCaseName(t);
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
    int tabCount_ = 0, folderCount_ = 0, splitCount_ = 0, verticalSplits_ = 0, tooDeep_ = 0, repeated_ = 0;
    std::set<std::string> iconsReplaced_;
    std::set<std::string> placed_;  // Arc item ids already in this walk's tree
    // The parent each item a space reaches goes under; none while favorites are walked.
    std::optional<std::map<std::string, std::string>> home_;
    std::vector<SplitView> spaceSplits_;  // splits found while building the current space
    std::set<std::string> untitled_;
    std::map<std::string, int> skippedKinds_;
    std::vector<std::string> profiles_;
};

}  // namespace

std::optional<std::string> SwiftCaseName(const json::Value* value) {
    if (!value) return std::nullopt;
    if (auto* name = value->AsString()) return *name;
    if (auto* object = value->AsObject(); object && !object->empty()) return object->begin()->first;
    return std::nullopt;
}

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
    for (Space& space : state.spaces) {
        AdoptAll(space.pinnedItems);
        // Unpinned tabs keep none, so pinning one again pins the page it's on then.
        for (Tab& tab : space.tabs) tab.pinnedURL.reset();
    }
}

}  // namespace kite
