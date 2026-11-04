// The store's background thread (core/BackgroundWorker.h) that the session's writer and history
// share: W11's thread tests (SessionSaveTests' aFlushIsBounded,
// aWorkerStillWritingAtTheEndIsHandedToOnStuck, aWriteThatFinishedAfterATimedOutFlushIsNotStuck)
// on the base itself, plus its exception path and WaitUntil's bound.

#include <atomic>
#include <chrono>
#include <deque>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>

#include "Check.h"
#include "core/BackgroundWorker.h"

using namespace kite;

namespace {

// A queue of jobs, as history's worker is.
struct Jobs : WorkerState {
    std::deque<std::function<void()>> jobs;
    int done = 0;
    std::string failure;

    bool HasWork() const override { return !jobs.empty(); }
    void RunOne(std::unique_lock<std::mutex>& lock) override {
        auto job = std::move(jobs.front());
        jobs.pop_front();
        lock.unlock();
        job();
        lock.lock();
        ++done;
    }
    void Failed(const char* what) noexcept override { failure = what ? what : "?"; }

    void Post(std::function<void()> job) {
        {
            std::lock_guard lock(mutex);
            jobs.push_back(std::move(job));
        }
        wake.notify_one();
    }
};

// A job that waits for its gate, as a write to a hung disk does.
std::function<void()> Gated(std::shared_ptr<std::atomic<bool>> gate) {
    return [gate] {
        while (!*gate) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    };
}

void WaitUntilIdle(const WorkerThread& thread) {
    for (int i = 0; i < 500 && thread.Writing(); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
}

}  // namespace

TEST(aWaitIsBounded) {
    auto jobs = std::make_shared<Jobs>();
    WorkerThread thread;
    // No thread yet: idle at once.
    CHECK(thread.WaitIdle(DeadlineAfter(std::chrono::milliseconds(0))));
    thread.Start(jobs);
    CHECK(thread.WaitIdle(DeadlineAfter(std::chrono::milliseconds(0))));
    jobs->Post([] {});
    CHECK(thread.WaitIdle(DeadlineAfter(std::chrono::milliseconds(5000))));
    CHECK(jobs->done == 1);
    CHECK(!thread.Writing());
    // A deadline that never comes.
    jobs->Post([] {});
    CHECK(thread.WaitIdle(Deadline::max()));
    CHECK(DeadlineAfter(std::chrono::milliseconds::max()) == Deadline::max());
}

TEST(aThreadStillBusyAtTheEndIsHandedToOnStuck) {
    auto jobs = std::make_shared<Jobs>();
    auto gate = std::make_shared<std::atomic<bool>>(false);
    auto stuck = std::make_shared<std::atomic<int>>(0);
    {
        WorkerThread thread;
        thread.Start(jobs);
        thread.OnStuck([stuck] { ++*stuck; });
        jobs->Post(Gated(gate));
        CHECK(!thread.WaitIdle(DeadlineAfter(std::chrono::milliseconds(50))));
        CHECK(thread.Writing());
        // Stop doesn't wait again after the timed-out wait: OnStuck runs at once.
    }
    CHECK(*stuck == 1);
    // The thread let go finishes on its own, with its own reference to the state.
    *gate = true;
    for (int i = 0; i < 500; ++i) {
        {
            std::lock_guard lock(jobs->mutex);
            if (jobs->ended) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    std::lock_guard lock(jobs->mutex);
    CHECK(jobs->ended && jobs->done == 1);
}

// A wait that timed out just short of the job's end: once the thread has nothing left, Stop joins
// it, and OnStuck (which ends the app's process) doesn't run.
TEST(aJobThatFinishedAfterATimedOutWaitIsNotStuck) {
    auto jobs = std::make_shared<Jobs>();
    auto gate = std::make_shared<std::atomic<bool>>(false);
    auto stuck = std::make_shared<std::atomic<int>>(0);
    {
        WorkerThread thread;
        thread.Start(jobs);
        thread.OnStuck([stuck] { ++*stuck; });
        jobs->Post(Gated(gate));
        CHECK(!thread.WaitIdle(DeadlineAfter(std::chrono::milliseconds(50))));
        *gate = true;
        WaitUntilIdle(thread);
        CHECK(!thread.Writing());
    }
    CHECK(*stuck == 0);
    CHECK(jobs->ended);
}

TEST(stopDoesWhatsQueuedFirst) {
    auto jobs = std::make_shared<Jobs>();
    auto ran = std::make_shared<std::atomic<int>>(0);
    {
        WorkerThread thread;
        thread.Start(jobs);
        for (int i = 0; i < 20; ++i) jobs->Post([ran] { ++*ran; });
    }
    CHECK(*ran == 20 && jobs->ended);
}

TEST(aJobThatThrowsIsReportedAndTheThreadGoesOn) {
    auto jobs = std::make_shared<Jobs>();
    WorkerThread thread;
    thread.Start(jobs);
    jobs->Post([] { throw std::runtime_error("disk on fire"); });
    jobs->Post([] {});
    CHECK(thread.WaitIdle(DeadlineAfter(std::chrono::seconds(5))));
    std::lock_guard lock(jobs->mutex);
    CHECK(jobs->failure == "disk on fire");
    CHECK(jobs->done == 1);  // the second job; the first never counted
    CHECK(!jobs->busy);
}

TEST(waitUntilIsBounded) {
    auto jobs = std::make_shared<Jobs>();
    auto gate = std::make_shared<std::atomic<bool>>(false);
    WorkerThread thread;
    thread.Start(jobs);
    jobs->Post(Gated(gate));
    jobs->Post([] {});
    // Checked as each job ends: not before the gate opens.
    CHECK(!thread.WaitUntil(DeadlineAfter(std::chrono::milliseconds(30)), [&] { return jobs->done == 2; }));
    *gate = true;
    CHECK(thread.WaitUntil(DeadlineAfter(std::chrono::seconds(5)), [&] { return jobs->done == 2; }));
    // Without a thread the condition is all there is.
    WorkerThread none;
    CHECK(none.WaitUntil(DeadlineAfter(std::chrono::milliseconds(0)), [] { return true; }));
    CHECK(!none.WaitUntil(DeadlineAfter(std::chrono::milliseconds(0)), [] { return false; }));
}
