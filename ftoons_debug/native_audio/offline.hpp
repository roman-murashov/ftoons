#pragma once
#include "synth.hpp"
#include <iomanip>
#include <iostream>
#include <sstream>
namespace ftoons {
namespace offline {
inline void save(const fs::path& path, const void* data,size_t size) {
    std::ofstream out(path,std::ios::binary);
    if(!out || !out.write(static_cast<const char*>(data),size) || !out.flush())
        throw std::runtime_error("Cannot write imported file "+path.filename().string());
}
inline void save_text(const fs::path& p,const std::string& s) {save(p,s.data(),s.size());}
inline std::string quote(const std::string& s) {
    std::ostringstream out; out<<'"';
    for(unsigned char c:s){
        if(c=='"' || c=='\\')out<<'\\'<<char(c);
        else if(c<32)out<<"\\u"<<std::hex<<std::setfill('0')<<std::setw(4)<<unsigned(c)<<std::dec;
        else out<<char(c);
    }
    out<<'"';return out.str();
}
inline std::string ints(const std::vector<int>& values) {
    std::ostringstream j; j<<'[';
    for(size_t i=0;i<values.size();++i){if(i)j<<',';j<<values[i];}
    j<<']';return j.str();
}
inline std::string rows(const std::vector<std::string>& records) {
    std::ostringstream j;j<<'[';
    for(size_t i=0;i<records.size();++i){if(i)j<<",\n";j<<records[i];}
    j<<']';return j.str();
}
inline Bytes samples(const std::vector<int16_t>& words) {
    const auto* base=reinterpret_cast<const uint8_t*>(words.data());
    return Bytes(base,base+words.size()*2); // Native target is little-endian Windows x64.
}
inline std::string name(const AudioSources& s,int id) {
    auto it=s.names.find(id);
    return it==s.names.end()?"null":quote(it->second);
}
inline std::string song(const fs::path& orig,const AudioSources& s,int id,const BankEntry& e) {
    Synth chip(s);
    require(chip.play(id),"DOS AdLib sequencer rejected a song");
    int duration=*std::max_element(e.ticks.begin(),e.ticks.end());
    const int frames=static_cast<int>(frames_at_tick(duration+1));
    const int64_t begin=e.loop_marker<0 ? 0 : frames_at_tick(e.loop_marker+1);
    Bytes pcm=samples(chip.render(frames));
    require(std::any_of(pcm.begin(),pcm.end(),[](auto x){return x!=0;}),"Silent DOS score");
    std::string leaf="music_"+std::to_string(id)+".pcm", hash=hash256(pcm);
    std::string path="res://assets/original/music_lossless/"+leaf;
    save(orig/"music_lossless"/leaf,pcm.data(),pcm.size());
    std::ostringstream j;
    j<<"{\"id\":"<<id<<",\"name\":"<<name(s,id)<<",\"frames\":"<<frames
     <<",\"loop_begin_frame\":"<<begin<<",\"loop_end_frame\":"<<frames
     <<",\"sample_rate_hz\":48000,\"lossless_bytes\":"<<pcm.size()
     <<",\"pcm_sha256\":"<<quote(hash)<<",\"pcm_path\":"<<quote(path)
     <<",\"asset_path\":"<<quote(path)<<",\"asset_sha256\":"<<quote(hash)<<'}';
    return j.str();
}
inline std::string effect(const fs::path& orig,const AudioSources& s,int id,const BankEntry& entry) {
    auto spans=tracks(entry.decoded);
    require(!spans.empty() && !entry.ticks.empty(),"Empty DOS synth effect");
    const auto offset=spans.front().first;
    const bool embedded=spans.size()==1 && u16(entry.decoded,offset)==0xfe;
    const bool loop=(entry.flags&2)!=0;
    int rate=48000; Bytes data;
    if(embedded) {
        rate=u16(entry.decoded,offset+2);
        auto len=u16(entry.decoded,offset+4);
        require(spans.front().second==len+10 && u16(entry.decoded,offset+6)==0 &&
                u16(entry.decoded,offset+8)==len,"Invalid DOS sample loop points");
        data=slice(entry.decoded,offset+10,len);
    } else {
        Synth chip(s);
        require(chip.play(id),"DOS AdLib sequencer rejected an effect");
        int ticks=*std::max_element(entry.ticks.begin(),entry.ticks.end());
        int phrase=loop?ticks*800:static_cast<int>(frames_at_tick(ticks+1));
        data=samples(chip.render(phrase));
        for(int i=0;!loop && i<20;++i) {
            auto tail=chip.render(4800);
            auto range=std::minmax_element(tail.begin(),tail.end());
            auto bytes=samples(tail);data.insert(data.end(),bytes.begin(),bytes.end());
            if(int(*range.second)-int(*range.first)<=8)break;
        }
        require(std::any_of(data.begin(),data.end(),[](auto x){return x!=0;}),"Silent synthesized effect");
    }
    std::ostringstream leaf;
    leaf<<"bank_"<<std::setfill('0')<<std::setw(2)<<id<<".pcm";
    save(orig/"synth_effects"/leaf.str(),data.data(),data.size());
    std::ostringstream j;
    j<<"{\"id\":"<<id<<",\"name\":"<<name(s,id)<<",\"resource\":"<<quote(leaf.str())
     <<",\"asset_path\":"<<quote("res://assets/original/synth_effects/"+leaf.str())
     <<",\"sample_rate_hz\":"<<rate<<",\"size_bytes\":"<<data.size()<<",\"frames\":"<<data.size()/(embedded?1:2)
     <<",\"channels\":1,\"encoding\":"<<quote(embedded?"unsigned_8":"signed_16_le")
     <<",\"loop\":"<<(loop?"true":"false")<<",\"loop_begin_frame\":0,\"track_ticks\":"<<ints(entry.ticks)<<'}';
    return j.str();
}
} // namespace offline
inline void import_audio(const fs::path& dos,const fs::path& project) {
    using namespace offline;
    auto s=load(dos,project);
    auto orig=project/"assets"/"original";
    for(auto sub:{"music_lossless","synth_effects","audio_driver"})fs::create_directories(orig/sub);
    save(orig/"audio_driver"/"TOONS.EXE",s.exe.data(),s.exe.size());
    save(orig/"audio_driver"/"ADL.DRV",s.driver.data(),s.driver.size());
    std::vector<std::string> raw,bank,music;
    for(auto& [id,bytes]:s.raw) {
        std::ostringstream j;
        j<<"{\"id\":"<<id<<",\"name\":"<<name(s,id)<<",\"resource\":\"SX_"<<id
         <<".RAW\",\"size_bytes\":"<<bytes.size()<<",\"sample_rate_hz\":11025}";
        raw.push_back(j.str());
    }
    for(auto& [id,entry]:s.bank) {
        if(id>=1000 && id<2000) {
            std::cout<<"Rendering DOS score "<<music.size()+1<<"/31"<<std::endl;
            music.push_back(song(orig,s,id,entry));
        } else if(!s.raw.count(id)) bank.push_back(effect(orig,s,id,entry));
    }
    require(raw.size()==132 && bank.size()==32 && music.size()==31,"Incomplete DOS audio catalog");
    save_text(orig/"sound_effect_index.json","{\"format\":\"sid_al_dos_sound_effect_index_v1\",\"samples\":"+rows(raw)+"}");
    save_text(orig/"synth_effect_index.json","{\"format\":\"sid_al_synth_effect_index_v1\",\"samples\":"+rows(bank)+"}");
    save_text(orig/"music_index.json","{\"format\":\"sid_al_music_index_v1\",\"complete\":true,\"profile\":\"Original ADL.DRV sequenced on local DBOPL\",\"songs\":"+rows(music)+",\"toonbox_playlist\":"+ints(s.playlist)+"}");
}
} // namespace ftoons
