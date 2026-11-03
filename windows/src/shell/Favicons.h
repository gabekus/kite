#pragma once
// Favicons for the sidebar, the Mac's FaviconCache (SidebarKit.swift, FaviconView.swift): an
// icon's URL is fetched once (WinHTTP, as the Mac fetches with URLSession rather than through
// the page; data: URLs are decoded in place) by a small pool of threads, so one slow server
// doesn't hold up the others, as the Mac's fetches run side by side. Its bytes are kept by URL
// and decoded with WIC at each size it's shown at, so another DPI scales them again without
// fetching. One that fails isn't asked for again this run, as on the Mac. Like the Mac's
// NSCache (500 icons), the cache is bounded: the least recently shown go first.
//
// Nothing here blocks the UI thread: Get answers from memory and queues what it doesn't have;
// a worker posts `message` to the window when icons arrive, and TakeResults moves them in.

#include <windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>

#include "shell/Capture.h"

namespace kite {

class Favicons {
public:
    // Starts the workers. `message` is posted to `window` when icons have arrived.
    static std::unique_ptr<Favicons> Create(HWND window, UINT message);
    // Tells the workers to stop. They aren't waited for: a fetch can take seconds (a slow
    // server), and the window mustn't wait on it to close; each finishes on its own, or with
    // the process.
    ~Favicons();
    Favicons(const Favicons&) = delete;
    Favicons& operator=(const Favicons&) = delete;

    // The icon at `url` decoded to `side`×`side` px (premultiplied BGRA), or null while it
    // loads and when there's none (failed, not an image, too big): the caller shows the globe
    // then. Asking starts the fetch, or the decode at a new size. The pointer is good until the
    // next call.
    const Pixels* Get(const std::string& url, UINT side);
    // On `message`: moves the finished icons in. True when one arrived that Get now returns.
    bool TakeResults();

    struct Shared;  // the queue the workers share (Favicons.cpp)

private:
    explicit Favicons(std::shared_ptr<Shared> shared) : shared_(std::move(shared)) {}

    struct Entry {
        std::shared_ptr<const std::string> bytes;  // once fetched
        bool fetching = false;
        bool failed = false;  // not fetched, or not an image: asked for no more this run
        std::map<UINT, Pixels> sized;
        std::set<UINT> decoding;
        std::set<UINT> failedSides;
        uint64_t used = 0;
    };
    void Evict(const std::string& keep);

    std::shared_ptr<Shared> shared_;
    // UI thread only.
    std::map<std::string, Entry> entries_;
    uint64_t clock_ = 0;
};

}  // namespace kite
