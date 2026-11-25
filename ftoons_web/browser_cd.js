// Keep the player's mixed-mode disc as a local Blob. Only the playing track is
// exposed to the media decoder, so the whole disc never enters the Godot heap.
(() => {
    "use strict";
    const sectorBytes = 2352;
    let disc = null;
    let player = null;
    let url = null;
    let volume = 1;
    const database = new Promise((resolve, reject) => {
        const request = indexedDB.open("ftoons-cd:" + new URL(".", location.href).pathname, 1);
        request.onupgradeneeded = () => request.result.createObjectStore("disc");
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
        request.onblocked = () => reject(new Error("Close other ftoons tabs and retry."));
    });
    const read = database.then(db => new Promise((resolve, reject) => {
        const request = db.transaction("disc").objectStore("disc").get("mixed-mode");
        request.onsuccess = () => { disc = request.result || null; resolve(); };
        request.onerror = () => reject(request.error);
    })).catch(() => {});

    function wavHeader(size) {
        const buffer = new ArrayBuffer(44);
        const output = new DataView(buffer);
        const tag = (offset, value) => new Uint8Array(buffer, offset, 4).set(new TextEncoder().encode(value));
        tag(0, "RIFF");
        output.setUint32(4, size + 36, true);
        tag(8, "WAVE");
        tag(12, "fmt ");
        output.setUint32(16, 16, true);
        output.setUint16(20, 1, true);
        output.setUint16(22, 2, true);
        output.setUint32(24, 44100, true);
        output.setUint32(28, 176400, true);
        output.setUint16(32, 4, true);
        output.setUint16(34, 16, true);
        tag(36, "data");
        output.setUint32(40, size, true);
        return buffer;
    }

    function stop() {
        if (player) {
            player.pause();
            player.removeAttribute("src");
            player.load();
            player = null;
        }
        if (url) URL.revokeObjectURL(url);
        url = null;
    }

    window.ftoonsCD = {
        async store(file, table, done) {
            try {
                await read;
                const next = { file, starts: JSON.parse(table) };
                const db = await database;
                await new Promise((resolve, reject) => {
                    const tx = db.transaction("disc", "readwrite");
                    tx.oncomplete = resolve;
                    tx.onabort = () => reject(tx.error || new Error("The browser could not store the disc."));
                    tx.objectStore("disc").put(next, "mixed-mode");
                });
                disc = next;
                done("");
            } catch (e) {
                done("Could not save the CD soundtrack in browser storage. " + e.message);
            }
        },
        available() { return !!disc; },
        play(number, failed) {
            stop();
            if (!disc || number < 2 || number > disc.starts.length) return false;
            const start = disc.starts[number - 1] * sectorBytes;
            const end = number < disc.starts.length ? disc.starts[number] * sectorBytes : disc.file.size;
            const audio = new Audio();
            const blob = new Blob([wavHeader(end - start), disc.file.slice(start, end)], { type: "audio/wav" });
            url = URL.createObjectURL(blob);
            player = audio;
            audio.loop = true;
            audio.volume = volume;
            audio.src = url;
            const report = message => {
                if (player !== audio) return;
                stop();
                failed(message);
            };
            audio.onerror = () => report("The browser could not decode this CD track.");
            audio.play().catch(e => report(e.message));
            return true;
        },
        stop,
        setVolume(value) {
            volume = Math.max(0, Math.min(1, value));
            if (player) player.volume = volume;
        }
    };
})();
