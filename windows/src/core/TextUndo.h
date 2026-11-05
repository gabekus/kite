#pragma once
// Undo and redo for one of Kite's text fields, as the Mac's field editor (NSTextView) groups
// them: a run of typing (characters, Backspace and Delete) is one undo, until the caret is moved
// some other way; a paste, a cut or a word deleted at once is one of its own. Undo puts back the
// text and the selection from before the group; a new edit after an undo drops what could have
// been redone. Kept to the last kLimit groups. `State` is the field's text and selection
// (shell/TextField keeps UTF-16 with its caret and anchor), so this stays standard C++ for the
// tests.

#include <cstddef>
#include <optional>
#include <utility>
#include <vector>

namespace kite {

template <typename State>
class TextUndo {
public:
    static constexpr size_t kLimit = 100;

    // How an edit groups with the one before it.
    enum class Kind { Typing, Other };

    // `before` was the field before an edit of `kind` that changed its text.
    void Record(const State& before, Kind kind) {
        redo_.clear();
        if (kind == Kind::Typing && typing_ && !undo_.empty()) return;  // the run's first state is kept
        undo_.push_back(before);
        if (undo_.size() > kLimit) undo_.erase(undo_.begin());
        typing_ = kind == Kind::Typing;
    }
    // The caret moved, or the field lost the keyboard: the next keystroke starts a new group.
    void BreakTyping() { typing_ = false; }

    bool CanUndo() const { return !undo_.empty(); }
    bool CanRedo() const { return !redo_.empty(); }
    // The state to go back to, given the field's `current` (kept for redo); none with nothing to undo.
    std::optional<State> Undo(const State& current) {
        if (undo_.empty()) return std::nullopt;
        State back = std::move(undo_.back());
        undo_.pop_back();
        redo_.push_back(current);
        typing_ = false;
        return back;
    }
    std::optional<State> Redo(const State& current) {
        if (redo_.empty()) return std::nullopt;
        State forward = std::move(redo_.back());
        redo_.pop_back();
        undo_.push_back(current);
        typing_ = false;
        return forward;
    }
    // A new text from outside (the field opened, or its text was set): nothing to undo.
    void Reset() {
        undo_.clear();
        redo_.clear();
        typing_ = false;
    }

private:
    std::vector<State> undo_, redo_;
    bool typing_ = false;
};

}  // namespace kite
