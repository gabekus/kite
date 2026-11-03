#pragma once
// Favicons for the sidebar, the Mac's FaviconCache (SidebarKit.swift, FaviconView.swift): an
// icon's URL is fetched once (WinHTTP, as the Mac fetches with URLSession rather than through
// the page) on a thread of its own, decoded with WIC and scaled to the size it's shown at, and
// kept in memory for the run. One that fails isn't asked for again this run, as on the Mac.
//
// Nothing here blocks the UI thread: Get answers from memory and queues what it doesn't have;
// the worker posts `message` to the window when icons arrive, and TakeResults moves them in.

#include <windows.h>

#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>

#include "shell/Capture.h"

namespace kite {

class Favicons {
public:
    // Starts the worker. `message` is posted to `window` when icons have arrived.
    static std::unique_ptr<Favicons> Create(HWND window, UINT message);
    // Tells the worker to stop. It isn't waited for: a fetch can take seconds (a slow server),
    // and the window mustn't wait on it to close; it finishes on its own, or with the process.
    ~Favicons();
    Favicons(const Favicons&) = delete;
    Favicons& operator=(const Favicons&) = delete;

    // The icon at `url` decoded to `side`×`side` px (premultiplied BGRA), or null while it
    // loads and when there's none (failed, not an image, too big): the caller shows the globe
    // then. Asking starts the fetch.
    const Pixels* Get(const std::string& url, UINT side);
    // On `message`: moves the finished icons in. True when one arrived that Get now returns.
    bool TakeResults();

    struct Shared;  // the queue the worker shares (Favicons.cpp)

private:
    using Key = std::pair<std::string, UINT>;
    explicit Favicons(std::shared_ptr<Shared> shared) : shared_(std::move(shared)) {}

    std::shared_ptr<Shared> shared_;
    // UI thread only.
    std::map<Key, Pixels> icons_;
    std::set<Key> asked_;
};

}  // namespace kite
