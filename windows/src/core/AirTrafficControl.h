#pragma once
// Air Traffic Control: Arc's routes for links opened from other apps. "If the URL is equal to /
// contains <text>, open it in <space or Little Arc>", and a default for the rest. Ports
// KiteCore's AirTrafficControl.swift's model and its JSON (LinkRouting.json in the profile, the
// Mac's AirTrafficControlStore). Windows doesn't open links from other apps yet, so where a link
// goes (State.destination(for:), the rules' matching) comes with the checkpoint that does;
// Import from Arc fills the file both apps read.

#include <optional>
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
    bool operator==(const Rule&) const = default;
};

// What's saved (LinkRouting.json). A missing default follows Open Links from Other Apps in
// Little Kite.
struct State {
    int version = 1;
    std::vector<Rule> rules;
    std::optional<Destination> defaultDestination;

    json::Value ToJson() const;
    // As JSONDecoder reads the Mac's file: nullopt when anything in it doesn't read.
    static std::optional<State> FromJson(const json::Value& value);
    bool operator==(const State&) const = default;
};

json::Value Encode(const Destination& destination);
std::optional<Destination> DecodeDestination(const json::Value& value);

}  // namespace kite::air_traffic
