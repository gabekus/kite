#pragma once
// kiteperf's static page server: raw Winsock on 127.0.0.1 … 127.0.0.N, one port, so each host
// is its own site (and Chromium gives each its own renderer) and nothing depends on the
// network. Serves pages/static.html as p1.html … p10.html ({{N}} replaced), and every other
// file in pages/ by name, uncached; counts requests and /favicon.ico hits (answered 404).

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace kiteperf {

class PageServer {
public:
    static std::unique_ptr<PageServer> Start(const std::filesystem::path& pages, int hosts, uint16_t port, std::wstring& error);
    ~PageServer();
    PageServer(const PageServer&) = delete;
    PageServer& operator=(const PageServer&) = delete;

    uint64_t Requests() const { return requests_; }
    uint64_t FaviconHits() const { return favicons_; }

private:
    PageServer() = default;
    void Run();
    std::string Respond(const std::string& request);

    std::map<std::string, std::string> files_;  // "/anim.html" → its bytes
    std::string staticPage_;
    std::vector<uintptr_t> listeners_;
    std::thread thread_;
    std::atomic<bool> quit_{false};
    std::atomic<uint64_t> requests_{0}, favicons_{0};
};

}  // namespace kiteperf
