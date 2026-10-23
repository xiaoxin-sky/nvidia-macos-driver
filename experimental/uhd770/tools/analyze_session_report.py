"""Summarize a UHD770MVP session report into the facts needed to decide the next step.

Usage:
  python analyze_session_report.py <report-dir> [--panic <panic-file>] [--json]

Rules this tool follows, because getting them wrong hides a failure:

* The current session is chosen by evidence time, not by directory name. Session
  directories are named after the boot UUID, which is not ordered; the probe
  evidence directory a session names starts with a UTC stamp, so that stamp is
  the only trustworthy ordering in the report.
* A session's probe evidence is only the directory that session named. Other
  probe directories are history and can never make the current run pass.
* A missing coordinator exit code means the run is incomplete, not successful.
* Success requires all of: the current session, exit code 0, and the success
  marker at the start of a line in that session's own probe log.
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path

STAMP = re.compile(r"(\d{8}T\d{6}Z)")
MARKER = "COMPUTE_READBACK_VERIFIED"


def read(path, limit=None):
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    return text[:limit] if limit else text


def sessions_in(report):
    """Collect manual sessions with the ordering facts, newest last."""
    out = []
    diag = report / "user-diagnostics"
    if not diag.is_dir():
        return out
    for path in sorted(diag.glob("manual-*")):
        if not path.is_dir():
            continue
        state = read(path / "session.txt") or ""
        runner = read(path / "vulkan-runner.txt") or ""
        evidence = re.search(r"Evidence directory:\s*(\S+)", runner)
        stated = re.search(r"Evidence directory:\s*(\S+)", state)
        named = evidence.group(1) if evidence else (stated.group(1) if stated else None)
        exits = [line.split("=", 1)[1].strip() for line in state.splitlines()
                 if line.startswith("coordinator_exit=")]
        stamp = None
        if named:
            m = STAMP.search(Path(named).name)
            if m:
                stamp = m.group(1)
        if stamp is None:
            # fall back to the probe directory this session names, if it is present
            for cand in diag.iterdir():
                if cand.is_dir() and cand.name.startswith("manual-"):
                    continue
                if named and cand.name == Path(named).name:
                    m = STAMP.search(cand.name)
                    if m:
                        stamp = m.group(1)
        try:
            mtime = (path / "session.txt").stat().st_mtime
        except OSError:
            mtime = 0.0
        out.append({
            "dir": path.name,
            "path": path,
            "boot": next((line.split("=", 1)[1] for line in state.splitlines()
                          if line.startswith("boot=")), None),
            "gpu_started": "gpu_started=true" in state,
            "coordinator_exit": exits[-1] if exits else None,
            "evidence_named": named,
            "evidence_stamp": stamp,
            "stamp_source": "probe evidence" if stamp else "session file time",
            "mtime": mtime,
            "registry_ready": bool(re.search(r"NMXGPU.*registered, matched, active",
                                             read(path / "registry-latest.txt") or "")),
        })
    return out


def mtime_stamp(session):
    """Express the session file's own timestamp in the same form as the evidence stamp.

    A session that failed before it could name a probe directory has no
    evidence stamp, and treating that as "older than everything" is exactly how
    an old success gets reported for a newer failure. The file timestamp is a
    real UTC instant, so both kinds of session can be ordered together.
    """
    try:
        return datetime.datetime.fromtimestamp(session["mtime"], datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    except (OverflowError, OSError, ValueError):
        return "00000000T000000Z"


def order_key(session):
    """Order by evidence time when present, otherwise by the session file's time."""
    return (session["evidence_stamp"] or mtime_stamp(session),)


def probe_report(directory):
    system = read(directory / "system.txt")
    if system is None:
        return None
    fields = dict(line.split("=", 1) for line in system.splitlines() if "=" in line)
    log = read(directory / "probe.log")
    lines = (log or "").splitlines()
    return {
        "dir": directory.name,
        "phase": fields.get("phase"),
        "uid": fields.get("uid"),
        "macos": next((line.split(":", 1)[1].strip() for line in system.splitlines()
                       if line.startswith("ProductVersion")), None),
        "loaded_uuids": (read(directory / "loaded-UUIDs.txt") or "").strip() or None,
        "probe_started": (directory / "probe-start.marker").is_file(),
        "probe_log_bytes": (directory / "probe.log").stat().st_size
        if (directory / "probe.log").is_file() else None,
        "marker_at_line_start": any(line.startswith(MARKER) for line in lines),
        "first_lines": lines[:6],
        "mismatch_lines": [line for line in lines
                           if "mismatch" in line.lower() or line.startswith("FAIL")][:6],
        "drm_discovery_lines": [line for line in lines if "NMX DRM discovery" in line][:12],
        "loader_errors": [line for line in lines
                          if "severity=0x1000" in line or "ERROR:" in line][:6],
    }


def kernel_failures(report, limit=8):
    """The port's own kernel-side failure lines, from both captured records."""
    found, streams, dmesgs = [], 0, 0
    pattern = re.compile(
        r"NullMoth devfs:"
        r"|NullMoth drm:"
        r"|guard retained|no_framebuffer"
        r"|NullMoth xkpi:.*(?:fail|error=|cannot)"
    )
    for path in report.rglob("kernel-stream.txt"):
        streams += 1
        for line in (read(path) or "").splitlines():
            if pattern.search(line) and line.strip() not in found:
                found.append(line.strip())
    for path in report.rglob("dmesg-*.txt"):
        dmesgs += 1
        for line in (read(path) or "").splitlines():
            if pattern.search(line) and line.strip() not in found:
                found.append(line.strip())
    return {"streams_scanned": streams, "dmesg_scanned": dmesgs, "lines": found[:limit]}


def panic_head(path):
    text = read(path, 4000)
    if text is None:
        return None
    lines = [line.rstrip() for line in text.splitlines()]
    head = next((line for line in lines if line.startswith("Panic(")), lines[0] if lines else None)
    task = next((line for line in lines if line.startswith("Panicked task")), None)
    frames = [line.strip() for line in lines
              if re.match(r"^0x[0-9a-f]+ : 0x[0-9a-f]+", line.strip())][:6]
    return {"headline": head, "task": task, "frames": frames}


def decide(report, current, probe, others_with_marker, panic):
    """Return (status, verdict). Status is one of success, failure, incomplete."""
    if panic:
        return "failure", f"the machine panicked: {panic['headline']}"
    if current is None:
        return "incomplete", "no manual session in the report: compute was never started"
    if current["coordinator_exit"] is None:
        return "incomplete", (
            f"the current session {current['dir']} recorded no coordinator exit code, so the run did not finish")
    code = current["coordinator_exit"]
    if code != "0":
        extra = ""
        if probe is not None and probe["marker_at_line_start"]:
            extra = " (its probe did print the success marker, but teardown did not end with exit 0)"
        return "failure", f"the coordinator exited {code}{extra}"
    if not current["gpu_started"]:
        return "failure", "the session exited 0 but never reached the probe"
    if probe is None:
        if not current["evidence_named"]:
            return "incomplete", (
                "the current session never named a probe directory, which means it stopped before compute could start; "
                "an older session's marker is not this run's result")
        return "incomplete", (
            "the current session named an evidence directory that is not in the report, so its own probe result "
            "cannot be checked")
    if probe["marker_at_line_start"]:
        return "success", "the current session exited 0 and its own probe printed the success marker"
    if others_with_marker:
        return "failure", (
            "the current session exited 0 but its own probe has no success marker; an older session in this report "
            f"does ({', '.join(others_with_marker)}), and that is not this run's result")
    if probe["probe_log_bytes"] == 0:
        return "failure", (
            "the current session exited 0 but its probe log is empty, so a kernel-level event interrupted it")
    return "failure", "the current session exited 0 but its probe printed no success marker"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report", type=Path)
    ap.add_argument("--panic", type=Path)
    ap.add_argument("--json", action="store_true", help="also print a machine-readable summary")
    args = ap.parse_args()
    report = args.report
    if not report.is_dir():
        raise SystemExit(f"not a directory: {report}")

    sessions = sessions_in(report)
    ordered = sorted(sessions, key=order_key)
    current = ordered[-1] if ordered else None

    probes, by_name = [], {}
    diag = report / "user-diagnostics"
    if diag.is_dir():
        for path in sorted(diag.iterdir()):
            if not path.is_dir() or path.name.startswith("manual-"):
                continue
            p = probe_report(path)
            if p is not None:
                probes.append(p)
                by_name[p["dir"]] = p

    current_probe = None
    if current and current["evidence_named"]:
        current_probe = by_name.get(Path(current["evidence_named"]).name)

    others = [p["dir"] for p in probes
              if p["marker_at_line_start"] and (current_probe is None or p["dir"] != current_probe["dir"])]
    panic = panic_head(args.panic) if args.panic else None
    status, verdict = decide(report, current, current_probe, others, panic)

    print(f"report: {report.name}")
    stage_state = read(report / "system" / "stage-state.txt")
    if stage_state:
        print("stage-state:", "; ".join(l.replace("=", ": ") for l in stage_state.splitlines() if l))

    print("\nsessions (oldest first, by probe evidence stamp or session file time):")
    for s in ordered:
        mark = "*" if current is not None and s["dir"] == current["dir"] else " "
        print(f" {mark} {s['dir']}  stamp={s['evidence_stamp'] or mtime_stamp(s)} "
              f"({s['stamp_source']})  exit={s['coordinator_exit']}  gpu_started={s['gpu_started']}")
    if not ordered:
        print("   (none)")

    if current:
        print(f"\ncurrent session: {current['dir']}")
        print(f"  evidence it named: {current['evidence_named']}")
        if current_probe:
            p = current_probe
            print(f"  probe: phase={p['phase']} uid={p['uid']} macOS={p['macos']} "
                  f"started={p['probe_started']} log_bytes={p['probe_log_bytes']} "
                  f"marker_at_line_start={p['marker_at_line_start']}")
            print(f"  loaded UUIDs: {p['loaded_uuids']}")
            for line in p["first_lines"]:
                print(f"    | {line}")
            for line in p["mismatch_lines"]:
                print(f"    ! {line}")
            for line in p["drm_discovery_lines"]:
                print(f"    discovery | {line}")
            for line in p["loader_errors"]:
                print(f"    loader ! {line}")
        else:
            print("  probe: not found in this report")

    if others:
        print(f"\nolder sessions carrying a success marker (not counted): {', '.join(others)}")

    if panic:
        print("\npanic:")
        print(f"  {panic['headline']}")
        if panic["task"]:
            print(f"  {panic['task']}")
        for frame in panic["frames"]:
            print(f"  {frame}")

    kernel = kernel_failures(report)
    print(f"\nkernel-side failures (scanned {kernel['streams_scanned']} streams, "
          f"{kernel['dmesg_scanned']} dmesg snapshots):")
    if kernel["lines"]:
        for line in kernel["lines"]:
            print(f"  {line}")
        if any("NullMoth devfs: open" in line for line in kernel["lines"]):
            print("  -> a device open failed inside the port")
    elif kernel["streams_scanned"] == 0 and kernel["dmesg_scanned"] == 0:
        print("  neither a kernel stream nor a dmesg snapshot was captured, so their absence proves nothing")
    else:
        print("  none captured; if a node open was refused, that refusal did not report through the port's error path")

    print(f"\nverdict ({status}): {verdict}")
    if args.json:
        print(json.dumps({
            "status": status, "verdict": verdict,
            "current_session": current["dir"] if current else None,
            "current_exit": current["coordinator_exit"] if current else None,
            "current_marker": bool(current_probe and current_probe["marker_at_line_start"]),
            "older_marker_sessions": others,
        }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
