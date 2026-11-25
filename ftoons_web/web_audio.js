// Local TOONS.SX reader and isolated original AdLib sequencer. Nothing supplied
// by the player leaves the page. Only math is imported into the audio Wasm VM.
(() => {
  "use strict";
  const entries = new Map();
  const from64 = text => Uint8Array.from(atob(text), c => c.charCodeAt(0));
  const u16 = (d, i) => d[i] | (d[i + 1] << 8);
  const u32 = (d, i) => (u16(d,i) + u16(d,i+2)*65536) >>> 0;
  const framesAt = tick => Math.ceil(tick * 5041 * 4 * 48000 / 1193182);
  const requireValue = (condition, message) => { if (!condition) throw Error(message); };
  let module, source, lastError = "";

  // Adaptive Huffman + 4096-byte sliding dictionary used by the DOS bank.
  // Position codes/lengths are read from the verified executable at import.
  function unpack(data, size, exe, ds) {
    const n = 314, total = 627, root = 626;
    const freq = new Int32Array(total+1), child = new Int32Array(total), parent = new Int32Array(total+n);
    for (let i=0; i<n; ++i) { freq[i]=1; child[i]=i+total; parent[i+total]=i; }
    freq[total] = 65535;
    for (let i=n,j=0; i<total; ++i,j+=2) {
      freq[i]=freq[j]+freq[j+1]; child[i]=j; parent[j]=parent[j+1]=i;
    }
    const ring = new Uint8Array(4096).fill(32), out = new Uint8Array(size);
    let bit = 0, cursor = 4036, used = 0;
    function bits(n) {
      requireValue(bit+n <= data.length*8, "Truncated DOS sound bank");
      let value=0;
      while (n--) { value=value*2+((data[bit>>>3] >>> (7-(bit&7)))&1); ++bit; }
      return value;
    }
    function emit(value) {
      out[used++]=value; ring[cursor]=value; cursor=(cursor+1)&4095;
    }
    while (used < size) {
      let c=child[root];
      while(c<total) c=child[c+bits(1)];
      const symbol=c-total;
      c=parent[c];
      do {
        const weight=++freq[c];
        let other=c+1;
        if (weight>freq[other]) {
          while(weight>freq[other+1]) ++other;
          freq[c]=freq[other]; freq[other]=weight;
          const a=child[c], b=child[other];
          parent[a]=other; if (a<total) parent[a+1]=other;
          parent[b]=c; if (b<total) parent[b+1]=c;
          child[c]=b; child[other]=a; c=other;
        }
        c=parent[c];
      } while(c);
      if (symbol<256) emit(symbol);
      else {
        const first=bits(8), extra=exe[ds+0x2757+first]-2;
        const distance=(exe[ds+0x2657+first]<<6) | (((first<<extra)|bits(extra))&63);
        const start=cursor-distance-1, length=symbol-253;
        requireValue(used+length<=size,"Invalid DOS sound bank match");
        for (let i=0; i<length; ++i) emit(ring[(start+i)&4095]);
      }
    }
    return out;
  }

  function analyze(bytes) {
    let p=2, loop=-1;
    requireValue(u16(bytes,0)===0x84,"Unknown sound sequence header");
    while (p<bytes.length && bytes[p]!==255) {
      const type=bytes[p++], ticks=[];
      let embedded, rate;
      while (p+1<bytes.length && bytes[p]!==255) {
        const offset=u16(bytes,p+2)+2, size=u16(bytes,p+4), end=offset+size;
        p+=6;
        if(type!==0) continue;
        requireValue(end<=bytes.length,"Track extent exceeds sequence");
        if(u16(bytes,offset)===0xfe) {
          rate=u16(bytes,offset+2);
          const length=u16(bytes,offset+4);
          requireValue(length+10===size && rate>0,"Invalid embedded DOS sample");
          ticks.push(Math.ceil(length*60/rate));
          embedded=bytes.subarray(offset+10,end);
          continue;
        }
        let at=offset+2, time=0, status=0;
        for(;;) {
          requireValue(at<end,"Missing DOS track terminator");
          while(bytes[at]===248) {time+=240; ++at;}
          time+=bytes[at++];
          if(bytes[at]&128) status=bytes[at++];
          if(status===252) break;
          requireValue(status>=128 && status<240,"Invalid DOS track command");
          if(status===207 && bytes[at]===127) loop=time;
          at+=(status>>4===12 || status>>4===13)?1:2;
        }
        ticks.push(time);
      }
      ++p;
      if(type===0 && ticks.length) {
        // The projector has sequenced tracks alongside a sample. The native
        // importer routes mixed resources through the original driver.
        return ticks.length===1 && embedded ? {ticks,loop,embedded,rate} : {ticks,loop};
      }
    }
    throw Error("Missing AdLib track table");
  }

  function importBank(exe, bank, raw) {
    entries.clear();
    const ds=u16(exe,8)*16+0x467f0, playlist=[], songs=[], effects=[], names={};
    for(let i=0;i<31;i++) playlist.push(u16(exe,ds+0x5e4+2*i));
    let last=0;
    for(let i=0;i<u16(bank,18);i++) {
      const row=21+i*6,id=u16(bank,row),start=u32(bank,row+2),size=u32(bank,start+4);
      const p=start+8,flags=bank[p+3],length=u32(bank,p+5);
      last=p+size;
      if(raw.has(id)) continue;
      requireValue(bank[p+4]===3 && length>0 && length<=65536 && last<=bank.length,"Invalid DOS bank entry");
      const seq=unpack(bank.subarray(p+9,last),length,exe,ds);
      const info=analyze(seq), music=id>=1000 && id<2000, loop=(flags&2)!==0;
      const rate=info.rate || 48000, ticks=Math.max(...info.ticks);
      const frames=info.embedded ? info.embedded.length : (!music && loop ? ticks*800 : framesAt(ticks+1));
      const resource="bank_"+id+(info.embedded?".pcm":".snd");
      const path="res://assets/original/web_audio/"+resource;
      const record={id,resource,flags,frames,loop:music||loop,loop_begin_frame:info.loop<0?0:framesAt(info.loop+1),
        sample_rate_hz:rate,channels:1,track_ticks:info.ticks};
      if(info.embedded) Object.assign(record,{asset_path:path,encoding:"unsigned_8",size_bytes:frames});
      else Object.assign(record,{web_score_path:path,encoding:"signed_16_le",size_bytes:frames*2});
      entries.set(id, info.embedded || seq);
      (music?songs:effects).push(record);
    }
    for(let p=last+10;p<bank.length;) {
      const id=u16(bank,p), end=bank.indexOf(0,p+2);
      requireValue(end>p,"Invalid sound name");
      names[id]=String.fromCharCode(...bank.subarray(p+2,end));p=end+1;
    }
    for(const row of [...songs,...effects]) row.name=names[row.id] || String(row.id);
    requireValue(songs.length===31 && effects.length===32,"Incomplete DOS sound bank");
    return JSON.stringify({songs,effects,playlist,names});
  }

  // Each rendered resource receives a fresh chip and guest memory, as on the
  // native importer's per-track render. No general purpose DOS API is exposed.
  function render(seq, record) {
    requireValue(module && source,"The original DOS audio renderer is unavailable");
    const vm = new WebAssembly.Instance(module,{env:{pow:Math.pow}}).exports;
    const address=vm.audio_mem(), mem=new Uint8Array(vm.memory.buffer,address,1048576);
    const words=new DataView(mem.buffer,mem.byteOffset,mem.byteLength);
    const word=(at,v)=>words.setUint16(at,v,true);
    function call(offset,...args) {
      word(0x7ff00,0); word(0x7ff02,0x60);
      args.forEach((v,i)=>word(0x7ff04+2*i,v));
      const result=vm.audio_call(offset);
      requireValue(result>=0,"DOS audio routine exceeded its limits at "+offset.toString(16));
      return result;
    }
    mem.set(source.image,0x10000);mem.set(source.driver,0x80000);mem.set(source.patch,0x84000);
    vm.audio_init();
    call(0x22c7,0,0x8000);call(0x22da,2,0x8400);
    const music=record.id>=1000 && record.id<2000,segment=music?0x9000:0x9020,slot=segment*16, data=music?0xa000:0xb000;
    mem.set(seq,data*16); word(slot+0x168,data);word(slot+0x16a,seq[1]+2);word(slot+0x16c,data);
    word(slot+8,0x16a);word(slot+10,segment);
    mem[slot+0x15c]=music?127:1;mem[slot+0x15d]=(record.flags&2)?1:0;mem[slot+0x15e]=127;
    requireValue(call(0x22f1,0,segment,Number(music))!==0,"DOS driver declined audio sequence");
    const maxTail=!record.loop ? 96000:0;
    requireValue(record.frames>0 && record.frames<=48000*600,"Invalid DOS sequence duration");
    const pcm=new Int16Array(record.frames+maxTail);
    let pos=0,tick=0;
    function advance(end) {
      while(pos<end) {
        const boundary=framesAt(tick+1),size=Math.min(end-pos,boundary-pos);
        if(size) pcm.set(new Int16Array(vm.memory.buffer,vm.audio_render(size),size),pos);
        pos+=size;
        if(pos===boundary){call(0x1938);++tick;}
      }
    }
    advance(record.frames);
    // Match the native renderer's 100 ms release tail blocks.
    while(pos<pcm.length) {
      const begin=pos;advance(pos+4800);
      let low=32767,high=-32768;
      for(let i=begin;i<pos;++i){low=Math.min(low,pcm[i]);high=Math.max(high,pcm[i]);}
      if(high-low<=8) break;
    }
    return new Uint8Array(pcm.buffer,0,pos*2);
  }

  function setDriver(exe,driver,patch) {
    const header=u16(exe,8)*16,pages=u16(exe,4),last=u16(exe,2);
    const end=last?(pages-1)*512+last:pages*512;
    const image=exe.slice(header,end), words=new DataView(image.buffer);
    for(let i=0;i<u16(exe,6);++i) {
      const row=u16(exe,0x18)+4*i, pos=u16(exe,row)+16*u16(exe,row+2);
      words.setUint16(pos,words.getUint16(pos,true)+0x1000,true);
    }
    source={image,driver,patch};return true;
  }
  // A synchronous buffer bridge keeps Godot's AudioStreamWAV / bus / mute /
  // loop behavior shared between platforms. Parsed bank data is freed at commit.
  function guarded(action,fallback) {
    try { return action(); } catch(err) { lastError=String(err);console.error("ftoons audio:",lastError);return fallback; }
  }
  const api=globalThis.FtoonsAudio={
    inspect:(exe,bank,ids)=>guarded(()=>importBank(from64(exe),from64(bank),new Set(JSON.parse(ids))),""),
    entry:id=>entries.get(id),clear:()=>entries.clear(),
    configure:(exe,driver,patch)=>guarded(()=>setDriver(from64(exe),from64(driver),from64(patch)),false),
    render:(seq,record)=>guarded(()=>render(from64(seq),JSON.parse(record)),null),
    error:()=>lastError,ready:()=>Boolean(module),loadError:()=>lastError,
    load:async bytes=>{module=await WebAssembly.compile(bytes);},
  };
  if(typeof document!=="undefined") {
    const wasm=new URL("ftoons_audio.wasm",document.currentScript.src);
    fetch(wasm).then(response=>{
      requireValue(response.ok,"Cannot load the WebAssembly audio decoder ("+response.status+")");
      return response.arrayBuffer();
    }).then(bytes=>api.load(bytes)).catch(error=>{lastError=String(error);console.error(lastError);});
  }
})();
