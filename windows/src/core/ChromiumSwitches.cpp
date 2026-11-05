#include "core/ChromiumSwitches.h"

#include <algorithm>
#include <utility>

namespace kite::chromium_switches {

namespace {

constexpr std::string_view kEnable = "enable-features";
constexpr std::string_view kDisable = "disable-features";

// A list's items as written ("B<Trial"), in order, without empty ones.
std::vector<std::string> Items(std::string_view list) {
    std::vector<std::string> out;
    for (size_t start = 0; start <= list.size();) {
        const size_t comma = std::min(list.find(',', start), list.size());
        if (comma > start) out.emplace_back(list.substr(start, comma - start));
        start = comma + 1;
    }
    return out;
}

// An item's feature name: without a leading '*', and up to its trial ('<') or parameters (':').
std::string_view NameOf(std::string_view item) {
    if (!item.empty() && item.front() == '*') item.remove_prefix(1);
    return item.substr(0, std::min(item.find('<'), item.find(':')));
}

bool Has(const std::vector<std::string>& names, std::string_view name) {
    return std::find(names.begin(), names.end(), name) != names.end();
}

// Adds each item whose name isn't in `items` yet.
void Merge(std::vector<std::string>& items, const std::vector<std::string>& more) {
    for (const std::string& item : more) {
        if (NameOf(item).empty()) continue;
        if (std::none_of(items.begin(), items.end(), [&](const std::string& i) { return NameOf(i) == NameOf(item); })) items.push_back(item);
    }
}

std::string Join(const std::vector<std::string>& items) {
    std::string out;
    for (const std::string& item : items) out += (out.empty() ? "" : ",") + item;
    return out;
}

// Splits "name=value" (value empty without '=').
std::pair<std::string_view, std::string_view> Split(std::string_view entry) {
    const size_t equals = entry.find('=');
    if (equals == std::string_view::npos) return {entry, {}};
    return {entry.substr(0, equals), entry.substr(equals + 1)};
}

// The names `requested` turns on.
std::vector<std::string> RequestedOn(const std::vector<std::string>& requested) {
    std::vector<std::string> on;
    for (const std::string& entry : requested) {
        const auto [name, value] = Split(entry);
        if (name != kEnable) continue;
        for (const std::string& n : FeatureNames(value)) on.push_back(n);
    }
    return on;
}

}  // namespace

std::vector<std::string> DefaultDisabledFeatures() { return {std::string(kNativeOcclusion)}; }

std::vector<std::string> FeatureNames(std::string_view list) {
    std::vector<std::string> out;
    for (const std::string& item : Items(list)) {
        const std::string_view name = NameOf(item);
        if (!name.empty()) out.emplace_back(name);
    }
    return out;
}

std::vector<std::string> BrowserSwitches(const std::vector<std::string>& requested, std::string_view existingEnable,
                                         std::string_view existingDisable) {
    std::vector<std::string> out;
    std::vector<std::string> enable = Items(existingEnable), disable = Items(existingDisable);
    std::vector<std::string> requestedDisable;
    for (const std::string& entry : requested) {
        const auto [name, value] = Split(entry);
        if (name == kEnable) Merge(enable, Items(value));
        else if (name == kDisable) Merge(requestedDisable, Items(value));
        else out.push_back(entry);
    }
    const std::vector<std::string> on = FeatureNames(Join(enable));
    const std::vector<std::string> requestedOn = RequestedOn(requested);
    std::vector<std::string> defaults;
    for (const std::string& feature : DefaultDisabledFeatures())
        if (!Has(on, feature)) defaults.push_back(feature);
    Merge(disable, defaults);
    Merge(disable, requestedDisable);
    std::erase_if(disable, [&](const std::string& item) { return Has(requestedOn, NameOf(item)); });

    const std::string enableValue = Join(enable), disableValue = Join(disable);
    if (enableValue != existingEnable) out.push_back(std::string(kEnable) + "=" + enableValue);
    if (disableValue != existingDisable) out.push_back(std::string(kDisable) + "=" + disableValue);
    return out;
}

std::string FeatureProblem(const std::vector<std::string>& requested, std::string_view cefEnable, std::string_view cefDisable,
                           std::string_view enable, std::string_view disable) {
    const std::vector<std::string> on = FeatureNames(enable), off = FeatureNames(disable);
    for (const std::string& name : on)
        if (Has(off, name)) return name + " is in both enable-features and disable-features";
    const std::vector<std::string> requestedOn = RequestedOn(requested);
    std::vector<std::string> defaults = DefaultDisabledFeatures();
    Merge(defaults, {"CalculateNativeWinOcclusion"});
    for (const std::string& name : FeatureNames(cefDisable))
        if (!Has(off, name) && !Has(requestedOn, name)) return name + ", CEF's own, isn't in disable-features any more";
    for (const std::string& name : FeatureNames(cefEnable))
        if (!Has(on, name)) return name + ", CEF's own, isn't in enable-features any more";
    for (const std::string& feature : defaults) {
        if (Has(requestedOn, feature)) {
            if (!Has(on, feature)) return feature + " was asked for but isn't in enable-features";
        } else if (!Has(off, feature)) {
            return feature + " isn't in disable-features";
        }
    }
    return {};
}

}  // namespace kite::chromium_switches
