#pragma once
// Reads an XML property list (Apple's plist 1.0) into a JSON value: dict → object, array,
// string, integer and real → number, true/false, and date and data as their text. Import from
// Arc needs it for Arc for Windows' settings, which Swift's Foundation keeps as an XML plist
// (company.thebrowser.arc.plist) where the Mac has its defaults. Binary plists aren't read.

#include <optional>
#include <string_view>

#include "core/Json.h"

namespace kite::plist {

// nullopt when the text isn't an XML plist this can read.
std::optional<json::Value> ParseXml(std::string_view text);

}  // namespace kite::plist
