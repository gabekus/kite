#pragma once
// Which space pictures are loaded, loading or unreadable, at which sizes (pixels on a side), and
// what a draw of one shows: the rules of SpaceIconPainter's picture cache, without the pixels
// (the shell keeps those, by the same name and size). Times are seconds on any steady clock.
//
// A file is read on a worker, once for the sizes asked of it while it waited; each keeps at most
// two sizes (the bar's and the header's: a DPI change's old ones go). Until its first answer a
// picture draws nothing. A file that can't be read shows the placeholder, and a draw 2 s on asks
// again while it still shows; only an answer that changes what shows needs a redraw, so nothing
// loops while idle.

#include <map>
#include <set>
#include <string>
#include <vector>

namespace kite {

class PictureLoads {
public:
    static constexpr double kRetryAfter = 2;
    static constexpr size_t kMaxSizes = 2;

    enum class Show { Nothing, Picture, Placeholder };
    struct Need {
        Show show = Show::Nothing;
        bool ask = false;  // ask the worker for this name at this size now
        bool operator==(const Need&) const = default;
    };
    // A draw of `name` (empty: an invalid name) at `side` px, at time `now`.
    Need Prepare(const std::string& name, unsigned side, double now);
    // What a draw shows, without asking.
    Show Shows(const std::string& name, unsigned side) const;

    struct Answer {
        bool changed = false;            // what shows changed: draw again
        std::vector<unsigned> evicted;   // sizes of `name` to drop (beyond kMaxSizes)
        bool operator==(const Answer&) const = default;
    };
    // The worker's answer for `name` at `sides`: read (each size decoded) or not.
    Answer Arrived(const std::string& name, const std::vector<unsigned>& sides, bool readable, double now);
    // Keeps only these names; an answer for any other is dropped.
    void Retain(const std::set<std::string>& names);
    bool Known(const std::string& name) const { return pictures_.contains(name); }

private:
    struct Picture {
        bool unreadable = false;
        double unreadableAt = 0;
        std::set<unsigned> asked;               // sizes the worker is reading
        std::map<unsigned, unsigned long long> loaded;  // size -> last use
    };
    std::map<std::string, Picture> pictures_;
    unsigned long long clock_ = 0;
};

}  // namespace kite
