# A tripwire: Chromium must never read Kite.exe's own command line as switches (shell/Chromium.cpp,
# command_line_args_disabled). Kite's parser refuses what CI could pass first, so this checks
# the setting itself is there.
file(READ "${SOURCE}" text)
string(FIND "${text}" "settings.command_line_args_disabled = true;" at)
if(at EQUAL -1)
  message(FATAL_ERROR "${SOURCE} doesn't set settings.command_line_args_disabled = true")
endif()
