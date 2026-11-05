// See LogReader.h.

#include "LogReader.h"

#include "core/Json.h"

namespace kiteperf {

using kite::json::Value;

LogReader::~LogReader() {
    if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
}

void LogReader::Pump() {
    if (file_ == INVALID_HANDLE_VALUE) {
        file_ = CreateFileW(path_.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file_ == INVALID_HANDLE_VALUE) return;
    }
    char buffer[65536];
    DWORD got = 0;
    while (ReadFile(file_, buffer, sizeof buffer, &got, nullptr) && got > 0) partial_.append(buffer, got);
    for (size_t end; (end = partial_.find('\n')) != std::string::npos;) {
        Parse(partial_.substr(0, end));
        partial_.erase(0, end + 1);
    }
}

const Mark* LogReader::Find(const std::string& name, int64_t after, const std::string* detail) const {
    for (const Mark& m : marks) {
        if (m.name == name && m.qpc >= after && (!detail || m.detail == *detail)) return &m;
    }
    return nullptr;
}

void LogReader::Parse(const std::string& line) {
    auto parsed = kite::json::Parse(line);
    const Value* v = std::get_if<Value>(&parsed);
    if (!v) return;
    const auto text = [&](const char* key) {
        const Value* at = v->Find(key);
        const std::string* s = at ? at->AsString() : nullptr;
        return s ? *s : std::string();
    };
    const auto integer = [&](const char* key) -> int64_t {
        const Value* at = v->Find(key);
        return at && at->AsNumber() ? static_cast<int64_t>(*at->AsNumber()) : 0;
    };
    const auto number = [&](const char* key) {
        const Value* at = v->Find(key);
        return at && at->AsNumber() ? *at->AsNumber() : 0.0;
    };
    const std::string type = text("type");
    if (type == "header") {
        if (const Value* switches = v->Find("chromiumSwitches"); switches && switches->AsArray()) {
            for (const Value& s : *switches->AsArray()) {
                if (s.AsString()) chromiumSwitches.push_back(*s.AsString());
            }
        }
    } else if (type == "mark") {
        Mark m{text("name"), text("detail"), integer("qpc"), number("presents"), number("commits"), number("pointerMoves"), {}};
        if (const Value* draws = v->Find("surfaceDraws"); draws && draws->AsObject()) {
            for (const auto& [key, count] : *draws->AsObject()) m.draws[key] = count.AsNumber().value_or(0);
        }
        marks.push_back(std::move(m));
    } else if (type == "input") {
        inputs.push_back({text("kind"), integer("inputQpc"), integer("commitQpc"), integer("presentQpc"), integer("targetQpc")});
    } else if (type == "frame") {
        frames.push_back({integer("qpc"), integer("presentQpc"), integer("targetQpc"), number("rate")});
    } else if (type == "dispatch") {
        dispatches.push_back({integer("qpc"), number("ms"), static_cast<unsigned>(integer("msg"))});
    }
}

}  // namespace kiteperf
