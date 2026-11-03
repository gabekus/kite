#pragma once
// UUIDs in the Mac's text form. Foundation's UUID parses either case and writes uppercase, so
// ids are normalized to uppercase when read and compared as strings after that.

#include <optional>
#include <string>

namespace kite {

// A random (version 4) UUID in the Mac's form: uppercase, hyphenated, as Foundation's UUID encodes it.
std::string NewUuid();

// True for "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" with hex digits, either case.
bool IsUuid(const std::string& text);

// The uppercase form of a valid UUID, or nullopt (as UUID(uuidString:) returns nil).
std::optional<std::string> NormalizeUuid(const std::string& text);

}  // namespace kite
