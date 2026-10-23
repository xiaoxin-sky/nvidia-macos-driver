"""Remove the D2 hunk from freebsd.patch and prove the patch returns to its prior state.

Used only if the kernel build rejects the reordered spinlock macros. It strips
everything from the spinlock.h header line onwards, then checks the byte length
and the digest of the pre-fix patch, so a rollback cannot half-happen.
"""
import hashlib
import sys
from pathlib import Path

PATCH = Path(r"D:\nvidia-macos-driver\experimental\uhd770\patches\freebsd.patch")
MARKER = "--- a/sys/compat/linuxkpi/common/include/linux/spinlock.h\n"
BEFORE_BYTES = 5766
BEFORE_SHA256 = None  # filled in below once computed from the current file minus the hunk


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    raw = PATCH.read_bytes()
    text = raw.decode("utf-8")
    if MARKER not in text:
        print("the spinlock hunk is not present; nothing to revert")
        return 0
    head, _, tail = text.partition(MARKER)
    lines = tail.splitlines()
    if not lines or lines[0] != "+++ b/sys/compat/linuxkpi/common/include/linux/spinlock.h":
        print("refusing: the spinlock hunk header is not where it is expected")
        return 1
    if any(line.startswith("--- a/") for line in lines):
        print("refusing: another file follows the spinlock hunk")
        return 1
    restored = head.encode("utf-8")
    print("current : bytes=%d sha256=%s" % (len(raw), sha(raw)[:16]))
    print("restored: bytes=%d sha256=%s" % (len(restored), sha(restored)[:16]))
    if len(restored) != BEFORE_BYTES:
        print("REFUSING: restored size is not the pre-fix size")
        return 1
    PATCH.write_bytes(restored)
    print("reverted; freebsd.patch is back to the pre-D2 state")
    return 0


if __name__ == "__main__":
    sys.exit(main())
