#pragma once
// One owner for a Win32 handle: closed once, when its owner goes, never copied. `Close` is
// the handle type's own closer (CloseHandle, WinHttpCloseHandle); a null handle isn't closed.

#include <windows.h>

#include <utility>

namespace kite {

template <typename T, auto Close>
class UniqueHandle {
public:
    UniqueHandle() = default;
    explicit UniqueHandle(T value) : value_(value) {}
    ~UniqueHandle() { Reset(); }
    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;
    UniqueHandle(UniqueHandle&& other) noexcept : value_(std::exchange(other.value_, T{})) {}
    UniqueHandle& operator=(UniqueHandle&& other) noexcept {
        if (this != &other) {
            Reset();
            value_ = std::exchange(other.value_, T{});
        }
        return *this;
    }

    T Get() const { return value_; }
    explicit operator bool() const { return value_ != T{}; }
    // For a function that writes a new handle into a pointer (OpenProcessToken): the old one
    // is closed first.
    T* Put() {
        Reset();
        return &value_;
    }
    void Reset(T value = T{}) {
        if (value_) Close(value_);
        value_ = value;
    }

private:
    T value_{};
};

// A kernel object's handle (CloseHandle). INVALID_HANDLE_VALUE isn't a handle here: callers
// that get it (CreateFile, CreateToolhelp32Snapshot) treat it as a failure, not keep it.
using KernelHandle = UniqueHandle<HANDLE, &CloseHandle>;

}  // namespace kite
