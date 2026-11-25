// Native Windows x64 companion to the Godot resource importer.
#include "shared_opl_service.h"
#include "synth.hpp"
#include "offline.hpp"
#include <iostream>

int wmain(int argc, wchar_t** argv) {
    try {
        if (argc == 4 && std::wstring(argv[1]) == L"import") {
            ftoons::import_audio(argv[2], argv[3]);
            return 0;
        }
        if (argc == 5 && std::wstring(argv[1]) == L"serve") {
            std::filesystem::path project(argv[2]);
            auto sources = ftoons::load(project / "assets/original/audio_driver", project);
            ftoons::Synth synth(sources);
            std::wstring token(argv[4]);
            int port = std::stoi(argv[3]);
            if (port < 1 || port > 65535 || token.size() != 32 ||
                token.find_first_not_of(L"0123456789abcdef") != std::wstring::npos) {
                throw std::runtime_error("Invalid loopback audio session");
            }
            ftoons_audio_service::serve(synth, port, std::string(token.begin(), token.end()));
            return 0;
        }
        throw std::runtime_error("Expected import <DOS folder> <stage> or serve <project> <port> <token>");
    } catch(const std::exception& error) {
        std::cerr << error.what() << "\n";
        return 1;
    }
}
