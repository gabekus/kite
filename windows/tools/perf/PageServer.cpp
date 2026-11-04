// See PageServer.h.

#include "PageServer.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <fstream>
#include <iterator>

namespace kiteperf {

namespace {

std::string ReadFile(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

std::string Response(int status, const char* reason, const std::string& body, const char* type) {
    return "HTTP/1.1 " + std::to_string(status) + " " + reason + "\r\nContent-Type: " + type +
           "\r\nContent-Length: " + std::to_string(body.size()) + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + body;
}

}  // namespace

std::unique_ptr<PageServer> PageServer::Start(const std::filesystem::path& pages, int hosts, uint16_t port, std::wstring& error) {
    std::unique_ptr<PageServer> server(new PageServer());
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(pages, ec)) {
        if (!entry.is_regular_file()) continue;
        const std::string name = entry.path().filename().string();
        if (name == "static.html") server->staticPage_ = ReadFile(entry.path());
        else server->files_["/" + name] = ReadFile(entry.path());
    }
    if (server->staticPage_.empty()) {
        error = L"no static.html in " + pages.wstring();
        return nullptr;
    }
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        error = L"WSAStartup failed";
        return nullptr;
    }
    // Each loopback address on its own: binding them, unlike 0.0.0.0, asks nothing of the firewall.
    for (int host = 1; host <= hosts; ++host) {
        SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        BOOL exclusive = TRUE;
        setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof exclusive);
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        address.sin_addr.s_addr = htonl(0x7F000000u | static_cast<u_long>(host));
        if (s == INVALID_SOCKET || bind(s, reinterpret_cast<sockaddr*>(&address), sizeof address) != 0 || listen(s, 64) != 0) {
            error = L"couldn't listen on 127.0.0." + std::to_wstring(host) + L":" + std::to_wstring(port) + L" (" +
                    std::to_wstring(WSAGetLastError()) + L"): is another kiteperf running?";
            if (s != INVALID_SOCKET) closesocket(s);
            return nullptr;
        }
        server->listeners_.push_back(static_cast<uintptr_t>(s));
    }
    server->thread_ = std::thread([raw = server.get()] { raw->Run(); });
    return server;
}

PageServer::~PageServer() {
    quit_ = true;
    if (thread_.joinable()) thread_.join();
    for (uintptr_t s : listeners_) closesocket(static_cast<SOCKET>(s));
    WSACleanup();
}

std::string PageServer::Respond(const std::string& request) {
    ++requests_;
    // "GET /path?query HTTP/1.1"
    const size_t start = request.find(' ');
    const size_t end = start == std::string::npos ? start : request.find(' ', start + 1);
    if (start == std::string::npos || end == std::string::npos) return Response(400, "Bad Request", "", "text/plain");
    std::string path = request.substr(start + 1, end - start - 1);
    if (const size_t query = path.find('?'); query != std::string::npos) path.resize(query);
    if (path == "/favicon.ico") {
        ++favicons_;
        return Response(404, "Not Found", "", "text/plain");
    }
    if (path.size() > 7 && path.starts_with("/p") && path.ends_with(".html")) {
        const std::string n = path.substr(2, path.size() - 7);
        if (!n.empty() && n.size() <= 2 && n.find_first_not_of("0123456789") == std::string::npos) {
            std::string page = staticPage_;
            for (size_t at; (at = page.find("{{N}}")) != std::string::npos;) page.replace(at, 5, n);
            return Response(200, "OK", page, "text/html; charset=utf-8");
        }
    }
    if (auto it = files_.find(path); it != files_.end()) return Response(200, "OK", it->second, "text/html; charset=utf-8");
    return Response(404, "Not Found", "", "text/plain");
}

void PageServer::Run() {
    struct Client {
        SOCKET socket;
        std::string request;
    };
    std::vector<Client> clients;
    while (!quit_) {
        std::vector<WSAPOLLFD> polls;
        for (uintptr_t s : listeners_) polls.push_back({static_cast<SOCKET>(s), POLLRDNORM, 0});
        for (const Client& c : clients) polls.push_back({c.socket, POLLRDNORM, 0});
        if (WSAPoll(polls.data(), static_cast<ULONG>(polls.size()), 100) <= 0) continue;
        for (size_t i = 0; i < listeners_.size(); ++i) {
            if (!(polls[i].revents & POLLRDNORM)) continue;
            SOCKET client = accept(polls[i].fd, nullptr, nullptr);
            if (client != INVALID_SOCKET) clients.push_back({client, {}});
        }
        // Clients accepted just now aren't in `polls`; they're polled next time round.
        for (size_t i = listeners_.size(); i < polls.size(); ++i) {
            if (!polls[i].revents) continue;
            Client& c = clients[i - listeners_.size()];
            char buffer[4096];
            const int got = recv(c.socket, buffer, sizeof buffer, 0);
            if (got > 0) c.request.append(buffer, static_cast<size_t>(got));
            if (got > 0 && c.request.find("\r\n\r\n") == std::string::npos && c.request.size() < 65536) continue;
            if (got > 0) {
                const std::string response = Respond(c.request);
                for (size_t sent = 0; sent < response.size();) {
                    const int n = send(c.socket, response.data() + sent, static_cast<int>(response.size() - sent), 0);
                    if (n <= 0) break;
                    sent += static_cast<size_t>(n);
                }
                shutdown(c.socket, SD_SEND);
            }
            closesocket(c.socket);
            c.socket = INVALID_SOCKET;
        }
        std::erase_if(clients, [](const Client& c) { return c.socket == INVALID_SOCKET; });
    }
    for (const Client& c : clients) closesocket(c.socket);
}

}  // namespace kiteperf
