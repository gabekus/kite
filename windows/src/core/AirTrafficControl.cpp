// Port of KiteCore AirTrafficControl.swift; see AirTrafficControl.h.

#include "core/AirTrafficControl.h"

#include <algorithm>

#include "core/Unicode.h"
#include "core/Url.h"
#include "core/Uuid.h"

namespace kite::air_traffic {

namespace {

std::string StripWWW(std::string host) { return host.starts_with("www.") ? host.substr(4) : host; }

std::string Normalized(std::string s) {
    for (std::string_view prefix : {"https://", "http://"}) {
        if (s.starts_with(prefix)) s.erase(0, prefix.size());
    }
    s = StripWWW(std::move(s));
    while (!s.empty() && s.back() == '/') s.pop_back();
    return s;
}

const std::string* StringAt(const json::Value& v, std::string_view key) {
    const json::Value* m = v.Find(key);
    return m ? m->AsString() : nullptr;
}

std::optional<std::string> UuidAt(const json::Value& v, std::string_view key) {
    const std::string* text = StringAt(v, key);
    return text ? NormalizeUuid(*text) : std::nullopt;
}

}  // namespace

std::optional<MatchStyle> MatchStyleFromRaw(std::string_view raw) {
    if (raw == "matches") return MatchStyle::Matches;
    if (raw == "contains") return MatchStyle::Contains;
    return std::nullopt;
}

std::string_view RawValue(MatchStyle style) { return style == MatchStyle::Matches ? "matches" : "contains"; }

bool Component::Matches(std::string_view url) const {
    const std::string needle = unicode::Lowercased(unicode::Trim(pattern));
    if (needle.empty()) return false;
    const std::string link = unicode::Lowercased(url);
    if (style == MatchStyle::Contains) return link.find(needle) != std::string::npos;
    // "Is equal to" accepts the site ("spotify.com") or the whole link, ignoring scheme, "www."
    // and a trailing slash.
    const std::string target = Normalized(needle);
    if (auto host = url::Host(url); host && StripWWW(unicode::Lowercased(*host)) == target) return true;
    return Normalized(link) == target;
}

bool Rule::Matches(std::string_view url) const {
    return std::any_of(components.begin(), components.end(), [&](const Component& c) { return c.Matches(url); });
}

Destination State::DestinationFor(std::string_view url, const std::set<std::string>& spaceIDs, bool opensExternalLinksInLittleKite) const {
    auto scheme = url::Scheme(url);
    if (scheme != "http" && scheme != "https") return Destination::MostRecent();
    auto valid = [&](const Destination& d) { return d.kind != Destination::Kind::Space || spaceIDs.contains(d.spaceID); };
    for (const Rule& rule : rules) {
        if (rule.Matches(url) && valid(rule.destination)) return rule.destination;
    }
    const Destination fallback = defaultDestination.value_or(opensExternalLinksInLittleKite ? Destination::Little() : Destination::MostRecent());
    return valid(fallback) ? fallback : Destination::MostRecent();
}

json::Value Encode(const Destination& d) {
    switch (d.kind) {
    case Destination::Kind::MostRecentSpace: return json::Object{{"mostRecentSpace", json::Object{}}};
    case Destination::Kind::LittleKite: return json::Object{{"littleKite", json::Object{}}};
    case Destination::Kind::Space: return json::Object{{"space", json::Object{{"_0", d.spaceID}}}};
    }
    return {};
}

std::optional<Destination> DecodeDestination(const json::Value& v) {
    const json::Object* o = v.AsObject();
    // Swift's enum encoding: one key, the case.
    if (!o || o->size() != 1) return std::nullopt;
    const auto& [name, payload] = *o->begin();
    if (!payload.AsObject()) return std::nullopt;
    if (name == "mostRecentSpace") return Destination::MostRecent();
    if (name == "littleKite") return Destination::Little();
    if (name == "space") {
        if (auto id = UuidAt(payload, "_0")) return Destination::InSpace(*id);
    }
    return std::nullopt;
}

json::Value State::ToJson() const {
    json::Array list;
    for (const Rule& rule : rules) {
        json::Array components;
        for (const Component& c : rule.components) {
            components.push_back(json::Object{{"id", c.id}, {"pattern", c.pattern}, {"style", std::string(RawValue(c.style))}});
        }
        list.push_back(json::Object{{"components", json::Value(std::move(components))}, {"destination", Encode(rule.destination)}, {"id", rule.id}});
    }
    json::Object o{{"rules", json::Value(std::move(list))}, {"version", version}};
    if (defaultDestination) o.emplace("defaultDestination", Encode(*defaultDestination));
    return json::Value(std::move(o));
}

std::optional<State> State::FromJson(const json::Value& v) {
    if (!v.AsObject()) return std::nullopt;
    const json::Value* version = v.Find("version");
    const json::Value* rules = v.Find("rules");
    if (!version || !version->AsInt() || !rules || !rules->AsArray()) return std::nullopt;
    State state;
    state.version = static_cast<int>(*version->AsInt());
    for (const json::Value& raw : *rules->AsArray()) {
        auto id = UuidAt(raw, "id");
        const json::Value* components = raw.Find("components");
        const json::Value* destination = raw.Find("destination");
        auto decoded = destination ? DecodeDestination(*destination) : std::nullopt;
        if (!id || !components || !components->AsArray() || !decoded) return std::nullopt;
        Rule rule{*id, {}, *decoded};
        for (const json::Value& c : *components->AsArray()) {
            auto componentID = UuidAt(c, "id");
            const std::string* style = StringAt(c, "style");
            const std::string* pattern = StringAt(c, "pattern");
            auto matchStyle = style ? MatchStyleFromRaw(*style) : std::nullopt;
            if (!componentID || !matchStyle || !pattern) return std::nullopt;
            rule.components.push_back({*componentID, *matchStyle, *pattern});
        }
        state.rules.push_back(std::move(rule));
    }
    if (const json::Value* d = v.Find("defaultDestination"); d && !d->IsNull()) {
        auto decoded = DecodeDestination(*d);
        if (!decoded) return std::nullopt;
        state.defaultDestination = *decoded;
    }
    return state;
}

}  // namespace kite::air_traffic
