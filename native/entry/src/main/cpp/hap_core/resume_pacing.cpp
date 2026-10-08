#include <native_display_soloist/native_display_soloist.h>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace {
// Keep the launch's composition cadence stable for a bounded window. Callbacks
// stay native and do not invalidate ArkUI or dispatch work to its JS thread.
class ResumePacing {
 public:
  ~ResumePacing() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      closing_ = true;
      Stop();
      changed_.notify_all();
    }
    if (worker_.joinable()) worker_.join();
    if (soloist_) OH_DisplaySoloist_Destroy(soloist_);
  }

  bool Set(bool enabled) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!enabled) { Stop(); changed_.notify_all(); return true; }
    if (!soloist_) soloist_ = OH_DisplaySoloist_Create(false);
    if (!soloist_) return false;
    if (!worker_.joinable()) worker_ = std::thread([this] { Expire(); });
    DisplaySoloist_ExpectedRateRange range{60, 120, 120};
    if (OH_DisplaySoloist_SetExpectedFrameRateRange(soloist_, &range) != 0) return false;
    if (!running_ && OH_DisplaySoloist_Start(soloist_, OnFrame, nullptr) != 0) return false;
    running_ = true;
    deadline_ = std::chrono::steady_clock::now() + std::chrono::milliseconds(660);
    changed_.notify_all();
    return true;
  }

 private:
  static void OnFrame(long long, long long, void*) {}
  void Stop() {
    if (soloist_ && running_) OH_DisplaySoloist_Stop(soloist_);
    running_ = false;
  }
  void Expire() {
    std::unique_lock<std::mutex> lock(mutex_);
    while (!closing_) {
      if (!running_) { changed_.wait(lock); continue; }
      const auto due = deadline_;
      if (!changed_.wait_until(lock, due, [this, due] {
        return closing_ || !running_ || deadline_ != due;
      })) Stop();
    }
  }
  std::mutex mutex_;
  std::condition_variable changed_;
  std::thread worker_;
  OH_DisplaySoloist* soloist_ = nullptr;
  bool running_ = false;
  bool closing_ = false;
  std::chrono::steady_clock::time_point deadline_;
};
}

bool qingqi_set_resume_pacing(bool enabled) noexcept {
  try { static ResumePacing pacing; return pacing.Set(enabled); }
  catch (...) { return false; }
}
