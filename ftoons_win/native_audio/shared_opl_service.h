#pragma once
// Godot owns a loopback listener and passes its port/token to the child process.
// All command frames are length-prefixed flat JSON. Replies add a PCM byte count.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace ftoons_audio_service {

class Winsock {
public:
    Winsock() {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2,2), &wsa)) throw std::runtime_error("Could not initialize Winsock");
    }
    ~Winsock() { WSACleanup(); }
};

class Channel {
    SOCKET socket_ = INVALID_SOCKET;
public:
    ~Channel() { if (socket_ != INVALID_SOCKET) closesocket(socket_); }
    void connect_local(int port) {
        if (port <= 0 || port > 65535) throw std::invalid_argument("Invalid Godot audio port");
        socket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<unsigned short>(port));
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (socket_ == INVALID_SOCKET || connect(socket_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)))
            throw std::runtime_error("Could not connect to Godot audio listener");
        DWORD timeout = 15000;
        int on = 1;
        setsockopt(socket_, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&on), sizeof(on));
        setsockopt(socket_, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
        setsockopt(socket_, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    }
    bool read(void* dest, size_t size, bool allow_eof = false) {
        char* ptr = static_cast<char*>(dest);
        size_t done = 0;
        while (done < size) {
            int n = recv(socket_, ptr + done, static_cast<int>(size - done), 0);
            if (n == 0 && !done && allow_eof) return false;
            if (n <= 0) throw std::runtime_error("Incomplete Godot audio command");
            done += n;
        }
        return true;
    }
    void write(const void* src, size_t size) {
        const char* ptr = static_cast<const char*>(src);
        size_t done = 0;
        while (done < size) {
            int n = send(socket_, ptr + done, static_cast<int>(size - done), 0);
            if (n <= 0) throw std::runtime_error("Could not reply to Godot");
            done += n;
        }
    }
    void reply(const std::string& header, const std::vector<int16_t>& pcm = {}) {
        // The executable and Godot client on this platform both use little-endian words.
        const std::array<uint32_t,2> lengths = {
            static_cast<uint32_t>(header.size()), static_cast<uint32_t>(pcm.size() * sizeof(int16_t))
        };
        write(lengths.data(), sizeof(lengths));
        write(header.data(), header.size());
        write(pcm.data(), pcm.size() * sizeof(int16_t));
    }
};

// The service accepts the scalar subset actually emitted by shared_opl.gd.
// It only needs ASCII identifiers, signed integers and Booleans.
class Command {
    const std::string& text;
    size_t pos = 0;
    std::map<std::string,std::string> fields;

    [[noreturn]] static void invalid() { throw std::runtime_error("Invalid Godot audio command"); }
    void whitespace() {
        while (pos < text.size() && std::isspace(static_cast<unsigned char>(text[pos]))) ++pos;
    }
    bool take(char ch) {
        whitespace();
        if (pos == text.size() || text[pos] != ch) return false;
        ++pos;
        return true;
    }
    std::string identifier() {
        if (!take('"')) invalid();
        size_t start = pos;
        while (pos < text.size() && (std::isalnum(static_cast<unsigned char>(text[pos])) || text[pos] == '_')) ++pos;
        if (pos == start || pos >= text.size() || text[pos] != '"') invalid();
        return text.substr(start, pos++ - start);
    }
public:
    explicit Command(const std::string& json) : text(json) {
        if (!take('{')) invalid();
        do {
            std::string key = identifier();
            if (!take(':')) invalid();
            whitespace();
            if (pos == text.size()) invalid();
            std::string value;
            if (text[pos] == '"') value = identifier();
            else {
                size_t start = pos;
                while (pos < text.size() && (std::isalnum(static_cast<unsigned char>(text[pos])) || text[pos] == '-')) ++pos;
                if (pos == start) invalid();
                value = text.substr(start, pos-start);
            }
            if (!fields.emplace(key,value).second) invalid();
        } while (take(','));
        if (!take('}')) invalid();
        whitespace();
        if (pos != text.size()) invalid();
    }
    std::string get(const std::string& key) const {
        auto it = fields.find(key);
        if (it == fields.end()) invalid();
        return it->second;
    }
    int number(const char* key) const {
        const std::string value = get(key);
        size_t end = 0;
        long long n = std::stoll(value, &end);
        if (end != value.size() || n < INT32_MIN || n > INT32_MAX) invalid();
        return static_cast<int>(n);
    }
    bool retrigger() const {
        auto it = fields.find("retrigger");
        if (it == fields.end() || it->second == "false") return false;
        if (it->second != "true") invalid();
        return true;
    }
};

template<class Synth>
int serve(Synth& synth, int port, std::string token) {
    if (token.size() != 32 || !std::all_of(token.begin(), token.end(), [](unsigned char c){ return std::isxdigit(c); }))
        throw std::invalid_argument("Invalid Godot audio session token");
    Winsock wsa;
    Channel conn;
    conn.connect_local(port);
    try {
        conn.reply("{\"ready\":true,\"rate\":48000,\"token\":\"" + token + "\",\"backend\":\"ADL.DRV / DBOPL\"}");
        for (;;) {
            uint32_t length = 0;
            if (!conn.read(&length, sizeof(length), true)) return 0;
            if (!length || length > 65536) throw std::runtime_error("Invalid audio frame length");
            std::string json(length, '\0');
            conn.read(&json[0], length);
            Command cmd(json);
            const std::string op = cmd.get("op");
            if (op == "close") return 0;
            if (op == "play") synth.play(cmd.number("id"), cmd.retrigger());
            else if (op == "stop") synth.stop(cmd.number("id"));
            else if (op == "stop_raw") synth.stop_raw();
            else if (op == "stop_effects") synth.stop_effects();
            else if (op == "music_volume") synth.music_volume(std::clamp(cmd.number("value"), 0, 127));
            else if (op == "render") {
                int frames = cmd.number("frames");
                int sequence = cmd.number("sequence");
                if (frames < 1 || frames > 4800 || sequence < 0) throw std::runtime_error("Invalid render request");
                auto pcm = synth.render(frames);
                if (pcm.size() != static_cast<size_t>(frames)) throw std::runtime_error("Incomplete PCM render");
                conn.reply("{\"sequence\":"+std::to_string(sequence)+",\"frames\":"+std::to_string(frames)+"}", pcm);
            } else throw std::runtime_error("Unknown audio command");
        }
    } catch (...) {
        try { conn.reply("{\"error\":\"The native audio worker could not complete the command. Check its log.\"}"); }
        catch (...) {}
        throw;
    }
}

} // namespace ftoons_audio_service
