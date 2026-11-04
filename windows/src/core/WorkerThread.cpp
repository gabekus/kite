// See WorkerThread.h.

#include "core/WorkerThread.h"

#include <exception>

namespace kite {

Deadline DeadlineAfter(std::chrono::milliseconds timeout) {
    const auto now = std::chrono::steady_clock::now();
    if (timeout == std::chrono::milliseconds::max() || timeout > std::chrono::duration_cast<std::chrono::milliseconds>(Deadline::max() - now)) {
        return Deadline::max();
    }
    return now + timeout;
}

void WorkerState::Run() {
    std::unique_lock lock(mutex);
    for (;;) {
        wake.wait(lock, [this] { return stop || HasWork(); });
        if (!HasWork()) break;  // stopping, with nothing left to do
        busy = true;
        try {
            RunOne(lock);
        } catch (const std::exception& e) {
            if (!lock.owns_lock()) lock.lock();
            Failed(e.what());
        } catch (...) {
            if (!lock.owns_lock()) lock.lock();
            Failed(nullptr);
        }
        busy = false;
        done.notify_all();
    }
    ended = true;
    done.notify_all();
}

void WorkerThread::Start(std::shared_ptr<WorkerState> state) {
    if (state_) return;
    state_ = std::move(state);
    thread_ = std::thread([state = state_] { state->Run(); });
}

bool WorkerThread::WaitIdle(Deadline deadline) {
    if (!state_) return true;
    std::unique_lock lock(state_->mutex);
    const auto idle = [this] { return state_->Idle() || state_->ended; };
    if (deadline == Deadline::max()) {
        state_->done.wait(lock, idle);
        return true;
    }
    if (state_->done.wait_until(lock, deadline, idle)) return true;
    timedOut_ = true;
    return false;
}

bool WorkerThread::Writing() const {
    if (!state_) return false;
    std::lock_guard lock(state_->mutex);
    return !state_->Idle() && !state_->ended;
}

void WorkerThread::Stop() {
    if (!thread_.joinable()) return;
    std::unique_lock lock(state_->mutex);
    state_->stop = true;
    state_->wake.notify_one();
    const auto wait = timedOut_ ? std::chrono::milliseconds(0) : kStopWait;
    const bool ended = state_->done.wait_for(lock, wait, [this] { return state_->ended || state_->Idle(); });
    lock.unlock();
    if (ended) {
        thread_.join();
        return;
    }
    // Still busy: the thread holds its own reference to the state, so it may go on, but the
    // process mustn't tear down its library under it. The app ends the process here.
    if (onStuck_) onStuck_();
    thread_.detach();
}

}  // namespace kite
