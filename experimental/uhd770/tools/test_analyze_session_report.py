"""Regression tests for the session-report analyzer.

These encode the failures the independent acceptance report reproduced: the tool
must never report success for a run that failed, and must never read an older
session's success marker as the current run's result.
"""
import datetime
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "analyze_session_report.py"


def epoch(stamp):
    """The instant named by an evidence stamp such as 20261021T120000Z."""
    return datetime.datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(
        tzinfo=datetime.timezone.utc).timestamp()


def build(root, sessions, probes):
    """sessions: list of dicts; probes: list of dicts."""
    diag = root / "user-diagnostics"
    diag.mkdir(parents=True, exist_ok=True)
    for s in sessions:
        d = diag / s["dir"]
        d.mkdir()
        lines = [f"boot={s.get('boot', 'BOOT')}", "mode=manual"]
        if s.get("gpu_started", True):
            lines.append("gpu_started=true")
        if s.get("exit") is not None:
            lines.append(f"coordinator_exit={s['exit']}")
        (d / "session.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        if s.get("evidence"):
            (d / "vulkan-runner.txt").write_text(
                f"Evidence directory: /Users/x/Library/Logs/UHD770MVP/{s['evidence']}\n", encoding="utf-8")
        (d / "registry-latest.txt").write_text(
            "+-o NMXGPU  <class NMXGPU, registered, matched, active>\n", encoding="utf-8")
        if "mtime" in s:
            os.utime(d / "session.txt", (s["mtime"], s["mtime"]))
    for p in probes:
        d = diag / p["dir"]
        d.mkdir()
        (d / "system.txt").write_text(
            f"phase=vulkan\nuid=501\nProductVersion:\t15.7.9\n", encoding="utf-8")
        (d / "probe.log").write_text(p.get("log", ""), encoding="utf-8")
        (d / "loaded-UUIDs.txt").write_text("com.nullmoth.NMXGPU 5d0b123e\n", encoding="utf-8")
        if p.get("started", True):
            (d / "probe-start.marker").write_text("", encoding="utf-8")


def run(root, panic=None):
    args = [sys.executable, str(TOOL), str(root)]
    if panic:
        args += ["--panic", str(panic)]
    out = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return out.stdout + out.stderr


class AnalyzerRules(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "UHD770MVP-session-reports.TEST"

    def tearDown(self):
        self.tmp.cleanup()

    def test_old_success_does_not_mask_new_failure(self):
        # the reviewer's repro: the newer session failed, an older one succeeded,
        # and the directory names sort the wrong way round
        build(
            self.root,
            sessions=[
                {"dir": "manual-FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", "exit": 0,
                 "evidence": "20261021T120000Z-vulkan.OLD001"},
                {"dir": "manual-00000000-0000-0000-0000-000000000000", "exit": 2,
                 "evidence": "20261021T180000Z-vulkan.NEW001"},
            ],
            probes=[
                {"dir": "20261021T120000Z-vulkan.OLD001",
                 "log": "probe_version=1\nCOMPUTE_READBACK_VERIFIED: vendor=8086 device=4680\n"},
                {"dir": "20261021T180000Z-vulkan.NEW001",
                 "log": "probe_version=1\nFAIL: enumerate physical count: VkResult=-3\n"},
            ],
        )
        text = run(self.root)
        self.assertIn("verdict (failure)", text)
        self.assertIn("exited 2", text)
        self.assertNotIn("verdict (success)", text)

    def test_current_success_without_its_own_marker_is_failure(self):
        build(
            self.root,
            sessions=[
                {"dir": "manual-AAAA", "exit": 0, "evidence": "20261021T120000Z-vulkan.OLD001"},
                {"dir": "manual-BBBB", "exit": 0, "evidence": "20261021T180000Z-vulkan.NEW001"},
            ],
            probes=[
                {"dir": "20261021T120000Z-vulkan.OLD001",
                 "log": "COMPUTE_READBACK_VERIFIED: vendor=8086\n"},
                {"dir": "20261021T180000Z-vulkan.NEW001", "log": "probe_version=1\n"},
            ],
        )
        text = run(self.root)
        self.assertIn("verdict (failure)", text)
        self.assertIn("older session", text)

    def test_success_needs_current_run_marker_and_exit_zero(self):
        build(
            self.root,
            sessions=[{"dir": "manual-AAAA", "exit": 0, "evidence": "20261022T120000Z-vulkan.OK001"}],
            probes=[{"dir": "20261022T120000Z-vulkan.OK001",
                     "log": "probe_version=1\nCOMPUTE_READBACK_VERIFIED: vendor=8086 device=4680\n"}],
        )
        text = run(self.root)
        self.assertIn("verdict (success)", text)

    def test_missing_exit_code_is_incomplete(self):
        build(
            self.root,
            sessions=[{"dir": "manual-AAAA", "exit": None, "evidence": "20261022T120000Z-vulkan.OK001"}],
            probes=[{"dir": "20261022T120000Z-vulkan.OK001",
                     "log": "COMPUTE_READBACK_VERIFIED: vendor=8086\n"}],
        )
        text = run(self.root)
        self.assertIn("verdict (incomplete)", text)
        self.assertIn("no coordinator exit code", text)

    def test_marker_but_nonzero_exit_is_failure(self):
        build(
            self.root,
            sessions=[{"dir": "manual-AAAA", "exit": 124, "evidence": "20261022T120000Z-vulkan.OK001"}],
            probes=[{"dir": "20261022T120000Z-vulkan.OK001",
                     "log": "COMPUTE_READBACK_VERIFIED: vendor=8086\n"}],
        )
        text = run(self.root)
        self.assertIn("verdict (failure)", text)
        self.assertIn("teardown did not end with exit 0", text)

    def test_named_evidence_missing_is_incomplete(self):
        build(
            self.root,
            sessions=[{"dir": "manual-AAAA", "exit": 0, "evidence": "20261022T120000Z-vulkan.GONE01"}],
            probes=[{"dir": "20261022T120000Z-vulkan.OTHER1",
                     "log": "COMPUTE_READBACK_VERIFIED: vendor=8086\n"}],
        )
        text = run(self.root)
        self.assertIn("verdict (incomplete)", text)
        self.assertIn("not in the report", text)

    def test_newest_session_without_evidence_does_not_lose_to_an_older_success(self):
        # a run that stops before naming a probe directory has no evidence
        # stamp; ordering it by "no stamp" would put it before every stamped
        # session and hand the verdict to an older success
        build(
            self.root,
            sessions=[
                {"dir": "manual-FFFFFFFF", "exit": 0, "evidence": "20261021T120000Z-vulkan.OLD001",
                 "mtime": epoch("20261021T110000Z")},
                {"dir": "manual-00000000", "exit": 2, "mtime": epoch("20261021T190000Z")},
            ],
            probes=[{"dir": "20261021T120000Z-vulkan.OLD001",
                     "log": "COMPUTE_READBACK_VERIFIED: vendor=8086 device=4680\n"}],
        )
        text = run(self.root)
        self.assertIn("verdict (failure)", text)
        self.assertIn("exited 2", text)
        self.assertNotIn("verdict (success)", text)

    def test_newest_session_without_evidence_and_no_exit_is_incomplete(self):
        build(
            self.root,
            sessions=[
                {"dir": "manual-FFFFFFFF", "exit": 0, "evidence": "20261021T120000Z-vulkan.OLD001",
                 "mtime": epoch("20261021T110000Z")},
                {"dir": "manual-00000000", "exit": None, "mtime": epoch("20261021T190000Z")},
            ],
            probes=[{"dir": "20261021T120000Z-vulkan.OLD001",
                     "log": "COMPUTE_READBACK_VERIFIED: vendor=8086\n"}],
        )
        text = run(self.root)
        self.assertIn("verdict (incomplete)", text)
        self.assertNotIn("verdict (success)", text)

    def test_panic_dominates(self):
        build(
            self.root,
            sessions=[{"dir": "manual-AAAA", "exit": 0, "evidence": "20261022T120000Z-vulkan.OK001"}],
            probes=[{"dir": "20261022T120000Z-vulkan.OK001", "log": "COMPUTE_READBACK_VERIFIED\n"}],
        )
        panic = Path(self.tmp.name) / "panic.txt"
        panic.write_text("Panic(CPU 5, time 1): NMIPI for unresponsive processor\n"
                         "Panicked task 0x1: pid 1: probe\n"
                         "0xffffff80 : 0xffffff801bf39241 mach_kernel : _interrupt + 0xc1\n",
                         encoding="utf-8")
        text = run(self.root, panic=panic)
        self.assertIn("verdict (failure)", text)
        self.assertIn("panicked", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
