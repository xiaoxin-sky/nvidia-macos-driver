"""Fixture checks for compare_report.py; no report from a real machine is needed."""

import tempfile
import unittest
from pathlib import Path

import compare_report

BOOT = "B00T"


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def report(root, metal_passes=True, kernel=""):
    write(root / "boot-identity.txt", f"kern.bootsessionuuid: {BOOT}\nkern.bootargs: -v nmxintel=1\n")
    write(root / "session/manual-result-B00T.txt", f"boot={BOOT}\nmanual_exit={0 if metal_passes else 2}\n")
    write(root / "user-diagnostics/1-vulkan.a/result.txt", "state=verified-readback\nrunner_exit=0\n")
    write(root / "user-diagnostics/1-vulkan.a/probe.log",
          "iteration 1: verified=4099 elapsed_ms=1.000\nCOMPUTE_READBACK_VERIFIED: x\n")
    write(root / "user-diagnostics/1-vulkan.a/loaded-UUIDs.txt", "com.nullmoth.NMXGPU aaa\n")
    metal = root / "user-diagnostics/2-metal.b"
    if metal_passes:
        write(metal / "result.txt", "state=verified-readback\nrunner_exit=0\n")
        write(metal / "probe.log", "round 1: verified=4096 elapsed_ms=10.000\nMETAL_COMPUTE_READBACK_VERIFIED: x\n")
    else:
        write(metal / "result.txt", "state=failed\nrunner_exit=2\n")
        write(metal / "probe.log", "FAIL: no device\n")
    write(root / "user-diagnostics/3-metal-render.c/result.txt", "state=verified-readback\nrunner_exit=0\n")
    write(root / "user-diagnostics/3-metal-render.c/probe.log",
          "round 1: verified=4096 pixels elapsed_ms=5.000\nMETAL_RENDER_READBACK_VERIFIED: x\n")
    suite = root / "user-diagnostics/4-metal-suite.d"
    write(suite / "result.txt", "state=failed\nrunner_exit=3\n")
    write(suite / "probe.log", "subtest texture: PASS verified=4096 pixels elapsed_ms=2.000\n"
                               "subtest iosurface: FAIL Metal refused an IOSurface-backed render target\n")
    write(root / f"preparation/final-dmesg-{BOOT}.txt", kernel)
    # An older boot's capture must not count against this report.
    write(root / "system/boot-capture/session-old/boot-identity.txt", "kern.bootsessionuuid: OLD\n")
    write(root / "system/boot-capture/session-old/kernel-stream.txt", "NullMoth mmap: stage=args err=22\n")
    return root


class CompareReportTests(unittest.TestCase):
    def test_phases_are_separated_and_older_boots_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            summary = compare_report.summarize(report(Path(temporary) / "r"))
        self.assertEqual(summary["phases"]["metal"]["marker"], "METAL_COMPUTE_READBACK_VERIFIED")
        self.assertEqual(summary["phases"]["metal-render"]["marker"], "METAL_RENDER_READBACK_VERIFIED")
        self.assertEqual(summary["phases"]["metal-render"]["round_ms"], [5.0])
        self.assertEqual(summary["mmap_refusal_lines"], 0)
        self.assertEqual(summary["loaded_uuids"], {"com.nullmoth.NMXGPU": "aaa"})
        subtests = summary["phases"]["metal-suite"]["subtests"]
        self.assertEqual(subtests["texture"], {"result": "PASS", "ms": 2.0, "detail": None})
        self.assertEqual(subtests["iosurface"]["result"], "FAIL")

    def test_lost_pass_and_new_panic_are_regressions(self):
        with tempfile.TemporaryDirectory() as temporary:
            baseline = compare_report.summarize(report(Path(temporary) / "base"))
            current = compare_report.summarize(report(Path(temporary) / "now", metal_passes=False,
                                                      kernel="panic(cpu 0 caller 0x0)\n"))
        regressions, _ = compare_report.compare(current, baseline)
        self.assertTrue(any(line.startswith("metal:") for line in regressions))
        self.assertTrue(any(line.startswith("panic_lines") for line in regressions))

    def test_identical_report_has_no_regression(self):
        with tempfile.TemporaryDirectory() as temporary:
            summary = compare_report.summarize(report(Path(temporary) / "r"))
        self.assertEqual(compare_report.compare(summary, summary)[0], [])


if __name__ == "__main__":
    unittest.main()
