#pragma once
#include "bank.hpp"
#include <windows.h>
#include <array>
#include <algorithm>
#include <cstring>
#include <initializer_list>
#include <stdexcept>

namespace ftoons {
// Windows x64 Unicorn and DOSBox-X DBOPL C interfaces. Only the hash-bound
// sound sequencer and AdLib driver from the selected game run in this VM.
class DecoderLibrary {
    HMODULE module;
public:
    explicit DecoderLibrary(const wchar_t* name) {
        wchar_t filename[32768];
        DWORD n = GetModuleFileNameW(nullptr,filename,32768);
        if (!n || n >= 32768) throw std::runtime_error("Cannot locate decoder DLL directory");
        auto path = std::filesystem::path(filename).parent_path() / name;
        module = LoadLibraryExW(path.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) throw std::runtime_error("Missing decoder DLL: " + path.filename().string());
    }
    template<class T> T symbol(const char* name) {
        auto fn = GetProcAddress(module,name);
        if (!fn) throw std::runtime_error(std::string("Decoder DLL missing entry ") + name);
        return reinterpret_cast<T>(fn);
    }
    ~DecoderLibrary() {FreeLibrary(module);}
};
struct AudioAPI {
    DecoderLibrary u{L"unicorn.dll"}, d{L"toons_dbopl.dll"};
    #define BIND(lib, name, type) decltype(lib.symbol<type>(#name)) name = lib.symbol<type>(#name)
    BIND(u, uc_open, int(*)(int,int,void**));
    BIND(u, uc_close, int(*)(void*));
    BIND(u, uc_mem_map, int(*)(void*,uint64_t,size_t,uint32_t));
    BIND(u, uc_mem_read, int(*)(void*,uint64_t,void*,size_t));
    BIND(u, uc_mem_write, int(*)(void*,uint64_t,const void*,size_t));
    BIND(u, uc_hook_add, int(*)(void*,size_t*,int,void*,void*,uint64_t,uint64_t,...));
    BIND(u, uc_reg_read, int(*)(void*,int,void*));
    BIND(u, uc_reg_write, int(*)(void*,int,const void*));
    BIND(u, uc_emu_start, int(*)(void*,uint64_t,uint64_t,uint64_t,size_t));
    BIND(d, chip_create, void*(*)(uint32_t,int));
    BIND(d, chip_destroy, void(*)(void*));
    BIND(d, chip_write, void(*)(void*,uint32_t,uint8_t));
    BIND(d, chip_render, int(*)(void*,int16_t*,uint32_t));
    BIND(d, chip_raw, int(*)(void*,const uint8_t*,uint32_t,uint32_t,uint32_t));
    BIND(d, chip_raw_stop, void(*)(void*));
    #undef BIND
};

inline AudioAPI& decoder_api() {static AudioAPI api; return api;}
inline int64_t frames_at_tick(int64_t tick) {return (tick*5041*4*48000+1193181)/1193182;}
class Synth {
    AudioAPI& api = decoder_api();
    const AudioSources& source;
    void *cpu = nullptr, *chip = nullptr;
    std::map<int,uint32_t> resources;
    std::map<int,int> slots;
    int64_t irq=0, frames=0, raw_end=0;
    int raw_id=-1, music_resource=-1;
    uint32_t allocation=0xb0000, reg=0;
    bool bad_port=false;
    static void check(int result) {if (result) throw std::runtime_error("DOS audio VM error " + std::to_string(result));}
    static uint16_t word(const Bytes& b, size_t at) {return uint16_t(b.at(at)) | (uint16_t(b.at(at+1)) << 8);}
    static bool music(int id) {return id >= 1000 && id < 2000;}
    static uint32_t in_port(void*,uint32_t,int,void*) {return 0;}
    static void out_port(void*,uint32_t port,int,uint32_t value,void* ctx) {
        Synth& self=*static_cast<Synth*>(ctx);
        if (port==0x388) self.reg=value;
        else if(port==0x389) self.api.chip_write(self.chip,self.reg,uint8_t(value));
        else self.bad_port=true;
    }
    void put(uint32_t address,const void* data,size_t size) {check(api.uc_mem_write(cpu,address,data,size));}
    void put_word(uint32_t address,uint16_t value) {put(address,&value,2);}
    uint16_t call(uint16_t offset,std::initializer_list<uint16_t> args={}) {
        std::vector<uint16_t> stack{0,0x60};
        stack.insert(stack.end(),args.begin(),args.end());
        put(0x7ff00,stack.data(),stack.size()*2);
        const std::array<std::pair<int,uint16_t>,6> regs{{{49,0x7000},{47,0xff00},{6,0},{17,0x567f},{11,0x3bea},{34,offset}}};
        for(auto [id,value]:regs) check(api.uc_reg_write(cpu,id,&value));
        check(api.uc_emu_start(cpu,0x3bea0+offset,0x600,0,2000000));
        uint16_t cs=0, ax=0;
        check(api.uc_reg_read(cpu,11,&cs));
        if(cs!=0x60 || bad_port) throw std::runtime_error("DOS audio routine exceeded its execution bounds");
        check(api.uc_reg_read(cpu,3,&ax));
        return ax;
    }
    void retire() {
        if(raw_id>=0 && frames>=raw_end) raw_id=-1;
        for(auto it=slots.begin();it!=slots.end();) {
            uint8_t state;
            check(api.uc_mem_read(cpu,((0x9000+it->second*0x20)<<4)+0x158,&state,1));
            if(state==0xff) it=slots.erase(it); else ++it;
        }
    }
public:
    explicit Synth(const AudioSources& src): source(src) {
        check(api.uc_open(4,2,&cpu));
        try {
            chip=api.chip_create(48000,1);
            if(!chip) throw std::runtime_error("Cannot initialize DBOPL");
            check(api.uc_mem_map(cpu,0,0x100000,7));
            auto& exe=source.exe;
            size_t header=word(exe,8)*16, pages=word(exe,4), last=word(exe,2);
            size_t end=last?(pages-1)*512+last:pages*512;
            if(header>end || end>exe.size()) throw std::runtime_error("Invalid DOS audio executable");
            Bytes image(exe.begin()+header,exe.begin()+end);
            for(unsigned i=0;i<word(exe,6);++i) {
                size_t p=word(exe,0x18)+i*4, loc=word(exe,p+2)*16+word(exe,p);
                uint16_t value=word(image,loc)+0x1000;
                image[loc]=value & 255; image[loc+1]=value>>8;
            }
            put(0x10000,image.data(),image.size());
            size_t handle;
            check(api.uc_hook_add(cpu,&handle,2,reinterpret_cast<void*>(&out_port),this,1,0,500));
            check(api.uc_hook_add(cpu,&handle,2,reinterpret_cast<void*>(&in_port),this,1,0,218));
            put(0x80000,src.driver.data(),src.driver.size());
            put(0x84000,src.patch.data(),src.patch.size());
            call(0x22c7,{0,0x8000}); call(0x22da,{2,0x8400});
        } catch(...) { if(chip)api.chip_destroy(chip);api.uc_close(cpu);throw; }
    }
    ~Synth() {api.chip_destroy(chip);api.uc_close(cpu);}
    bool play(int id,bool retrigger=false) {
        retire();
        if(source.raw.count(id)) {
            if(raw_id==id && !retrigger) return true;
            auto& data=source.raw.at(id); uint32_t length=static_cast<uint32_t>(data.size())&~3u;
            uint32_t padded=length<=5120?length:((length+5119)/5120)*5120;
            if(!api.chip_raw(chip,data.data(),length,padded,11025)) return false;
            raw_id=id; raw_end=frames+(uint64_t(padded)*48000+11024)/11025;return true;
        }
        if(!source.bank.count(id)) return false;
        if(slots.count(id)) {if(!retrigger) return true;stop(id);}
        bool song=music(id);
        if(song){ auto prev=slots;for(auto item:prev)if(music(item.first))stop(item.first); }
        auto& entry=source.bank.at(id);auto& bytes=entry.decoded;
        if(!resources.count(id)) {
            uint32_t addr=song?0xa0000:allocation;
            if(song){if(bytes.size()>65536)throw std::runtime_error("Song exceeds 64K");resources.erase(music_resource);music_resource=id;}
            else {allocation=uint32_t((addr+bytes.size()+15)&~size_t(15));if(allocation>=0xf0000)throw std::runtime_error("Effect bank exceeded VM bounds");}
            put(addr,bytes.data(),bytes.size());resources[id]=addr;
        }
        int slot=song?0:1;
        while(slot<(song?1:8) && std::any_of(slots.begin(),slots.end(),[&](auto p){return p.second==slot;}))++slot;
        if(slot>=(song?1:8))return false;
        uint16_t seg=0x9000+slot*0x20, ptr_seg=resources[id]>>4;
        uint32_t ptr=uint32_t(seg)<<4; slots[id]=slot;
        uint8_t zero[0x17a]{};put(ptr,zero,sizeof(zero));
        put_word(ptr+0x168,ptr_seg);put_word(ptr+0x16a,bytes.at(1)+2);put_word(ptr+0x16c,ptr_seg);
        put_word(ptr+8,0x16a);put_word(ptr+10,seg);
        uint8_t priority[]{uint8_t(song?127:1),uint8_t(!!(entry.flags&2)),127};put(ptr+0x15c,priority,3);
        return call(0x22f1,{0,seg,uint16_t(song)})!=0;
    }
    void stop_raw(){api.chip_raw_stop(chip);raw_id=-1;}
    void stop(int id){
        if(id<0){auto prev=slots;for(auto p:prev) stop(p.first);stop_raw();return;}
        if(id==raw_id){stop_raw();return;}
        auto it=slots.find(id);if(it==slots.end())return;
        auto seg=uint16_t(0x9000+it->second*0x20);slots.erase(it);call(0x2365,{0,seg});
    }
    void stop_effects(){auto prev=slots;for(auto p:prev)if(!music(p.first))stop(p.first);}
    void music_volume(int value){for(auto p:slots)if(music(p.first))call(0x2336,{0,uint16_t(0x9000+p.second*0x20),uint16_t(std::clamp(value,0,127))});}
    std::vector<int16_t> render(int count) {
        if(count<0)throw std::runtime_error("Invalid PCM length");
        std::vector<int16_t> pcm(count);int done=0;
        while(done<count) {
            auto next=frames_at_tick(irq+1);
            int n=static_cast<int>(std::min<int64_t>(std::min(512,count-done),next-frames));
            if(n>0) {
                if(!api.chip_render(chip,pcm.data()+done,n))throw std::runtime_error("DBOPL render failed");
                done+=n;frames+=n;
            }
            if(frames==next){call(0x1938);++irq;}
        }
        retire();return pcm;
    }
};
}
