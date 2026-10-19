/* Exercise real mapping arithmetic at zero, page crossings and the 64-bit edge.
 * Valid arithmetic does not establish that an address belongs to GPU memory. */
#include <cassert>
#include <cstdint>
#include <cstdio>
#include "nmx_checked_ranges.h"
int main() {
    uint64_t last = 7, base = 9, span = 10;
    assert(!nmx_checked_last(0, 0, &last) && last == 7);
    assert(!nmx_checked_last(UINT64_MAX, 2, &last) && last == 7);
    assert(!nmx_checked_last(0, 1, nullptr));
    assert(nmx_checked_last(0, 1, &last) && last == 0);
    assert(nmx_checked_last(UINT64_MAX, 1, &last) && last == UINT64_MAX);
    assert(nmx_checked_last(100, 400, &last) && last == 499);
    assert(!nmx_checked_page_span(0, 1, 0, &base, &span));
    assert(!nmx_checked_page_span(0, 1, 3, &base, &span));
    assert(!nmx_checked_page_span(UINT64_MAX, 1, 4096, &base, &span));
    assert(base == 9 && span == 10);
    assert(nmx_checked_page_span(0, 4096, 4096, &base, &span));
    assert(base == 0 && span == 4096);
    assert(nmx_checked_page_span(4095, 2, 4096, &base, &span));
    assert(base == 0 && span == 8192);
    assert(nmx_checked_page_span(0x1003, 0x3000, 4096, &base, &span));
    assert(base == 0x1000 && span == 0x4000);
    assert(!nmx_checked_page_span(1, UINT64_MAX, 4096, &base, &span));
    std::puts("Checked mapping ranges fixture passed: zero, overflow, inclusive endpoints and page spans");
}
