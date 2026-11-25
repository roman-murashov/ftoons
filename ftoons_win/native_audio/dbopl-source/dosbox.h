#pragma once
#include <cstdint>
#include <iosfwd>
#include <cstdio>
using Bitu=uintptr_t; using Bits=intptr_t;
#define INLINE inline
#define DB_FASTCALL
#define GCC_UNLIKELY(x) __builtin_expect(!!(x),0)
#define LOG_MSG(...) std::fprintf(stderr,__VA_ARGS__)
class MixerChannel {public: virtual void AddSamples_m32(Bitu,const int32_t*)=0; virtual void AddSamples_s32(Bitu,const int32_t*)=0;};
