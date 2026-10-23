"""Tie the recorded primitive-hazard dispositions to the code they describe.

The acceptance review objected that a proven hazard (spin_unlock enables bottom
halves before dropping the mutex) had no fix and no reason. The reason given is
that enabling bottom halves cannot run anything in this port, so the inverted
order is unobservable. That reason is only true while the port's BH enable does
nothing, so this checks it instead of asserting it.

Each check is a claim from the audit records; if the code moves, the claim is
stale and this fails, which is the point.

The pinned trees are outside the repository, so the checks skip when the paths
are not present, and say which variable to set.
"""
import os
import re
import unittest
from pathlib import Path

FREEBSD = os.environ.get("NMX_FREEBSD_SRC")
XKPI = os.environ.get("NMX_XKPI")

LINUXKPI = "sys/compat/linuxkpi/common/include/linux"
LINUXKPI_SRC = "sys/compat/linuxkpi/common/src"


def need(base, variable):
    if not base:
        raise unittest.SkipTest(f"set {variable} to the pinned tree to run this check")
    path = Path(base)
    if not path.is_dir():
        raise unittest.SkipTest(f"{variable} does not point at a directory: {path}")
    return path


def read(base, relative):
    path = Path(base) / relative
    if not path.is_file():
        raise unittest.SkipTest(f"missing {path}")
    return path.read_text(encoding="utf-8", errors="replace")


PATCH = Path(__file__).resolve().parent.parent / "patches" / "freebsd.patch"
SPINLOCK = f"{LINUXKPI}/spinlock.h"


def patched_spinlock():
    """Reproduce the header the kernel build sees: the pin with our patch applied.

    Reading the pinned file would assert the pre-fix order, which is exactly the
    mistake this check exists to prevent.
    """
    base = need(FREEBSD, "NMX_FREEBSD_SRC")
    if not PATCH.is_file():
        raise unittest.SkipTest(f"missing patch {PATCH}")
    import shutil, subprocess, tempfile
    work = Path(tempfile.mkdtemp())
    try:
        target = work / SPINLOCK
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((Path(base) / SPINLOCK).read_bytes().replace(b"\r\n", b"\n"))
        subprocess.run(["git", "init", "-q"], cwd=work, check=True, capture_output=True)
        applied = subprocess.run(["git", "apply", "--include", SPINLOCK, str(PATCH)],
                                 cwd=work, capture_output=True, text=True)
        if applied.returncode != 0:
            raise AssertionError(f"patch does not apply to {SPINLOCK}: {applied.stderr.strip()[:200]}")
        return target.read_text(encoding="utf-8")
    finally:
        shutil.rmtree(work, ignore_errors=True)


class HazardDispositions(unittest.TestCase):
    def test_d2_bh_enable_cannot_dispatch(self):
        """D2's fix is behaviourally neutral today only because enabling BH dispatches nothing."""
        base = need(XKPI, "NMX_XKPI")
        # the port overrides the pinned linux_tasklet.c, so the built definition
        # is the override, not the FreeBSD original
        source = read(base, "override/src/linux_tasklet.c")
        body = self._function_body(source, "local_bh_enable")
        self.assertIsNotNone(body, "local_bh_enable not found")
        # The whole reason the inverted order is unobservable: it only forwards.
        self.assertRegex(body, r"nmx_linux_bh_enable\s*\(", "local_bh_enable no longer forwards")
        self.assertNotRegex(body, r"tasklet_schedule|tasklet_action|softirq|wakeup|sched_",
                            "local_bh_enable could dispatch work")
        kernel = Path(XKPI) / "bsdcompat" / "src" / "nmx_kernel.c" if XKPI else None
        if kernel and kernel.is_file():
            text = kernel.read_text(encoding="utf-8", errors="replace")
            impl = self._function_body(text, "nmx_linux_bh_enable")
            self.assertIsNotNone(impl, "nmx_linux_bh_enable not found")
            self.assertNotRegex(impl, r"tasklet|softirq|wakeup|schedule",
                                "the BH enable implementation gained a dispatch path")

    def test_d2_unlock_order_is_fixed(self):
        """D2 is fixed by the shipped patch: both unlock macros release the mutex before enabling BH."""
        header = patched_spinlock()
        for macro in ("spin_unlock", "spin_unlock_bh"):
            block = re.search(rf"#define\s+{macro}\(_l\).*?while \(0\)", header, re.S)
            self.assertIsNotNone(block, f"{macro} definition not found")
            body = block.group(0)
            release = body.find("mtx_unlock") if "mtx_unlock" in body else body.find("spin_unlock(_l)")
            self.assertGreaterEqual(release, 0, f"{macro} has no release step")
            self.assertLess(release, body.index("local_bh_enable"),
                            f"{macro} enables bottom halves before releasing the lock again")

    def test_d1_irqsave_still_does_not_mask(self):
        """D1's claim: spin_lock_irqsave only zeroes the flags."""
        header = patched_spinlock()
        block = re.search(r"#define\s+spin_lock_irqsave\(_l, flags\).*?while \(0\)", header, re.S)
        self.assertIsNotNone(block, "spin_lock_irqsave definition not found")
        body = block.group(0)
        self.assertIn("(flags) = 0", body)
        self.assertNotRegex(body, r"critical_enter|intr_disable|ml_set_interrupts_enabled",
                            "spin_lock_irqsave now masks interrupts; the D1 record is stale")

    @staticmethod
    def _function_body(source, name):
        match = re.search(rf"\b{re.escape(name)}\s*\([^)]*\)\s*\n?\s*\{{", source)
        if not match:
            return None
        start = source.index("{", match.end() - 1)
        depth = 0
        for i in range(start, len(source)):
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    return source[start:i + 1]
        return None


if __name__ == "__main__":
    unittest.main(verbosity=2)
