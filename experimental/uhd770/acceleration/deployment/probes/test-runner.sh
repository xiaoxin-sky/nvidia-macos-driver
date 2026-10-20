#!/bin/bash
# Offline fixtures: only shell mocks are spawned; no Mac probe, ICD or driver is
# loaded. Production identity gates are not parameterized for these fixtures.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/runner-lib.sh"
fixture_parent=${TMPDIR:-/tmp}
fixture_parent=$(cd "$fixture_parent" && pwd -P)
fixture=$(mktemp -d "$fixture_parent/uhd770-runner-fixture.XXXXXX")
case "$fixture" in "$fixture_parent"/uhd770-runner-fixture.*) ;; *) exit 1 ;; esac
[ -d "$fixture" ] && [ ! -L "$fixture" ] || exit 1
fixture_cleanup() {
    local status=$? resolved
    if [ "$status" -ne 0 ]; then
        printf 'Fixture failed; evidence retained at %s\n' "$fixture" >&2
        return
    fi
    # Recheck the final absolute target immediately before recursive removal;
    # keep creation, validation and removal in the same shell path namespace.
    case "$fixture" in "$fixture_parent"/uhd770-runner-fixture.*) ;; *) return 1 ;; esac
    [ -d "$fixture" ] && [ ! -L "$fixture" ] || return 1
    resolved=$(cd "$fixture" && pwd -P) || return 1
    [ "$resolved" = "$fixture" ] || return 1
    rm -rf -- "$fixture"
}
trap fixture_cleanup EXIT
# Avoid flushing the entire development machine for each mock; only the inert
# helper is sourced. The installed production runner has no test environment.
sync() { :; }
export -f sync

assert_file() { [ -f "$1" ] || { printf 'Missing fixture evidence: %s\n' "$1" >&2; exit 1; }; }
case_run() {
    local name=$1 expected=$2 text=$3 actual=0
    mkdir "$fixture/$name"
    uhd_run_bounded "$fixture/$name" COMPUTE_READBACK_VERIFIED 4 \
        /bin/bash -c "$text" > "$fixture/$name/terminal.txt" 2>&1 || actual=$?
    [ "$actual" -eq "$expected" ] || { cat "$fixture/$name/terminal.txt"; printf 'Wrong exit for %s: %s\n' "$name" "$actual" >&2; exit 1; }
    assert_file "$fixture/$name/probe-start.marker"
    assert_file "$fixture/$name/probe-pid.txt"
    assert_file "$fixture/$name/result.txt"
}

case_run valid 0 'printf "COMPUTE_READBACK_VERIFIED: mock-only\n"'
grep -q '^state=verified-readback$' "$fixture/valid/result.txt"
case_run no_marker 65 'printf "No GPU execution occurred\n"'
case_run bad_exit 7 'printf "COMPUTE_READBACK_VERIFIED: mock-only\n"; exit 7'
case_run wrong_phase 65 'printf "METAL_COMPUTE_READBACK_VERIFIED: mock-only\n"'
case_run partial_marker 65 'printf "prefix COMPUTE_READBACK_VERIFIED: mock-only\n"'

# Failure to persist the start marker must refuse before launching the mock.
mkdir "$fixture/unwritable"
mkdir "$fixture/unwritable/probe-start.marker"
code=0
uhd_run_bounded "$fixture/unwritable" COMPUTE_READBACK_VERIFIED 4 \
    /bin/bash -c 'touch "$1/child-started"' fake "$fixture/unwritable" \
    > "$fixture/unwritable/terminal.txt" 2>&1 || code=$?
[ "$code" -eq 74 ]
[ ! -e "$fixture/unwritable/child-started" ]

# The marker must exist before even the first child instruction. This mock exits
# immediately on a missing marker, making the ordering an observable contract.
mkdir "$fixture/prestart"
uhd_run_bounded "$fixture/prestart" COMPUTE_READBACK_VERIFIED 4 \
    /bin/bash -c 'test -s "$1/probe-start.marker" || exit 9; printf "COMPUTE_READBACK_VERIFIED: mock-only\n"' \
    fake "$fixture/prestart" > "$fixture/prestart/terminal.txt" 2>&1

# Timeout remains bounded when the fake child ignores TERM. The outer helper
# must be allowed to kill its OWN waiting shell, never the fixture parent.
mkdir "$fixture/timeout"
code=0
started=$SECONDS
uhd_run_bounded "$fixture/timeout" COMPUTE_READBACK_VERIFIED 1 \
    /bin/bash -c 'trap "" TERM; while :; do sleep 1; done' \
    > "$fixture/timeout/terminal.txt" 2>&1 || code=$?
[ "$code" -eq 124 ] && [ $((SECONDS - started)) -le 8 ]
assert_file "$fixture/timeout/outer-timeout.marker"
assert_file "$fixture/timeout/result.txt"

# A native Mach-O byte fixture checks UUID decoding without Xcode, Python or any
# execution of the image. LC_UUID follows the 32-byte little-endian 64-bit header.
printf '\317\372\355\376\007\000\000\001\003\000\000\000\013\000\000\000\001\000\000\000\030\000\000\000\000\000\000\000\000\000\000\000\033\000\000\000\030\000\000\000\000\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017' > "$fixture/native-image"
[ "$(uhd_macho_uuid "$fixture/native-image")" = 000102030405060708090a0b0c0d0e0f ]
printf 'not a Mach-O\n' > "$fixture/bad-image"
if uhd_macho_uuid "$fixture/bad-image" >/dev/null 2>&1; then exit 1; fi

# On Git Bash/Linux the real entry point refuses before reading candidate paths.
# This is deliberately NOT a production mock/identity-check override.
if [ "$(uname -s)" != Darwin ]; then
    code=0
    /bin/bash -p "$HERE/run-probe.sh" vulkan > "$fixture/refused.txt" 2>&1 || code=$?
    [ "$code" -eq 64 ]
    grep -q 'macOS is required' "$fixture/refused.txt"
fi
/bin/bash -p "$HERE/run-probe.sh" --help > "$fixture/help.txt"
grep -q 'vulkan|metal' "$fixture/help.txt"
printf 'PASS: lifecycle/marker/phase/timeout/UUID fixtures; fake children only, no GPU executed.\n'
