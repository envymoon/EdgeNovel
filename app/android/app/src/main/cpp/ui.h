// The no-assets interface from llama.cpp's tools/ui/embed.cpp. Flutter owns UI;
// no web bundle, Node toolchain, or host-side UI generator is needed on Android.
#pragma once
#include <array>
#include <string>
struct llama_ui_asset {
    std::string name;
    const unsigned char * data;
    std::size_t size;
    std::string etag;
    std::string type;
};
inline const llama_ui_asset * llama_ui_find_asset(const std::string &) { return nullptr; }
inline bool llama_ui_use_gzip() { return false; }
inline const std::array<llama_ui_asset, 0> & llama_ui_get_assets() {
    static const std::array<llama_ui_asset, 0> empty{};
    return empty;
}
