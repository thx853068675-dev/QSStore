#include <native_display_soloist/native_display_soloist.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <thread>

struct OH_DisplaySoloist {};
static std::atomic<int> creates{0}, starts{0}, stops{0};
static bool rejectCreate = true, rejectRange = true, rejectStart = true;
static std::atomic<bool> active{false};
extern "C" OH_DisplaySoloist* OH_DisplaySoloist_Create(bool exclusive) {
  assert(!exclusive); creates++;
  return rejectCreate ? nullptr : new OH_DisplaySoloist();
}
extern "C" int32_t OH_DisplaySoloist_Destroy(OH_DisplaySoloist* p) { delete p; return 0; }
extern "C" int32_t OH_DisplaySoloist_SetExpectedFrameRateRange(OH_DisplaySoloist*, DisplaySoloist_ExpectedRateRange* r) {
  assert(r->min >= 0 && r->min < r->max && r->expected <= r->max && r->expected >= r->min);
  return rejectRange ? -1 : 0;
}
extern "C" int32_t OH_DisplaySoloist_Start(OH_DisplaySoloist*, OH_DisplaySoloist_FrameCallback cb, void* data) {
  if (rejectStart) return -1;
  starts++; active = true; cb(0,0,data); return 0;
}
extern "C" int32_t OH_DisplaySoloist_Stop(OH_DisplaySoloist*) { active = false; stops++; return 0; }
bool qingqi_set_resume_pacing(bool) noexcept;

int main() {
  using namespace std::chrono_literals;
  assert(qingqi_set_resume_pacing(false) && creates == 0);
  assert(!qingqi_set_resume_pacing(true)); rejectCreate = false;
  assert(!qingqi_set_resume_pacing(true)); rejectRange = false;
  assert(!qingqi_set_resume_pacing(true)); rejectStart = false;
  assert(qingqi_set_resume_pacing(true) && active && starts == 1);
  std::this_thread::sleep_for(480ms);
  assert(qingqi_set_resume_pacing(true) && starts == 1);
  std::this_thread::sleep_for(220ms);
  assert(active && stops == 0); // The old deadline must not end the extended lease.
  assert(qingqi_set_resume_pacing(false) && !active && stops == 1);
  assert(qingqi_set_resume_pacing(true) && starts == 2);
  auto deadline = std::chrono::steady_clock::now() + 1500ms;
  while (active && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(10ms);
  assert(!active && stops == 2);
  assert(qingqi_set_resume_pacing(false) && stops == 2);
  for (int i=0;i<30;++i) {
    assert(qingqi_set_resume_pacing(true));
    assert(qingqi_set_resume_pacing(false) && !active);
  }
  assert(creates == 2); // One failed creation; one reused object for all successful leases.
}
