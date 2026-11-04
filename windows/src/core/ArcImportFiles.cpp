// Ports of KiteCore ArcArchiveImport.swift, ArcSettingsImport.swift, ArcKeyBindingsImport.swift,
// ArcLinkRoutingImport.swift, and KiteMac's ArcSiteSearchImport.swift; see ArcImportFiles.h.

#include "core/ArcImportFiles.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>

#include "core/ArcImport.h"
#include "core/SQLiteReader.h"
#include "core/Unicode.h"
#include "core/Url.h"
#include "core/Uuid.h"

namespace kite::arc_import {

namespace {

using json::Value;


const std::vector<std::pair<std::string_view, std::string_view>> kIntervals = {
    {"never", "Never"},       {"oneHour", "1 hour"},          {"sixHours", "6 hours"}, {"twelveHours", "12 hours"},
    {"twentyFourHours", "24 hours"}, {"sevenDays", "7 days"}, {"thirtyDays", "30 days"},
};

bool IsInterval(std::string_view raw) {
    return std::any_of(kIntervals.begin(), kIntervals.end(), [&](const auto& i) { return i.first == raw; });
}

}  // namespace

// MARK: Archive

std::vector<ClosedTab> ParseArchive(std::string_view text) {
    auto root = json::ParseValue(text);
    const Value* items = root && root->AsObject() ? root->Find("items") : nullptr;
    if (!items || !items->AsArray()) return {};
    std::set<std::string> seen;
    std::vector<std::pair<double, ClosedTab>> entries;
    // A flat [id, object, id, object, ...] list, like the rest of Arc's files.
    for (const Value& item : *items->AsArray()) {
        if (!item.AsObject()) continue;
        const Value* sidebarItem = json::ObjectMember(&item, "sidebarItem");
        const Value* tab = json::ObjectMember(json::ObjectMember(sidebarItem, "data"), "tab");
        const std::string* url = json::StringMember(tab, "savedURL");
        if (!tab || !url || !IsURL(*url) || !url::Scheme(*url)) continue;
        std::string id;
        if (const std::string* raw = json::StringMember(sidebarItem, "id")) id = NormalizeUuid(*raw).value_or("");
        if (id.empty()) id = NewUuid();
        if (!seen.insert(id).second) continue;
        const Value* archived = item.Find("archivedAt");
        const double archivedAt = archived && archived->AsNumber() ? *archived->AsNumber() : 0;
        // Arc's dates are seconds since 2001, as Kite's.
        const Value* active = tab->Find("timeLastActiveAt");
        const double lastActive = active && active->AsNumber() ? *active->AsNumber() : archivedAt;
        const std::string* customTitle = json::StringMember(sidebarItem, "title");
        const std::string* savedTitle = json::StringMember(tab, "savedTitle");
        const std::string* space = json::StringMember(json::ObjectMember(json::ObjectMember(&item, "source"), "space"), "_0");
        ClosedTab closed;
        closed.tab.id = id;
        closed.tab.url = *url;
        closed.tab.title = customTitle && !customTitle->empty() ? *customTitle : savedTitle ? *savedTitle : "";
        closed.tab.lastActiveAt = lastActive;
        closed.spaceID = space ? NormalizeUuid(*space).value_or(kNoSpace) : kNoSpace;
        closed.index = 0;
        entries.emplace_back(archivedAt, std::move(closed));
    }
    std::stable_sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    std::vector<ClosedTab> out;
    for (auto& [at, closed] : entries) out.push_back(std::move(closed));
    return out;
}

int MergeArchive(BrowserState& state, const std::vector<ClosedTab>& imported) {
    std::set<std::string> existing;
    for (const ClosedTab& closed : state.archived) existing.insert(closed.tab.id);
    std::vector<ClosedTab> archived;
    std::set<std::string> added;
    for (const ClosedTab& closed : imported) {
        if (existing.contains(closed.tab.id)) continue;
        archived.push_back(closed);
        added.insert(closed.tab.id);
    }
    archived.insert(archived.end(), state.archived.begin(), state.archived.end());
    if (archived.size() > BrowserState::kArchiveLimit) {
        archived.erase(archived.begin(), archived.begin() + static_cast<std::ptrdiff_t>(archived.size() - BrowserState::kArchiveLimit));
    }
    state.archived = std::move(archived);
    return static_cast<int>(std::count_if(state.archived.begin(), state.archived.end(),
                                          [&](const ClosedTab& c) { return added.contains(c.tab.id); }));
}

// MARK: Settings

std::vector<std::string> Settings::Names() const {
    std::vector<std::string> out;
    if (warnsBeforeQuitting) out.push_back("Warn before quitting");
    if (opensExternalLinksInLittleKite) out.push_back("Open links from other apps in Little Arc");
    if (archiveAfter) out.push_back("Archive tabs after: " + ArchiveIntervalTitle(*archiveAfter));
    return out;
}

Settings Settings::FromDefaults(const Value& defaults) {
    // `raw as? Bool`: a boolean, or an NSNumber 0 or 1 (a plist <integer>).
    auto boolean = [&](std::string_view key) -> std::optional<bool> {
        const Value* v = defaults.Find(key);
        if (!v) return std::nullopt;
        if (auto b = v->AsBool()) return b;
        if (auto n = v->AsNumber(); n && (*n == 0 || *n == 1)) return *n == 1;
        return std::nullopt;
    };
    Settings s;
    s.warnsBeforeQuitting = boolean("shouldWarnBeforeQuitting");
    s.opensExternalLinksInLittleKite = boolean("openExternalLinksInLittleBrowserEnabled");
    if (const Value* thresholds = defaults.Find("autoArchiveTimeThresholdsPerProfile")) s.archiveAfter = ArchiveInterval(*thresholds);
    return s;
}

std::optional<std::string> ArchiveInterval(const Value& raw) {
    // A JSON string: Swift's encoding of a dictionary with non-string keys. Profiles are
    // {"default": {}} or {"custom": {"_0": {...}}}, as in StorableSidebar.json.
    const std::string* text = raw.AsString();
    auto root = text ? json::ParseValue(*text) : std::nullopt;
    const Value* list = root && root->AsObject() ? root->Find("thresholds") : nullptr;
    if (!list || !list->AsArray()) return std::nullopt;
    const json::Array& a = *list->AsArray();
    std::optional<std::string> fallback;
    for (size_t i = 0; i + 1 < a.size(); i += 2) {
        auto name = SwiftCaseName(&a[i + 1]);
        if (!name || !IsInterval(*name)) continue;
        if (a[i].AsObject() && a[i].Find("default")) return name;
        if (!fallback) fallback = name;
    }
    // Kite has the one archive setting: with no default-profile entry, take the first there is.
    return fallback;
}

std::string ArchiveIntervalTitle(std::string_view raw) {
    for (const auto& [name, title] : kIntervals) {
        if (name == raw) return std::string(title);
    }
    return std::string(raw);
}

void Apply(BrowserState& state, const Settings& settings) {
    // Saved as asksBeforeQuitting, the Mac's key for warnsBeforeQuitting.
    if (settings.warnsBeforeQuitting) state.extra.insert_or_assign("asksBeforeQuitting", *settings.warnsBeforeQuitting);
    if (settings.archiveAfter) state.archiveAfter = *settings.archiveAfter;
}

// MARK: Key bindings

namespace {

// Arc action ids whose Kite command has another name. The rest share Arc's id, so an override
// for a command Kite doesn't have yet applies once it lands.
std::string KiteAction(const std::string& arc) {
    if (arc == "addressBar") return "openLocation";
    if (arc == "focusNextSpace") return "nextSpace";
    if (arc == "focusPreviousSpace") return "previousSpace";
    return arc;
}

struct ArcStoredShortcut {
    std::string keyEquivalent;
    int64_t flags = 0;
};

// JSONDecoder's reading of Arc's Shortcut; nullopt is a decoding error.
std::optional<ArcStoredShortcut> DecodeShortcut(const Value& v) {
    const std::string* key = json::StringMember(&v, "keyEquivalent");
    const Value* flags = v.Find("deviceIndependentModifierFlags");
    if (!v.AsObject() || !key || !flags || !flags->AsInt()) return std::nullopt;
    return ArcStoredShortcut{*key, *flags->AsInt()};
}

// An optional String member: absent or null is none; another type fails the decode.
bool OptionalString(const Value* object, std::string_view key, std::optional<std::string>& out) {
    const Value* v = json::Member(object, key);
    if (!v || v->IsNull()) return true;
    if (!v->AsString()) return false;
    out = *v->AsString();
    return true;
}

}  // namespace

std::optional<KeyShortcut> ArcShortcut(const std::string& keyEquivalent, int64_t flags) {
    const std::vector<char32_t> scalars = unicode::Decode(keyEquivalent);
    if (scalars.size() != 1) return std::nullopt;
    static const std::map<std::string, std::string, std::less<>> kArrows{
        {"\xE2\x86\x90", "left"}, {"\xE2\x86\x92", "right"}, {"\xE2\x86\x91", "up"}, {"\xE2\x86\x93", "down"}};  // ←→↑↓
    // Arc may also store an arrow as the AppKit function-key character.
    static const std::map<char32_t, std::string> kFunctionKeys{{0xF702, "left"}, {0xF703, "right"}, {0xF700, "up"}, {0xF701, "down"}};
    const auto arrow = kArrows.find(keyEquivalent);
    const auto function = kFunctionKeys.find(scalars[0]);
    std::string key = arrow != kArrows.end() ? arrow->second : function != kFunctionKeys.end() ? function->second : keyEquivalent;
    using M = KeyShortcut::Modifier;
    std::vector<M> modifiers;
    if (flags & (1 << 17)) modifiers.push_back(M::Shift);
    if (flags & (1 << 18)) modifiers.push_back(M::Control);
    if (flags & (1 << 19)) modifiers.push_back(M::Option);
    if (flags & (1 << 20)) modifiers.push_back(M::Command);
    // fn (1 << 23) has no Kite modifier. Dropping it would leave a bare key that fires while typing.
    if ((flags & (1 << 23)) && arrow == kArrows.end() && function == kFunctionKeys.end()) return std::nullopt;
    // KeyShortcut.init lowercases a one-character key, whatever its script.
    if (unicode::Characters(key).size() == 1) key = unicode::Lowercased(key);
    KeyShortcut shortcut(key, modifiers);
    if (!shortcut.IsSafeKeyEquivalent()) return std::nullopt;
    return shortcut;
}

std::optional<std::vector<KeyBindingOverride>> ParseKeyBindings(std::string_view text) {
    auto root = json::ParseValue(text);
    const Value* list = root && root->AsObject() ? root->Find("userOverrides") : nullptr;
    if (!list || !list->AsArray()) return std::nullopt;
    std::vector<KeyBindingOverride> out;
    for (const Value& entry : *list->AsArray()) {
        if (!entry.AsObject()) return std::nullopt;
        const Value* action = json::ObjectMember(&entry, "action");
        const std::string* identifier = json::StringMember(action, "identifier");
        const Value* state = json::ObjectMember(&entry, "state");
        if (!identifier || !state) return std::nullopt;
        // state is [String: [String: Shortcut]]: every value must decode, used or not.
        std::optional<ArcStoredShortcut> valid;
        bool unset = false;
        for (const auto& [name, cases] : *state->AsObject()) {
            if (!cases.AsObject()) return std::nullopt;
            for (const auto& [label, shortcut] : *cases.AsObject()) {
                auto decoded = DecodeShortcut(shortcut);
                if (!decoded) return std::nullopt;
                if (name == "valid" && label == "_0") valid = decoded;
            }
            if (name == "unset") unset = true;
        }
        std::optional<std::string> priority, defaultPriority;
        if (!OptionalString(&entry, "priority", priority)) return std::nullopt;
        if (const Value* def = json::Member(&entry, "default"); def && !def->IsNull()) {
            if (!def->AsObject() || !OptionalString(def, "priority", defaultPriority)) return std::nullopt;
        }
        // A priority comes along only when the user changed it from Arc's default for that command.
        std::optional<KeyShortcutPriority> changed;
        if (priority && priority != defaultPriority) changed = PriorityFromRaw(*priority);
        const std::string kite = KiteAction(*identifier);
        if (unset) {
            out.emplace_back(kite, std::nullopt, KeyBindingOverride::Source::Arc, changed);
            continue;
        }
        if (!valid) continue;
        if (auto shortcut = ArcShortcut(valid->keyEquivalent, valid->flags)) {
            out.emplace_back(kite, *shortcut, KeyBindingOverride::Source::Arc, changed);
        }
    }
    return out;
}

// MARK: Air Traffic Control

LinkRouting LinkRouting::Keeping(const std::set<std::string>& ids) const {
    LinkRouting result = *this;
    std::erase_if(result.rules, [&](const air_traffic::Rule& rule) {
        return rule.destination.kind == air_traffic::Destination::Kind::Space && !ids.contains(rule.destination.spaceID);
    });
    if (defaultSpace && !ids.contains(*defaultSpace)) result.defaultSpace.reset();
    return result;
}

std::optional<air_traffic::Destination> ArcDestination(const Value* raw) {
    if (!raw || !raw->AsObject()) return std::nullopt;
    if (raw->Find("littleArc")) return air_traffic::Destination::Little();
    if (raw->Find("mostRecent")) return air_traffic::Destination::MostRecent();
    // Imported spaces keep Arc's ids, so the route finds its space in Kite.
    const std::string* space = json::StringMember(json::ObjectMember(json::ObjectMember(json::ObjectMember(raw, "space"), "_0"), "space"), "_0");
    auto id = space ? NormalizeUuid(*space) : std::nullopt;
    if (!id) return std::nullopt;
    return air_traffic::Destination::InSpace(*id);
}

std::optional<LinkRouting> ParseLinkRouting(std::string_view text) {
    auto root = json::ParseValue(text);
    if (!root || !root->AsObject()) return std::nullopt;
    LinkRouting result;
    const Value* rules = root->Find("rules");
    for (const Value& raw : rules && rules->AsArray() ? *rules->AsArray() : json::Array{}) {
        const Value* object = raw.AsObject() ? &raw : nullptr;
        if (json::ObjectMember(object, "destination") && json::ObjectMember(object, "destination")->Find("profile")) {
            ++result.profileRoutes;
            continue;
        }
        const Value* list = json::Member(object, "sourceComponents");
        const json::Array empty;
        const json::Array& rawComponents = list && list->AsArray() ? *list->AsArray() : empty;
        std::vector<air_traffic::Component> components;
        for (const Value& c : rawComponents) {
            const Value* match = json::ObjectMember(json::ObjectMember(&c, "componentType"), "urlMatch");
            const std::string* pattern = json::StringMember(match, "_1");
            // A style Kite doesn't know could match far more than Arc did, so it isn't read.
            auto styleName = SwiftCaseName(json::Member(match, "_0"));
            auto style = styleName ? air_traffic::MatchStyleFromRaw(*styleName) : std::nullopt;
            if (!pattern || !style) continue;
            const std::string* id = json::StringMember(&c, "id");
            components.push_back({id ? NormalizeUuid(*id).value_or(NewUuid()) : NewUuid(), *style, *pattern});
        }
        // The id is what a second import replaces by, so a route without one is left out.
        const std::string* id = json::StringMember(object, "id");
        auto uuid = id ? NormalizeUuid(*id) : std::nullopt;
        auto destination = ArcDestination(json::Member(object, "destination"));
        if (!uuid || components.empty() || components.size() != rawComponents.size() || !destination) {
            ++result.unreadable;
            continue;
        }
        result.rules.push_back({*uuid, std::move(components), *destination});
    }
    if (auto d = ArcDestination(root->Find("defaultDestination"))) {
        switch (d->kind) {
        case air_traffic::Destination::Kind::Space: result.defaultSpace = d->spaceID; break;
        case air_traffic::Destination::Kind::LittleKite: result.defaultOpensInLittleKite = true; break;
        case air_traffic::Destination::Kind::MostRecentSpace: result.defaultOpensInLittleKite = false; break;
        }
    }
    return result;
}

int Merge(air_traffic::State& state, const LinkRouting& imported) {
    int added = 0;
    for (const air_traffic::Rule& rule : imported.rules) {
        auto it = std::find_if(state.rules.begin(), state.rules.end(), [&](const air_traffic::Rule& r) { return r.id == rule.id; });
        if (it != state.rules.end()) {
            *it = rule;
        } else {
            state.rules.push_back(rule);
            ++added;
        }
    }
    if (imported.defaultSpace) state.defaultDestination = air_traffic::Destination::InSpace(*imported.defaultSpace);
    // Arc's default is now the Little Kite setting, so a space default from before goes.
    else if (imported.defaultOpensInLittleKite) state.defaultDestination.reset();
    return added;
}

// MARK: Site Search

namespace {

std::optional<int64_t> Integer(const sqlite::SqlValue& v) {
    if (auto* i = std::get_if<int64_t>(&v)) return *i;
    // A whole REAL in int64's range; converting anything else (NaN, 1e300) is undefined.
    if (auto* d = std::get_if<double>(&v); d && std::isfinite(*d) && *d >= -9.2e18 && *d <= 9.2e18 && *d == std::trunc(*d)) {
        return static_cast<int64_t>(*d);
    }
    return std::nullopt;
}

// sqlite3_column_text: text as it is, numbers as SQLite prints them, NULL as none.
std::optional<std::string> Text(const sqlite::SqlValue& v) {
    if (auto* s = std::get_if<std::string>(&v)) return *s;
    if (auto* b = std::get_if<sqlite::Blob>(&v)) return b->bytes;
    if (auto* i = std::get_if<int64_t>(&v)) return std::to_string(*i);
    if (auto* d = std::get_if<double>(&v)) {
        char buffer[32];
        std::snprintf(buffer, sizeof buffer, "%.15g", *d);
        return std::string(buffer);
    }
    return std::nullopt;
}

}  // namespace

std::optional<std::vector<SiteSearch>> ParseSiteSearches(std::string_view webData) {
    auto table = sqlite::ReadTable(webData, "keywords");
    if (!table) return std::nullopt;
    const auto name = table->Column("short_name"), keyword = table->Column("keyword"), url = table->Column("url"),
               prepopulated = table->Column("prepopulate_id"), autoReplace = table->Column("safe_for_autoreplace"),
               created = table->Column("date_created");
    if (!name || !keyword || !url || !prepopulated || !autoReplace || !created) return std::nullopt;
    // is_active (1 = on, 2 = off) only exists in newer Chromium; without it, keep the
    // shortcuts the user made (not ones added from sites they visited).
    const auto active = table->Column("is_active");
    std::vector<const std::vector<sqlite::SqlValue>*> rows;
    for (const auto& row : table->rows) {
        if (Integer(row[*prepopulated]) != 0) continue;
        const bool userMade = Integer(row[*autoReplace]) == 0;
        if (active ? !(Integer(row[*active]) == 1 || userMade) : !userMade) continue;
        rows.push_back(&row);
    }
    // ORDER BY date_created: NULL first, then by value; SQLite's sorter keeps rowid order for ties.
    auto key = [&](const std::vector<sqlite::SqlValue>* row) -> std::pair<int, double> {
        const sqlite::SqlValue& v = (*row)[*created];
        if (auto* i = std::get_if<int64_t>(&v)) return {1, static_cast<double>(*i)};
        if (auto* d = std::get_if<double>(&v)) return {1, *d};
        if (std::holds_alternative<std::monostate>(v)) return {0, 0};
        return {2, 0};
    };
    std::stable_sort(rows.begin(), rows.end(), [&](auto* a, auto* b) { return key(a) < key(b); });
    std::vector<SiteSearch> sites;
    for (const auto* row : rows) {
        auto n = Text((*row)[*name]), k = Text((*row)[*keyword]), u = Text((*row)[*url]);
        if (!n || !k || !u) continue;
        auto site = SiteSearch::FromChromium(*n, *k, *u);
        if (!site) continue;
        // One the user made and then turned off lands in "Inactive shortcuts", as in Arc.
        site->isActive = !active || Integer((*row)[*active]) != 2;
        sites.push_back(std::move(*site));
    }
    return sites;
}

// MARK: Profile names

std::map<std::string, std::string> ParseProfileNames(std::string_view localState) {
    std::map<std::string, std::string> names;
    auto root = json::ParseValue(localState);
    const Value* cache = json::ObjectMember(json::ObjectMember(root ? &*root : nullptr, "profile"), "info_cache");
    if (!cache) return names;
    for (const auto& [directory, info] : *cache->AsObject()) {
        const std::string* name = info.AsObject() ? json::StringMember(&info, "name") : nullptr;
        names[directory] = name && !name->empty() ? *name : directory;
    }
    return names;
}

}  // namespace kite::arc_import
