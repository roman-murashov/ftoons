#include "dbopl.h"
#include <algorithm>
#include <new>
#include <cmath>
#include <vector>
bool adlib_pcm_boost=false; void adlib_boost32(int32_t*,unsigned int,unsigned int){}
namespace DBOPL {void InitTables(); void Handler::SaveState(std::ostream&){} void Handler::LoadState(std::istream&){} }
struct HostChip {
 DBOPL::Chip chip{true}; uint32_t rate,phase=0; int32_t previous=0,current=0; int64_t dc=0;
 bool loaded=false; bool correct_dc;
 std::vector<int32_t> raw; size_t raw_pos=0; uint32_t raw_rate=11025,raw_phase=0;
 int32_t raw_previous=0,raw_current=0,raw_lowpass=0,raw_alpha=0;
 HostChip(uint32_t r,bool d):rate(r),correct_dc(d){DBOPL::InitTables();chip.Setup(49716);}
 int32_t one(){int32_t value=0;chip.GenerateBlock2(1,&value);return value;}
 int32_t digital(){
  while(raw_phase>=rate){raw_phase-=rate;raw_previous=raw_current;raw_current=raw_pos<raw.size()?raw[raw_pos++]:0;}
  int32_t sample=raw_previous+static_cast<int32_t>((static_cast<int64_t>(raw_current-raw_previous)*raw_phase)/rate);
  raw_phase+=raw_rate;
  raw_lowpass=static_cast<int32_t>((static_cast<int64_t>(sample)*8192*raw_alpha+static_cast<int64_t>(raw_lowpass)*(65536-raw_alpha))>>16);
  return raw_lowpass;
 }
};
extern "C" {
__declspec(dllexport) void* chip_create(uint32_t rate,int correct_dc){if(rate<8000||rate>192000)return nullptr;return new(std::nothrow) HostChip(rate,correct_dc!=0);}
__declspec(dllexport) void chip_destroy(void* p){delete static_cast<HostChip*>(p);}
__declspec(dllexport) void chip_write(void* p,uint32_t reg,uint8_t value){static_cast<HostChip*>(p)->chip.WriteReg(reg,value);}
__declspec(dllexport) int chip_raw(void* p,const uint8_t* data,uint32_t source,uint32_t padded,uint32_t rate){
 if(!p||!data||!source||source>padded||padded>1048576||rate<4000||rate>48000)return 0;
 auto& h=*static_cast<HostChip*>(p);h.raw.assign(padded,0);
 for(uint32_t i=0;i<source;i++)h.raw[i]=(static_cast<int32_t>(data[i])-128)*256;
 h.raw_pos=0;h.raw_rate=rate;h.raw_phase=0;
 double interval=1.0/h.rate,tau=1.0/(static_cast<uint32_t>(rate/2)*2.0*3.14159265358979323846);
 h.raw_alpha=static_cast<int32_t>((interval/(tau+interval))*65536);return 1;
}
__declspec(dllexport) void chip_raw_stop(void* p){if(p){auto& h=*static_cast<HostChip*>(p);h.raw.clear();h.raw_pos=0;}}
__declspec(dllexport) int chip_render(void* p,int16_t* out,uint32_t frames){
 if(!p||!out||frames<1||frames>8192)return 0;auto& h=*static_cast<HostChip*>(p);
 if(!h.loaded){h.previous=h.one();h.current=h.one();h.loaded=true;}
 for(uint32_t i=0;i<frames;i++){
  while(h.phase>=h.rate){h.phase-=h.rate;h.previous=h.current;h.current=h.one();}
  int32_t sample=h.previous+static_cast<int32_t>((static_cast<int64_t>(h.current-h.previous)*h.phase)/h.rate);
  h.phase+=49716;
  int64_t value=static_cast<int64_t>(sample)*12288+h.digital();
  if(h.correct_dc){value+=h.dc;int64_t speed=(value>-(30000LL<<13)&&value<(30000LL<<13))?1:64;
   h.dc-=(value*((1<<24)/h.rate)*speed)>>24;}
  value>>=13;out[i]=static_cast<int16_t>(std::clamp<int64_t>(value,-32768,32767));
 }return 1;
}
}
