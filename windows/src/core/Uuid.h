#pragma once
#include <string>

namespace kite {

// A random (version 4) UUID in the Mac's form: uppercase, hyphenated, as Foundation's UUID encodes it.
std::string NewUuid();

// True for "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" with hex digits, either case.
bool IsUuid(const std::string& text);

}  // namespace kite
