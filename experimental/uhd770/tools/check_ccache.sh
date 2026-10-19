#!/bin/bash
# A userspace probe checks cache hits and invalidation with the runner's actual
# ccache/Clang. It never loads driver code and never modifies the real build cache.
set -euo pipefail
TMP=$(mktemp -d /tmp/nmx-ccache-check.XXXXXX)
export CCACHE_DIR=$TMP/cache
export CCACHE_NODIRECT=true
export CCACHE_COMPILERCHECK=content
unset CCACHE_DISABLE CCACHE_SLOPPINESS
cleanup() {
    local result=$?
    if [[ "$result" != 0 ]]; then
        echo "ccache probe failed (exit $result); isolated cache statistics follow" >&2
        ccache --show-stats >&2 || true
        ccache --print-stats >&2 || true
    fi
    rm -rf "$TMP"
    exit "$result"
}
trap cleanup EXIT
CC=$(xcrun --find clang)
printf '#define HEADER_VALUE 1\n' > "$TMP/value.h"
printf '#include "value.h"\nint value(void) { return HEADER_VALUE + FLAG_VALUE; }\n' > "$TMP/value.c"
printf '#include <stdio.h>\nint value(void); int main(void) { printf("%%d\\n", value()); }\n' > "$TMP/main.c"
# Freshly generated input timestamps must predate compilation. Keep ccache's
# race protection enabled rather than weakening it with mtime/ctime sloppiness.
sleep 1
probe() {
    local actual
    ccache "$CC" -O2 "-DFLAG_VALUE=$1" -c "$TMP/value.c" -o "$TMP/value.o"
    "$CC" "$TMP/main.c" "$TMP/value.o" -o "$TMP/probe"
    actual=$("$TMP/probe")
    printf 'Cache probe flag=%s expected=%s actual=%s\n' "$1" "$2" "$actual"
    [[ "$actual" == "$2" ]]
}
probe 3 4
probe 3 4
ccache --print-stats > "$TMP/stats.txt"
ccache --show-stats
python3 - "$TMP/stats.txt" <<'PY'
import sys
stats = dict(line.split() for line in open(sys.argv[1]) if line.strip())
assert int(stats.get('preprocessed_cache_hit', 0)) >= 1, stats
PY
printf '#define HEADER_VALUE 7\n' > "$TMP/value.h"
sleep 1
probe 3 10
probe 5 12
printf '#include "value.h"\nint value(void) { return HEADER_VALUE + FLAG_VALUE + 1; }\n' > "$TMP/value.c"
sleep 1
probe 5 13
ccache --print-stats > "$TMP/stats.txt"
python3 - "$TMP/stats.txt" <<'PY'
import sys
stats = dict(line.split() for line in open(sys.argv[1]) if line.strip())
assert int(stats.get('cache_miss', 0)) == 4, stats
assert int(stats.get('preprocessed_cache_hit', 0)) == 1, stats
PY
echo 'ccache probe passed: hit, header change, flag change, source change'
ccache --show-stats
