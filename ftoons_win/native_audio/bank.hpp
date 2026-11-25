#pragma once
// Original audio-bank and instrument formats. Only the verified retail release
// is compatible with the original sequencer's code addresses and data tables.
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace ftoons {
using Bytes = std::vector<uint8_t>;
namespace fs = std::filesystem;

struct BankEntry {
    int flags = 0;
    Bytes decoded;
    std::vector<int> ticks;
    int loop_marker = -1;
};
struct AudioSources {
    Bytes exe, driver, patch;
    std::map<int,BankEntry> bank;
    std::map<int,Bytes> raw;
    std::map<int,std::string> names;
    std::vector<int> playlist;
};
inline void require(bool value, const char *reason) {
    if (!value) throw std::runtime_error(reason);
}
inline unsigned u16(const Bytes& d, size_t o) {
    return unsigned(d.at(o)) | (unsigned(d.at(o+1))<<8);
}
inline uint32_t u32(const Bytes& d, size_t o) {
    return u16(d,o) | (uint32_t(u16(d,o+2))<<16);
}
inline Bytes slice(const Bytes& d, size_t o, size_t n) {
    require(o <= d.size() && n <= d.size()-o,"Truncated audio resource");
    return Bytes(d.begin()+o, d.begin()+o+n);
}
inline Bytes read_file(const fs::path& p) {
    std::ifstream f(p,std::ios::binary|std::ios::ate);
    require(bool(f),"Missing DOS audio source file");
    auto size=f.tellg();
    require(size>=0 && size<=32*1024*1024,"Unexpected DOS audio source size");
    Bytes d(static_cast<size_t>(size));
    f.seekg(0);
    f.read(reinterpret_cast<char*>(d.data()),size);
    require(bool(f),"Cannot read DOS audio file");
    return d;
}
inline std::string hash256(const Bytes& data) {
    BCRYPT_ALG_HANDLE alg=nullptr;
    require(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0,"SHA256 provider unavailable");
    BYTE digest[32];
    auto status=BCryptHash(alg,nullptr,0,const_cast<BYTE*>(data.data()),
                           static_cast<ULONG>(data.size()),digest,sizeof(digest));
    BCryptCloseAlgorithmProvider(alg,0);
    require(status>=0,"SHA256 computation failed");
    const char alphabet[]="0123456789abcdef";
    std::string out;
    for (BYTE b:digest) {out+=alphabet[b>>4];out+=alphabet[b&15];}
    return out;
}
inline Bytes verified(const fs::path& p,const char *expected) {
    auto d=read_file(p);
    if(hash256(d)!=expected) throw std::runtime_error("Unsupported DOS revision of "+p.filename().string());
    return d;
}
struct Bits {
    const Bytes& bytes;
    size_t bit=0;
    unsigned read(unsigned n,bool little) {
        require(n<=16 && bit+n<=bytes.size()*8,"Truncated compressed bit stream");
        unsigned value=0;
        for(unsigned i=0;i<n;++i,++bit) {
            unsigned shift=bit%8;
            if(little) value|=((bytes[bit/8]>>shift)&1u)<<i;
            else value=(value<<1)|((bytes[bit/8]>>(7-shift))&1u);
        }
        return value;
    }
};
inline Bytes unpack_lzw(const Bytes& data,size_t expected) {
    std::vector<Bytes> dict;
    auto reset=[&]() {
        dict.clear();
        for(int i=0;i<256;++i)dict.push_back(Bytes{static_cast<uint8_t>(i)});
        dict.emplace_back();
    };
    reset();
    unsigned width=9, code_count=0;
    Bits input{data};
    Bytes old,out;
    while(out.size()<expected) {
        unsigned code=input.read(width,true);
        ++code_count;
        if(code==256) {
            while(code_count%8) {input.read(width,true);++code_count;}
            reset();width=9;old.clear(); continue;
        }
        Bytes entry;
        if(code<dict.size()) entry=dict[code];
        else {
            require(!old.empty() && code==dict.size(),"Invalid AdLib LZW code");
            entry=old;entry.push_back(old.front());
        }
        require(!entry.empty(),"Empty code in AdLib patch");
        out.insert(out.end(),entry.begin(),entry.end());
        if(!old.empty()) {
            old.push_back(entry.front());dict.push_back(std::move(old));
            if(width<12 && dict.size()>=(1u<<width))++width;
        }
        old=std::move(entry);
    }
    out.resize(expected);
    return out;
}
inline Bytes instrument_patch(const Bytes& overlay) {
    for(size_t pos=8;pos+8<=overlay.size();) {
        size_t length=u32(overlay,pos+4);
        if(std::equal(overlay.begin()+pos,overlay.begin()+pos+4,"003:")) {
            require(length>=5 && overlay.at(pos+8)==2,"Unsupported AdLib patch format");
            return unpack_lzw(slice(overlay,pos+13,length-5),u32(overlay,pos+9));
        }
        pos+=8+length;
    }
    throw std::runtime_error("Missing original AdLib patch");
}
inline Bytes unpack_lzh(const Bytes& data,size_t expected,const Bytes& exe,size_t codes,size_t lengths) {
    constexpr int count=314,total=627,root=626;
    int freq[total+1]={},child[total]={},parent[total+count]={};
    for(int i=0;i<count;++i){freq[i]=1;child[i]=i+total;parent[i+total]=i;}
    freq[total]=65535;
    for(int i=count,j=0;i<total;++i,j+=2) {
        freq[i]=freq[j]+freq[j+1]; child[i]=j; parent[j]=parent[j+1]=i;
    }
    std::array<uint8_t,4096> ring;
    ring.fill(' ');
    unsigned cursor=4036;
    Bits input{data};
    Bytes out;
    out.reserve(expected);
    auto emit=[&](unsigned v) {
        out.push_back(static_cast<uint8_t>(v)); ring[cursor]=static_cast<uint8_t>(v); cursor=(cursor+1)&4095;
    };
    while(out.size()<expected) {
        int c=child[root];
        while(c<total)c=child[c+input.read(1,false)];
        int symbol=c-total;
        require(freq[root]<32768,"LZH tree exceeds supported DOS bank");
        c=parent[c];
        do {
            int k=++freq[c],other=c+1;
            if (k>freq[other]) {
                while(k>freq[other+1])++other;
                std::swap(freq[c],freq[other]);
                int a=child[c],b=child[other];
                parent[a]=other;if(a<total)parent[a+1]=other;
                parent[b]=c;if(b<total)parent[b+1]=c;
                std::swap(child[c],child[other]);c=other;
            }
            c=parent[c];
        } while(c);
        if(symbol<256)emit(symbol);
        else {
            unsigned first=input.read(8,false),extra=exe.at(lengths+first)-2;
            unsigned distance=(exe.at(codes+first)<<6)|(((first<<extra)|input.read(extra,false))&63);
            unsigned start=(cursor-distance-1)&4095;
            for(int i=0;i<symbol-253;++i)emit(ring[(start+i)&4095]);
        }
    }
    require(out.size()==expected,"Bad LZH output length");
    return out;
}
inline std::vector<std::pair<size_t,size_t>> tracks(const Bytes& d) {
    require(u16(d,0)==0x84,"Unsupported track table");
    size_t pos=2;
    while(d.at(pos)!=255) {
        int type=d.at(pos++);
        std::vector<std::pair<size_t,size_t>> spans;
        while(d.at(pos)!=255) {
            size_t offset=u16(d,pos+2)+2, size=u16(d,pos+4);
            require(offset+size<=d.size(),"Invalid track extent");
            spans.emplace_back(offset,size); pos+=6;
        }
        ++pos;
        if(type==0)return spans;
    }
    throw std::runtime_error("Missing device zero track table");
}
inline void timing(BankEntry& song) {
    const auto& d=song.decoded;
    for(auto [o,len]:tracks(d)) {
        if(u16(d,o)==0xfe) {
            unsigned rate=u16(d,o+2), count=u16(d,o+4);
            require(rate && count+10==len,"Invalid embedded sample");
            song.ticks.push_back((count*60+rate-1)/rate);
            continue;
        }
        int tick=0,status=-1;
        size_t end=o+len, pos=o+2;
        while(true) {
            require(pos<end,"Missing track terminator");
            while(d.at(pos)==0xf8) {tick+=240;++pos;}
            tick+=d.at(pos++);
            if(d.at(pos)&128)status=d.at(pos++);
            if(status==0xfc)break;
            require(status>=0x80 && status<0xf0,"Unsupported DOS MIDI command");
            unsigned args=(status>>4==12 || status>>4==13)?1:2;
            if(status==0xcf && d.at(pos)==127)song.loop_marker=tick;
            pos+=args;
        }
        song.ticks.push_back(tick);
    }
}
inline AudioSources load(const fs::path& dos,const fs::path& stage) {
    const auto payloads=stage/"assets"/"original"/"payloads";
    AudioSources s;
    s.exe=verified(dos/"TOONS.EXE","cc37575f7bf1f36ac1b2083f82095930fc2d132881f9b619de46452210c30fc1");
    s.driver=verified(dos/"ADL.DRV","f1d093291b4395e485e9d19cb6684ffecf3c5dab31f2462264bf6fd4f15907af");
    auto packed=verified(payloads/"TOONS.SX.bin","c86bbab024e3d16d2775e42eeb1cc0b42546da3afad424f2f880ec5422c498d2");
    s.patch=instrument_patch(verified(payloads/"SX.OVL.bin","9105ac13ca9163ac4ec7589651961945fb9a4260f421a69aaa17269cc03f7b7f"));
    const size_t ds=u16(s.exe,8)*16+0x467f0;
    for(size_t i=0;i<31;++i)s.playlist.push_back(u16(s.exe,ds+0x5e4+i*2));
    const size_t count=u16(packed,18);
    size_t last=0;
    for(size_t i=0;i<count;++i) {
        const size_t row=21+6*i;
        unsigned id=u16(packed,row);
        size_t offset=u32(packed,row+2),size=u32(packed,offset+4);
        const size_t p=offset+8;
        require(size>=9 && packed.at(p+4)==3,"Incorrect DOS bank compression code");
        BankEntry e;
        e.flags=packed.at(p+3);
        e.decoded=unpack_lzh(slice(packed,p+9,size-9),u32(packed,p+5),s.exe,ds+0x2657,ds+0x2757);
        timing(e);
        s.bank.emplace(id,std::move(e));
        last=p+size;
    }
    for(size_t pos=last+10;pos<packed.size();) {
        int id=u16(packed,pos);pos+=2;
        auto term=std::find(packed.begin()+pos,packed.end(),uint8_t(0));
        require(term!=packed.end(),"Unterminated native sound name");
        s.names[id]=std::string(packed.begin()+pos,term);
        pos=static_cast<size_t>(term-packed.begin())+1;
    }
    for(const auto& entry:fs::directory_iterator(payloads)) {
        auto leaf=entry.path().filename().string();
        if(leaf.size()==15 && leaf.substr(0,3)=="SX_" && leaf.substr(7)==".RAW.bin") {
            s.raw.emplace(std::stoi(leaf.substr(3,4)),read_file(entry.path()));
        }
    }
    require(s.raw.size()==132,"DOS RAW effects missing");
    return s;
}
} // namespace ftoons
