// See Report.h.

#include "Report.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <functional>
#include <iterator>

#include "Processes.h"

namespace kiteperf {

double Round(double value, int digits) {
    const double scale = std::pow(10.0, digits);
    return std::round(value * scale) / scale;
}

Value RoundOrNull(std::optional<double> value, int digits) { return value ? Value(Round(*value, digits)) : Value(); }

std::optional<double> Percentile(std::vector<double> values, double p) {
    if (values.empty()) return std::nullopt;
    std::sort(values.begin(), values.end());
    const double rank = p / 100.0 * static_cast<double>(values.size() - 1);
    const size_t low = static_cast<size_t>(std::floor(rank)), high = static_cast<size_t>(std::ceil(rank));
    return values[low] + (values[high] - values[low]) * (rank - static_cast<double>(low));
}

double Ms(int64_t from, int64_t to) { return static_cast<double>(to - from) * 1000.0 / QpcFrequency(); }

std::string Utf8(const std::filesystem::path& path) {
    const std::u8string text = path.u8string();
    return std::string(text.begin(), text.end());
}

const Array& Items(const Value* v) {
    static const Array none;
    return v && v->AsArray() ? *v->AsArray() : none;
}

const Object& Members(const Value* v) {
    static const Object none;
    return v && v->AsObject() ? *v->AsObject() : none;
}

const Value* Path(const Value& v, std::initializer_list<const char*> keys) {
    const Value* at = &v;
    for (const char* key : keys) {
        if (!at || !(at = at->Find(key))) return nullptr;
    }
    return at;
}

std::optional<double> NumberAt(const Value& v, std::initializer_list<const char*> keys) {
    const Value* at = Path(v, keys);
    return at ? at->AsNumber() : std::nullopt;
}

namespace {

const std::string* NameOf(const Value& v) {
    const Value* n = v.Find("name");
    return n ? n->AsString() : nullptr;
}

}  // namespace

Value MedianOf(const std::vector<const Value*>& values, const std::string& key) {
    std::vector<const Value*> present;
    for (const Value* v : values) {
        if (v && !v->IsNull()) present.push_back(v);
    }
    if (present.empty()) return {};
    const Value& first = *present.front();
    if (first.IsNumber()) {
        std::vector<double> numbers;
        for (const Value* v : present) {
            if (auto n = v->AsNumber()) numbers.push_back(*n);
        }
        return Round(*Percentile(numbers, 50), 2);
    }
    if (first.IsBool()) {
        size_t yes = 0;
        for (const Value* v : present) yes += v->AsBool().value_or(false) ? 1 : 0;
        if (key == "pass") return yes == values.size();
        return yes * 2 > values.size();
    }
    if (first.IsObject()) {
        std::vector<std::string> keys;
        for (const Value* v : present) {
            if (!v->AsObject()) continue;
            for (const auto& [name, member] : *v->AsObject()) {
                if (name != "processes" && std::find(keys.begin(), keys.end(), name) == keys.end()) keys.push_back(name);
            }
        }
        Object out;
        for (const std::string& name : keys) {
            std::vector<const Value*> members;
            for (const Value* v : values) members.push_back(v ? v->Find(name) : nullptr);
            out[name] = MedianOf(members, name);
        }
        return out;
    }
    if (first.AsArray()) {
        // Named objects (the phases): every name any run has, in order.
        std::vector<std::string> names;
        bool named = true;
        for (const Value* v : present) {
            for (const Value& e : Items(v)) {
                const std::string* name = NameOf(e);
                if (!name) {
                    named = false;
                    continue;
                }
                if (std::find(names.begin(), names.end(), *name) == names.end()) names.push_back(*name);
            }
        }
        if (!named || names.empty()) return first;
        Array out;
        for (const std::string& name : names) {
            std::vector<const Value*> matches;
            for (const Value* v : values) {
                const Value* match = nullptr;
                for (const Value& e : Items(v)) {
                    if (const std::string* n = NameOf(e); n && *n == name) match = &e;
                }
                matches.push_back(match);
            }
            out.push_back(MedianOf(matches));
        }
        return out;
    }
    return first;
}

namespace {

void PrettyInto(const Value& v, std::string& out, int indent) {
    const std::string pad(static_cast<size_t>(indent + 2), ' '), close(static_cast<size_t>(indent), ' ');
    if (const Object* o = v.AsObject(); o && !o->empty()) {
        out += "{\n";
        size_t i = 0;
        for (const auto& [key, member] : *o) {
            out += pad + kite::json::Write(Value(key)) + ": ";
            PrettyInto(member, out, indent + 2);
            out += ++i < o->size() ? ",\n" : "\n";
        }
        out += close + "}";
    } else if (const Array* a = v.AsArray(); a && !a->empty()) {
        if (std::all_of(a->begin(), a->end(), [](const Value& e) { return e.IsNumber() || e.IsNull() || e.IsString(); })) {
            out += kite::json::Write(v);
            return;
        }
        out += "[\n";
        for (size_t i = 0; i < a->size(); ++i) {
            out += pad;
            PrettyInto((*a)[i], out, indent + 2);
            out += i + 1 < a->size() ? ",\n" : "\n";
        }
        out += close + "]";
    } else {
        out += kite::json::Write(v);
    }
}

std::string Cell(std::optional<double> v, int digits = 1) {
    if (!v) return "–";
    char text[32];
    std::snprintf(text, sizeof text, "%.*f", digits, *v);
    return text;
}

std::string CompareCell(std::optional<double> before, std::optional<double> after, int digits = 1) {
    if (!before && !after) return "–";
    std::string cell = Cell(before, digits) + " → " + Cell(after, digits);
    if (before && after && *before != 0) {
        char delta[32];
        std::snprintf(delta, sizeof delta, " (%+.0f%%)", (*after - *before) / *before * 100);
        cell += delta;
    }
    return cell;
}

const Value* PhaseNamed(const Value& result, const std::string& name) {
    const Value* phases = result.Find("phases");
    for (const Value& p : Items(phases)) {
        if (const std::string* n = NameOf(p); n && *n == name) return &p;
    }
    return nullptr;
}

std::optional<double> GpuMB(const Value& v) {
    const auto d = NumberAt(v, {"gpuDedicatedMB"}), s = NumberAt(v, {"gpuSharedMB"});
    if (!d && !s) return std::nullopt;
    return d.value_or(0) + s.value_or(0);
}

using Get = std::function<std::optional<double>(const Value&)>;

std::string TablesOf(const Value& after, const Value* before) {
    std::string md;
    const auto cell = [&](const Get& get, int digits = 1) {
        return before ? CompareCell(get(*before), get(after), digits) : Cell(get(after), digits);
    };
    const auto phaseCell = [&](const std::string& name, const Get& get, int digits = 1) {
        return cell([&](const Value& r) -> std::optional<double> {
            const Value* p = PhaseNamed(r, name);
            return p ? get(*p) : std::nullopt;
        }, digits);
    };
    const auto at = [](std::initializer_list<const char*> keys) {
        const std::vector<const char*> path(keys);
        return [path](const Value& v) -> std::optional<double> {
            const Value* p = &v;
            for (const char* k : path) {
                if (!(p = p->Find(k))) return std::nullopt;
            }
            return p->AsNumber();
        };
    };
    md += "| phase | Kite visible % | Kite CPU ms/s | private MB | commit MB | GPU MB (dedicated + shared) | GPU ms/s | processes | presents | commits |\n";
    md += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n";
    std::vector<std::string> names;
    for (const Value* r : {before, &after}) {
        const Value* phases = r ? r->Find("phases") : nullptr;
        for (const Value& p : Items(phases)) {
            const std::string* n = NameOf(p);
            const std::string name = n ? *n : "?";
            if (std::find(names.begin(), names.end(), name) == names.end()) names.push_back(name);
        }
    }
    for (const std::string& name : names) {
        const Value* p = PhaseNamed(after, name);
        const bool noisy = p && p->Find("noisy") && p->Find("noisy")->AsBool().value_or(false);
        md += "| " + name + (noisy ? " (noisy)" : "") + " | ";
        md += phaseCell(name, at({"window", "kiteVisiblePct"}), 0) + " | ";
        md += phaseCell(name, at({"totals", "cpuMsPerS"})) + " | ";
        md += phaseCell(name, at({"totals", "privateWsMB"})) + " | ";
        md += phaseCell(name, at({"totals", "commitMB"})) + " | ";
        md += phaseCell(name, [](const Value& v) -> std::optional<double> {
            const Value* t = v.Find("totals");
            return t ? GpuMB(*t) : std::nullopt;
        }) + " | ";
        md += phaseCell(name, at({"totals", "gpuMsPerS"})) + " | ";
        md += phaseCell(name, at({"totals", "processCount"}), 0) + " | ";
        md += phaseCell(name, at({"kite", "presents"}), 0) + " | ";
        md += phaseCell(name, at({"kite", "commits"}), 0) + " |\n";
    }
    if (const Value* idle = PhaseNamed(after, "idle")) {
        md += "\nAt idle, by process type:\n\n| type | count | CPU ms/s | private MB | commit MB | GPU MB (dedicated + shared) | GPU ms/s |\n"
              "|---|---:|---:|---:|---:|---:|---:|\n";
        const Value* types = idle->Find("byType");
        for (const auto& [type, ignored] : Members(types)) {
            const auto get = [t = type](const char* key) {
                return [t, key](const Value& v) -> std::optional<double> {
                    const Value* b = Path(v, {"byType", t.c_str()});
                    return b ? NumberAt(*b, {key}) : std::nullopt;
                };
            };
            md += "| " + type + " | " + phaseCell("idle", get("processCount"), 0) + " | " + phaseCell("idle", get("cpuMsPerS")) + " | " +
                  phaseCell("idle", get("privateWsMB")) + " | " + phaseCell("idle", get("commitMB")) + " | " +
                  phaseCell("idle", [t = type](const Value& v) -> std::optional<double> {
                      const Value* b = Path(v, {"byType", t.c_str()});
                      return b ? GpuMB(*b) : std::nullopt;
                  }) +
                  " | " + phaseCell("idle", get("gpuMsPerS")) + " |\n";
        }
    }
    md += "\n| measure | value |\n|---|---:|\n";
    const auto row = [&](const std::string& label, const Get& get, int digits = 1) { md += "| " + label + " | " + cell(get, digits) + " |\n"; };
    const auto phaseRow = [&](const std::string& label, const std::string& phase, std::initializer_list<const char*> keys, int digits = 1) {
        if (!PhaseNamed(after, phase) && !(before && PhaseNamed(*before, phase))) return;
        row(label, [&, get = at(keys)](const Value& v) -> std::optional<double> {
            const Value* p = PhaseNamed(v, phase);
            return p ? get(*p) : std::nullopt;
        }, digits);
    };
    row("startup: launch to shown, ms", at({"startup", "shownMs"}));
    row("startup: launch to first page loaded, ms", at({"startup", "firstLoadEndMs"}));
    row("startup: CefInitialize, ms", at({"startup", "cefInitMs"}));
    phaseRow("open: tab load p50, ms", "open", {"loadP50Ms"});
    phaseRow("open: processes started", "open", {"spawns"}, 0);
    phaseRow("open: processes ended", "open", {"exits"}, 0);
    phaseRow("crossfade frames", "switchSpaces", {"frames", "count"}, 0);
    phaseRow("crossfade frame interval p50, ms", "switchSpaces", {"frames", "intervalP50Ms"}, 2);
    phaseRow("crossfade frame interval p99, ms", "switchSpaces", {"frames", "intervalP99Ms"}, 2);
    phaseRow("crossfade frames missed", "switchSpaces", {"frames", "missed"}, 0);
    phaseRow("space switch to present p50, ms", "switchSpaces", {"latency", "command", "toPresentP50Ms"});
    phaseRow("space switches committed / logged", "switchSpaces", {"latency", "command", "committed"}, 0);
    phaseRow("tab switch to present p50, ms", "switchTabs", {"latency", "command", "toPresentP50Ms"});
    phaseRow("hover moves sent", "hover", {"moves"}, 0);
    phaseRow("hover moves committed (the rest changed nothing)", "hover", {"latency", "move", "committed"}, 0);
    phaseRow("hover move to present p50, ms", "hover", {"latency", "move", "toPresentP50Ms"});
    phaseRow("hover move to present p99, ms", "hover", {"latency", "move", "toPresentP99Ms"});
    phaseRow("hover: sidebar surface draws", "hover", {"kite", "surfaceDraws", "sidebar"}, 0);
    phaseRow("idle: dwm CPU ms/s", "idle", {"context", "dwmCpuMsPerS"});
    phaseRow("idle: samples with the real pointer over Kite", "idle", {"window", "pointerOverKiteSamples"}, 0);
    row("shutdown: WM_CLOSE to every process gone, ms", at({"shutdown", "allExitedMs"}));
    row("favicon requests to the page server", at({"faviconHits"}), 0);
    if (const Value* check = after.Find("idleAssert")) {
        const bool pass = check->Find("pass") && check->Find("pass")->AsBool().value_or(false);
        const bool self = check->Find("drewByItself") && check->Find("drewByItself")->AsBool().value_or(false);
        md += std::string("\nIdle check (no presents, no commits over the idle phase, every run): **") +
              (pass ? "pass" : self ? "FAIL: Kite drew by itself" : "fail: only with the real pointer over Kite") + "**\n";
    }
    return md;
}

}  // namespace

std::string Pretty(const Value& v) {
    std::string out;
    PrettyInto(v, out, 0);
    return out + "\n";
}

std::optional<Value> ReadResult(const std::filesystem::path& path, std::string& error) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        error = "can't read " + Utf8(path);
        return std::nullopt;
    }
    const std::string text{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
    auto parsed = kite::json::Parse(text);
    const Value* v = std::get_if<Value>(&parsed);
    const Value* schema = v ? v->Find("schema") : nullptr;
    if (!schema || !schema->AsString() || *schema->AsString() != "kiteperf/1") {
        error = Utf8(path) + " isn't a kiteperf/1 result";
        return std::nullopt;
    }
    return *v;
}

std::string Tables(const Value& result) { return TablesOf(result, nullptr); }

std::string Compare(const Value& before, const Value& after) {
    std::string warnings;
    const auto same = [&](const char* key, const char* what) {
        const Value* a = before.Find(key);
        const Value* b = after.Find(key);
        if (!a || !b || *a != *b) {
            warnings += std::string("> **Warning:** the two differ in ") + what + ": " + (a ? kite::json::Write(*a) : "none") + " and " +
                        (b ? kite::json::Write(*b) : "none") + ".\n";
        }
    };
    same("scenario", "scenario");
    same("phasesRequested", "the phases asked for");
    same("runs", "run count");
    same("frameStatistics", "frame statistics (Windows 11's DirectComposition statistics)");
    same("gpuCounters", "GPU counters (PDH)");
    return warnings + (warnings.empty() ? "" : "\n") + TablesOf(after, &before);
}

}  // namespace kiteperf
