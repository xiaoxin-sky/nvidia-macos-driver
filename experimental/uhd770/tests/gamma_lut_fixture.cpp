/* Test the real packed-IOFramebuffer-to-DRM normalization without IOKit or GPU
 * services. Expected ramps and interpolation properties come from the formats. */
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include "nmx_gamma_lut.h"

int main() {
    std::array<uint16_t, 3 * NMX_GAMMA_ENTRIES> out{};
    const uint16_t endpoints[] = {0, 65535};
    assert(nmx_gamma_normalize(1, 2, 16, endpoints, out.data()));
    for (unsigned channel = 0; channel < 3; ++channel)
        for (unsigned i = 0; i < NMX_GAMMA_ENTRIES; ++i)
            assert(out[channel * NMX_GAMMA_ENTRIES + i] == i * 257);
    std::array<uint8_t, 3 * NMX_GAMMA_ENTRIES> rgb{};
    for (unsigned i = 0; i < NMX_GAMMA_ENTRIES; ++i) {
        rgb[i] = static_cast<uint8_t>(i);
        rgb[NMX_GAMMA_ENTRIES + i] = static_cast<uint8_t>(255 - i);
        rgb[NMX_GAMMA_ENTRIES * 2 + i] = 128;
    }
    assert(nmx_gamma_normalize(3, NMX_GAMMA_ENTRIES, 8, rgb.data(), out.data()));
    for (unsigned i = 0; i < NMX_GAMMA_ENTRIES; ++i) {
        assert(out[i] == i * 257);
        assert(out[NMX_GAMMA_ENTRIES + i] == (255 - i) * 257);
        assert(out[NMX_GAMMA_ENTRIES * 2 + i] == 128 * 257);
    }
    const uint8_t triangle[] = {0, 255, 0};
    assert(nmx_gamma_normalize(1, 3, 8, triangle, out.data()));
    assert(out[0] == 0 && out[255] == 0 && out[127] == out[128] && out[127] > 65000);
    std::array<uint8_t, sizeof(endpoints) + 1> unaligned{};
    std::memcpy(unaligned.data() + 1, endpoints, sizeof(endpoints));
    assert(nmx_gamma_normalize(1, 2, 16, unaligned.data() + 1, out.data()));
    assert(out[0] == 0 && out[255] == 65535);
    std::vector<uint16_t> large(65536);
    for (unsigned i = 0; i < large.size(); ++i) large[i] = static_cast<uint16_t>(i);
    assert(nmx_gamma_normalize(1, static_cast<unsigned>(large.size()), 16, large.data(), out.data()));
    for (unsigned i = 0; i < NMX_GAMMA_ENTRIES; ++i) assert(out[i] == i * 257);
    out.fill(1234);
    assert(!nmx_gamma_normalize(2, 256, 8, rgb.data(), out.data()));
    assert(!nmx_gamma_normalize(1, 0, 8, rgb.data(), out.data()));
    assert(!nmx_gamma_normalize(1, 65537, 8, rgb.data(), out.data()));
    assert(!nmx_gamma_normalize(1, 256, 32, rgb.data(), out.data()));
    assert(!nmx_gamma_normalize(1, 256, 8, nullptr, out.data()));
    assert(!nmx_gamma_normalize(1, 256, 8, rgb.data(), nullptr));
    for (uint16_t value : out) assert(value == 1234);
    std::puts("Gamma LUT fixture passed: packed channels, 8/16-bit, resampling, unaligned input and invalid metadata");
}
