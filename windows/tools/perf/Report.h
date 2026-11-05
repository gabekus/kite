#pragma once
// kiteperf's results: numbers rounded for reading, medians across runs, the JSON file
// (kiteperf/1) and the markdown tables for one result or two (--compare).

#include <cstdint>
#include <filesystem>
#include <initializer_list>
#include <optional>
#include <string>
#include <vector>

#include "core/Json.h"

namespace kiteperf {

using kite::json::Array;
using kite::json::Object;
using kite::json::Value;

double Round(double value, int digits = 2);
Value RoundOrNull(std::optional<double> value, int digits = 2);
// The p-th percentile, interpolated; none for no values.
std::optional<double> Percentile(std::vector<double> values, double p);
// ms between two QueryPerformanceCounter values.
double Ms(int64_t from, int64_t to);
std::string Utf8(const std::filesystem::path& path);

// A value's elements or members, by reference (none for anything else): never a copy, so a
// pointer into them stays valid.
const Array& Items(const Value* v);
const Object& Members(const Value* v);
const Value* Path(const Value& v, std::initializer_list<const char*> keys);
std::optional<double> NumberAt(const Value& v, std::initializer_list<const char*> keys);

// The median of each number across runs, path by path, over the union of every run's keys;
// phases (arrays of named objects) are matched by name, in the order they first appear.
// Per-process lists stay in allRuns only. Booleans are true when most runs say so (a missing
// one says no), except an assertion's `pass`, which needs every run.
Value MedianOf(const std::vector<const Value*>& values, const std::string& key = {});

// Indented JSON, arrays of numbers on one line.
std::string Pretty(const Value& v);
// A result file, or why not.
std::optional<Value> ReadResult(const std::filesystem::path& path, std::string& error);
// One result's tables.
std::string Tables(const Value& result);
// Two results' tables, before → after, after warnings for anything that makes them unlike.
std::string Compare(const Value& before, const Value& after);

}  // namespace kiteperf
