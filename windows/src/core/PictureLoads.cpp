#include "core/PictureLoads.h"

#include <algorithm>

namespace kite {

PictureLoads::Show PictureLoads::Shows(const std::string& name, unsigned side) const {
    if (name.empty()) return Show::Placeholder;
    const auto it = pictures_.find(name);
    if (it == pictures_.end()) return Show::Nothing;
    if (it->second.loaded.contains(side)) return Show::Picture;
    return it->second.unreadable ? Show::Placeholder : Show::Nothing;
}

PictureLoads::Need PictureLoads::Prepare(const std::string& name, unsigned side, double now) {
    if (name.empty()) return {Show::Placeholder, false};
    Picture& picture = pictures_[name];
    if (auto loaded = picture.loaded.find(side); loaded != picture.loaded.end()) {
        loaded->second = ++clock_;
        return {Show::Picture, false};
    }
    // Asked once at a time; an unreadable file again 2 s on, its placeholder showing meanwhile.
    const bool due = !picture.unreadable || now - picture.unreadableAt >= kRetryAfter;
    const bool ask = due && picture.asked.insert(side).second;
    return {picture.unreadable ? Show::Placeholder : Show::Nothing, ask};
}

PictureLoads::Answer PictureLoads::Arrived(const std::string& name, const std::vector<unsigned>& sides, bool readable, double now) {
    Answer answer;
    const auto it = pictures_.find(name);
    if (it == pictures_.end()) return answer;  // no longer shown
    Picture& picture = it->second;
    for (unsigned side : sides) picture.asked.erase(side);
    if (!readable) {
        // The placeholder, which changes nothing when it already showed.
        answer.changed = !picture.unreadable;
        picture.unreadable = true;
        picture.unreadableAt = now;
        return answer;
    }
    picture.unreadable = false;
    for (unsigned side : sides) picture.loaded[side] = ++clock_;
    answer.changed = !sides.empty();
    while (picture.loaded.size() > kMaxSizes) {
        const auto oldest = std::min_element(picture.loaded.begin(), picture.loaded.end(),
                                             [](const auto& a, const auto& b) { return a.second < b.second; });
        answer.evicted.push_back(oldest->first);
        picture.loaded.erase(oldest);
    }
    return answer;
}

void PictureLoads::Retain(const std::set<std::string>& names) {
    std::erase_if(pictures_, [&](const auto& entry) { return !names.contains(entry.first); });
}

}  // namespace kite
