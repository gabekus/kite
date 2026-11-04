#pragma once
// One store's background thread: what core/SessionWriter.h (session.json) and
// core/HistoryStore.h (history.json) share. The UI thread hands work over and goes on at once;
// the thread does it in order and sleeps on a condition variable in between, so an idle Kite
// has no wakeups from it. Every wait is bounded: a disk that hangs can't hang Kite, and giving up
// is safe, since the stores' writes are atomic (core/StoreFile.h).
//
// The thread's state is shared with it (not owned by the WorkerThread), so a thread still busy
// when its owner goes is let go and finishes, or dies with the process, on its own: OnStuck's
// handler runs first, and the app ends the process there, so the C++ library is never torn
// down under the thread.

#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

namespace kite {

using Deadline = std::chrono::steady_clock::time_point;
// `timeout` from now; milliseconds::max() (or anything past the clock's end) is no deadline.
Deadline DeadlineAfter(std::chrono::milliseconds timeout);

// What a store's thread shares with its owner, all of it behind `mutex`. A store's state derives
// from it and says what's waiting (HasWork) and how one piece of it is done (RunOne).
struct WorkerState {
    virtual ~WorkerState() = default;

    std::mutex mutex;
    std::condition_variable wake;  // the thread: work, or stop
    std::condition_variable done;  // waiters: a piece of work ended, or the thread did
    bool busy = false;
    bool stop = false;
    bool ended = false;

    // Under the lock: whether something waits to be done.
    virtual bool HasWork() const = 0;
    // With `lock` held and HasWork(): takes one piece of the work, unlocks for the slow part, and
    // returns with the lock held again (after an exception the thread relocks).
    virtual void RunOne(std::unique_lock<std::mutex>& lock) = 0;
    // An exception left RunOne (out of memory, mostly), `what` its message or null; the lock is
    // held. Nothing may throw out of the thread (std::terminate), so this mustn't either, and
    // shouldn't allocate: reserve room for its message up front.
    virtual void Failed(const char* what) noexcept = 0;

    // Under the lock: nothing waits and nothing runs.
    bool Idle() const { return !busy && !HasWork(); }
    void Run();
};

class WorkerThread {
public:
    // How long Stop waits for a thread still busy before it lets it go.
    static constexpr std::chrono::milliseconds kStopWait{5000};

    WorkerThread() = default;  // no thread yet: idle, and Stop does nothing
    ~WorkerThread() { Stop(); }
    WorkerThread(const WorkerThread&) = delete;
    WorkerThread& operator=(const WorkerThread&) = delete;

    void Start(std::shared_ptr<WorkerState> state);
    bool Started() const { return state_ != nullptr; }

    // Until nothing waits or runs, or `deadline`; false then, and Stop won't wait again.
    bool WaitIdle(Deadline deadline);
    // Until `ready()` (checked under the lock, as each piece of work ends) or the thread ends,
    // or `deadline`; false on the deadline.
    template <class Ready>
    bool WaitUntil(Deadline deadline, Ready ready) {
        if (!state_) return ready();
        std::unique_lock lock(state_->mutex);
        const auto done = [&] { return ready() || state_->ended; };
        if (deadline == Deadline::max()) {
            state_->done.wait(lock, done);
            return true;
        }
        return state_->done.wait_until(lock, deadline, done);
    }
    // Whether the thread has something to do right now (after a wait timed out, whether it
    // really is stuck).
    bool Writing() const;
    // Runs when Stop has to let a busy thread go. Without one it's detached.
    void OnStuck(std::function<void()> stuck) { onStuck_ = std::move(stuck); }
    // Tells the thread to stop once it has done what's waiting, and waits for that, kStopWait at
    // most (none after a WaitIdle timed out: the caller has waited its bound). A thread with
    // nothing left counts as done, so the join can't hang.
    void Stop();

private:
    std::shared_ptr<WorkerState> state_;
    std::thread thread_;
    std::function<void()> onStuck_;
    bool timedOut_ = false;
};

}  // namespace kite
