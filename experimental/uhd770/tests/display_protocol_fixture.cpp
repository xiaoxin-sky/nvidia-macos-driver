/* Exercise the shared mode/DDC ABI with independent boundary cases. No DRM or
 * GPU is mocked here: the same validators/copy routines serve native callers. */
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "nmx_display_protocol.h"

static void checksum(uint8_t *block) {
    unsigned sum = 0;
    for (unsigned i = 0; i < 127; ++i) sum += block[i];
    block[127] = static_cast<uint8_t>(0u - sum);
}
int main() {
    nmx_display_mode mode{7, 1920, 1080, 148500, 2200, 1125, 2008, 2052, 1084, 1089, 0};
    assert(nmx_display_mode_valid(&mode, 3840, 2160));
    assert(!nmx_display_mode_valid(&mode, 1280, 720));
    assert(!nmx_display_mode_valid(nullptr, 3840, 2160));
    auto bad = mode;
    bad.htotal = 0; assert(!nmx_display_mode_valid(&bad, 3840, 2160));
    bad = mode; bad.hsync_end = bad.hsync_start;
    assert(!nmx_display_mode_valid(&bad, 3840, 2160));
    bad = mode; bad.vsync_end = 2000;
    assert(!nmx_display_mode_valid(&bad, 3840, 2160));
    bad = mode; bad.id = 0;
    assert(!nmx_display_mode_valid(&bad, 3840, 2160));
    bad = mode; bad.pclk_khz = UINT32_MAX;
    assert(!nmx_display_mode_valid(&bad, 3840, 2160));
    nmx_display_state state{};
    state.connected = 1; state.current_mode = mode.id;
    state.modes[0] = mode; state.mode_count = 1;
    assert(nmx_display_find(&state, 7) == &state.modes[0]);
    assert(!nmx_display_find(&state, 0) && !nmx_display_find(&state, 1));
    state.mode_count = NMX_DISPLAY_MODES + 1;
    assert(!nmx_display_find(&state, 7));
    state.mode_count = 1;

    std::array<uint8_t, 256> edid{};
    for (unsigned i = 1; i < 7; ++i) edid[i] = 255;
    edid[126] = 1;
    edid[128] = 2;
    checksum(edid.data()); checksum(edid.data() + 128);
    assert(nmx_display_edid_size(edid.data(), edid.size()) == edid.size());
    assert(!nmx_display_edid_size(edid.data(), 128));
    edid[140] ^= 1;
    assert(!nmx_display_edid_size(edid.data(), edid.size()));
    edid[140] ^= 1;
    edid[0] = 1;
    assert(!nmx_display_edid_size(edid.data(), edid.size()));
    edid[0] = 0;
    state.edid_size = static_cast<uint32_t>(edid.size());
    std::memcpy(state.edid, edid.data(), edid.size());
    std::array<uint8_t, 128> out{};
    assert(nmx_display_edid_block(&state, 1, out.data(), out.size()));
    assert(!std::memcmp(out.data(), edid.data(), 128));
    assert(nmx_display_edid_block(&state, 2, out.data(), out.size()));
    assert(!std::memcmp(out.data(), edid.data() + 128, 128));
    out.fill(99);
    assert(!nmx_display_edid_block(&state, 0, out.data(), 128));
    assert(!nmx_display_edid_block(&state, 3, out.data(), 128));
    assert(!nmx_display_edid_block(&state, UINT32_MAX, out.data(), 128));
    assert(!nmx_display_edid_block(&state, 1, out.data(), 127));
    state.connected = 0;
    assert(!nmx_display_edid_block(&state, 1, out.data(), 128));
    for (auto value : out) assert(value == 99);
    edid[126] = 255; checksum(edid.data());
    assert(!nmx_display_edid_size(edid.data(), 32768));
    std::puts("Display protocol fixture passed: timing bounds, stable IDs, EDID checksums/extensions and one-based DDC blocks");
}
