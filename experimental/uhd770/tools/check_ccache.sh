#!/bin/bash
# A userspace probe checks cache hits and invalidation with the runner's actual
# ccache/Clang. It never loads driver code and never modifies the real build cache.
set -euo pipefail
TMP=$(mktemp -d /tmp/nmx-ccache-check.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export CCACHE_DIR=$TMP/cache
export CCACHE_NODIRECT=true
export CCACHE_COMPILERCHECK=content
unset CCACHE_DISABLE CCACHE_SLOPPINESS
CC=$(xcrun --find clang)
printf '#define HEADER_VALUE 1\n' > "$TMP/value.h"
printf '#include "value.h"\nint value(void) { return HEADER_VALUE + FLAG_VALUE; }\n' > "$TMP/value.c"
printf '#include <stdio.h>\nint value(void); int main(void) { printf("%%d\\n", value()); }\n' > "$TMP/main.c"
probe() {
    ccache "$CC" -O2 "-DFLAG_VALUE=$1" -c "$TMP/value.c" -o "$TMP/value.o"
    "$CC" "$TMP/main.c" "$TMP/value.o" -o "$TMP/probe"
    [[ "$("$TMP/probe")" == "$2" ]]
}
probe 3 4
probe 3 4
ccache --print-stats > "$TMP/stats.txt"
python3 - "$TMP/stats.txt" <<'PY'
import sys
stats = dict(line.split() for line in open(sys.argv[1]) if line.strip())
assert int(stats.get('preprocessed_cache_hit', 0)) >= 1, stats
PY
printf '#define HEADER_VALUE 7\n' > "$TMP/value.h"
probe 3 10
probe 5 12
printf '#include "value.h"\nint value(void) { return HEADER_VALUE + FLAG_VALUE + 1; }\n' > "$TMP/value.c"
probe 5 13
echo 'ccache probe passed: hit, header change, flag change, source change'
ccache --show-stats
