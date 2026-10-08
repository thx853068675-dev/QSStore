#pragma once
#include <cstdint>
extern "C" {
struct OH_DisplaySoloist;
using OH_DisplaySoloist_FrameCallback = void (*)(long long, long long, void*);
struct DisplaySoloist_ExpectedRateRange { int32_t min, max, expected; };
OH_DisplaySoloist* OH_DisplaySoloist_Create(bool);
int32_t OH_DisplaySoloist_Destroy(OH_DisplaySoloist*);
int32_t OH_DisplaySoloist_Start(OH_DisplaySoloist*, OH_DisplaySoloist_FrameCallback, void*);
int32_t OH_DisplaySoloist_Stop(OH_DisplaySoloist*);
int32_t OH_DisplaySoloist_SetExpectedFrameRateRange(OH_DisplaySoloist*, DisplaySoloist_ExpectedRateRange*);
}
