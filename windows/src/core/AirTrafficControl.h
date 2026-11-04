#pragma once
// Air Traffic Control: Arc's routes for links opened from other apps. "If the URL is equal to /
// contains <text>, open it in <space or Little Arc>", and a default for the rest. Ports
// KiteCore's AirTrafficControl.swift: the model, its JSON (LinkRouting.json in the profile, the
// Mac's AirTrafficControlStore, Arc's StorableLinkRouting.json shape) and where a link goes.
// Windows doesn't open links from other apps yet; Import from Arc fills the file both apps read.

#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "core/Json.h"

namespace kite::air_traffic {

// How a component compares its text with the link: "matches" (Is equal to), "contains".
enum class MatchStyle { Matches, Contains };
std::optional<MatchStyle> MatchStyleFromRaw(std::string_view raw);
std::string_view RawValue(MatchStyle style);

struct Component {
    std::string id;  // a UUID
    MatchStyle style = MatchStyle::Contains;
    std::string pattern;
    bool Matches(std::string_view url) const;
    bool operator==(const Component&) const = default;
};

// Where a routed link opens: the most recent space, Little Kite, or a space by id.
struct Destination {
    enum class Kind { MostRecentSpace, LittleKite, Space };
    Kind kind = Kind::LittleKite;
    std::string spaceID;  // Space only
    static Destination MostRecent() { return {Kind::MostRecentSpace, {}}; }
    static Destination Little() { return {Kind::LittleKite, {}}; }
    static Destination InSpace(std::string id) { return {Kind::Space, std::move(id)}; }
    bool operator==(const Destination&) const = default;
};

struct Rule {
    std::string id;  // a UUID: what a second import replaces by
    std::vector<Component> components;
    Destination destination;
    // Any one of the rule's components.
    bool Matches(std::string_view url) const;
    bool operator==(const Rule&) const = default;
};

// What's saved (LinkRouting.json). A missing default follows Open Links from Other Apps in
// Little Kite.
struct State {
    int version = 1;
    std::vector<Rule> rules;
    std::optional<Destination> defaultDestination;

    // Where a link from another app goes: the first route that matches (skipping one to a space
    // that's gone), else the default. Only web links are routed.
    Destination DestinationFor(std::string_view url, const std::set<std::string>& spaceIDs, bool opensExternalLinksInLittleKite) const;

    json::Value ToJson() const;
    // As JSONDecoder reads the Mac's file: nullopt when anything in it doesn't read.
    static std::optional<State> FromJson(const json::Value& value);
    bool operator==(const State&) const = default;
};

json::Value Encode(const Destination& destination);
std::optional<Destination> DecodeDestination(const json::Value& value);

}  // namespace kite::air_traffic
