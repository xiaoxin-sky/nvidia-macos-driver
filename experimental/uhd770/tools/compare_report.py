"""Summarize a UHD770 session report and compare it with a recorded baseline.

Reads only. A report is the exported UHD770MVP-session-reports.* folder. The
summary covers each compute/render phase (result, marker, per-round time), the
loaded kext UUIDs, the manual exit, the post-test observation, and kernel lines
that mark a regression (panic, NullMoth mmap refusals). Comparison against the
baseline fails when a phase the baseline passed no longer passes, or a panic or
mmap refusal appears; slower rounds are reported but do not fail.

  python -I compare_report.py REPORT                    summary only
  python -I compare_report.py REPORT --baseline FILE     summary and comparison
  python -I compare_report.py REPORT --write-baseline FILE --package NAME
"""

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

PHASES = ("vulkan", "metal", "metal-render", "metal-suite")
ROUND = re.compile(r"^(?:iteration|round) \d+: verified=\d+(?: pixels)? elapsed_ms=([0-9.]+)$")
MARKER = re.compile(r"^((?:METAL_)?(?:COMPUTE|RENDER)_READBACK_VERIFIED|METAL_RENDER_SUITE_VERIFIED):")
SUBTEST = re.compile(r"^subtest (\S+): (PASS|FAIL)(?: verified=\d+ pixels elapsed_ms=([0-9.]+))?(.*)$")


def read(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def fields(text):
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


def phase_summary(report, phase):
    # "*-metal.*" must not also match "*-metal-render.*".
    runs = sorted(p for p in (report / "user-diagnostics").glob(f"*-{phase}.*") if p.is_dir())
    if not runs:
        return {"ran": False}
    run = runs[-1]
    result = fields(read(run / "result.txt"))
    log = read(run / "probe.log").splitlines()
    markers = [m.group(1) for m in map(MARKER.match, log) if m]
    rounds = [float(m.group(1)) for m in map(ROUND.match, log) if m]
    failures = [line for line in log if line.startswith("FAIL:")]
    subtests = {m.group(1): {"result": m.group(2), "ms": float(m.group(3)) if m.group(3) else None,
                             "detail": m.group(4).strip() or None}
                for m in map(SUBTEST.match, log) if m}
    summary = {"ran": True, "directory": run.name, "state": result.get("state", "missing"),
               "runner_exit": result.get("runner_exit"), "marker": markers[-1] if markers else None,
               "round_ms": rounds, "failure": failures[-1] if failures else None}
    if subtests:
        summary["subtests"] = subtests
    return summary


def kernel_lines(report, boot):
    """Count regression lines from this boot only; reports also keep older boots' captures."""
    paths = list((report / "preparation").glob(f"final-dmesg-{boot}.txt"))
    for session in (report / "system/boot-capture").glob("session-*"):
        if f"kern.bootsessionuuid: {boot}" in read(session / "boot-identity.txt"):
            paths.append(session / "kernel-stream.txt")
    panics, refusals = 0, 0
    for path in paths:
        text = read(path)
        panics += len(re.findall(r"panic\(cpu", text))
        refusals += len(re.findall(r"NullMoth mmap: ", text))
    return {"kernel_logs": len(paths), "panic_lines": panics, "mmap_refusal_lines": refusals}


def summarize(report):
    report = Path(report)
    if not (report / "user-diagnostics").is_dir():
        raise SystemExit(f"not a session report (no user-diagnostics): {report}")
    manual = {}
    for path in sorted((report / "session").glob("manual-result-*.txt")):
        manual = fields(read(path))
    uuids = {}
    for path in (report / "user-diagnostics").glob("*/loaded-UUIDs.txt"):
        for line in read(path).splitlines():
            parts = line.split()
            if len(parts) == 2:
                uuids[parts[0]] = parts[1]
    observation = {}
    for path in sorted((report / "preparation").glob("post-test-observation-*.txt")):
        observation = fields(read(path))
    # Read-only scan-out snapshots NMXGPU publishes before and after i915 attaches (informational, never compared).
    display = {}
    for path in (report / "preparation").glob("final-NMXGPU-*.txt"):
        for m in re.finditer(r'"nmxdiag-display-(\w+)" = "([^"]*)"', read(path)):
            display[m.group(1)] = m.group(2)
    identity = fields(read(report / "boot-identity.txt").replace(": ", "="))
    boot = identity.get("kern.bootsessionuuid", "")
    summary = {"report": report.name, "boot": boot, "boot_args": identity.get("kern.bootargs"),
               "manual_exit": manual.get("manual_exit"),
               "phases": {phase: phase_summary(report, phase) for phase in PHASES},
               "loaded_uuids": dict(sorted(uuids.items())),
               "observation": {k: observation.get(k) for k in ("observation_limit_s", "observation_end")},
               "display_snapshot": display}
    summary.update(kernel_lines(report, boot))
    return summary


def passed(phase):
    return phase.get("state") == "verified-readback" and phase.get("runner_exit") == "0" and phase.get("marker")


def compare(current, baseline):
    """Return (regressions, notes) of the current summary against the baseline."""
    regressions, notes = [], []
    for name in PHASES:
        old, new = baseline["phases"].get(name, {"ran": False}), current["phases"][name]
        if passed(old) and not passed(new):
            regressions.append(f"{name}: baseline passed, now {new.get('state', 'not run')}"
                               + (f" ({new['failure']})" if new.get("failure") else ""))
        elif passed(new) and not passed(old):
            notes.append(f"{name}: passes now; the baseline had no pass")
        for subtest, outcome in old.get("subtests", {}).items():
            now = new.get("subtests", {}).get(subtest, {}).get("result")
            if outcome["result"] == "PASS" and now != "PASS":
                regressions.append(f"{name}/{subtest}: baseline passed, now {now or 'not run'}")
        if passed(old) and passed(new) and old.get("round_ms") and new.get("round_ms"):
            before, after = statistics.median(old["round_ms"]), statistics.median(new["round_ms"])
            line = f"{name}: median round {after:.3f} ms (baseline {before:.3f} ms)"
            notes.append(line + (" - more than 3x slower" if after > 3 * before else ""))
    for key in ("panic_lines", "mmap_refusal_lines"):
        if current[key] > baseline.get(key, 0):
            regressions.append(f"{key}: {current[key]} (baseline {baseline.get(key, 0)})")
    for bundle, uuid in current["loaded_uuids"].items():
        if baseline["loaded_uuids"].get(bundle) not in (None, uuid):
            notes.append(f"{bundle}: loaded UUID {uuid} differs from baseline {baseline['loaded_uuids'][bundle]}")
    return regressions, notes


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--write-baseline", type=Path)
    parser.add_argument("--package", help="package name recorded with --write-baseline")
    args = parser.parse_args()
    current = summarize(args.report)
    print(json.dumps(current, indent=2, ensure_ascii=False))
    if args.write_baseline:
        if not args.package:
            parser.error("--write-baseline needs --package")
        if args.write_baseline.exists():
            parser.error(f"{args.write_baseline} exists; baselines are never overwritten")
        args.write_baseline.write_text(json.dumps(dict(current, package=args.package), indent=2, ensure_ascii=False)
                                       + "\n", encoding="utf-8", newline="\n")
        print(f"baseline written: {args.write_baseline}")
    if args.baseline:
        regressions, notes = compare(current, json.loads(args.baseline.read_text(encoding="utf-8")))
        for line in notes:
            print("NOTE:", line)
        for line in regressions:
            print("REGRESSION:", line)
        print("RESULT:", "REGRESSION" if regressions else "NO REGRESSION")
        return 1 if regressions else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
