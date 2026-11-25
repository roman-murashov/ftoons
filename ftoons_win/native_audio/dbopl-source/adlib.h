#pragma once
#include "dosbox.h"
namespace Adlib {class Handler {public:
virtual uint32_t WriteAddr(uint32_t,uint8_t)=0; virtual void WriteReg(uint32_t,uint8_t)=0;
virtual void Generate(MixerChannel*,Bitu)=0; virtual void Init(Bitu)=0;
virtual void SaveState(std::ostream&)=0; virtual void LoadState(std::istream&)=0;
virtual ~Handler(){};};}
