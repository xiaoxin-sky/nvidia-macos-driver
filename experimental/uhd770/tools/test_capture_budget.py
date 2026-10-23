"""Check the manual capture budget invariant against the scripts themselves.

The independent acceptance report asked for the invariant to be verified on the
slowest reachable path. No fixture here can wait 900 real seconds, so this
checks what can be checked without waiting: the arithmetic the script enforces,
that every bounded step actually uses those constants, and that the collector
accepts the value the session writes.
"""
import re
import unittest
from pathlib import Path

DEPLOY = Path(__file__).resolve().parent.parent / "acceleration" / "deployment"
SESSION = DEPLOY / "session.sh"
COLLECTOR = DEPLOY / "capture" / "collector.sh"


def constants():
    text = SESSION.read_text(encoding="utf-8")
    values = {m.group(1): int(m.group(2))
              for m in re.finditer(r"^(MANUAL_[A-Z_]+_LIMIT)=(\d+)$", text, re.M)}
    return text, values


class CaptureBudget(unittest.TestCase):
    def test_budget_covers_every_bounded_step(self):
        text, v = constants()
        required = (v["MANUAL_STARTUP_LIMIT"] + v["MANUAL_COORDINATOR_LIMIT"]
                    + v["MANUAL_OBSERVE_LIMIT"] + v["MANUAL_LOADED_AFTER_LIMIT"])
        self.assertGreaterEqual(v["MANUAL_CAPTURE_LIMIT"], required,
                                "capture window is shorter than the steps it must cover")
        self.assertIn("MANUAL_REQUIRED_LIMIT=$((MANUAL_STARTUP_LIMIT", text,
                      "the invariant is not expressed in the script")
        self.assertRegex(text, r'\[ "\$MANUAL_CAPTURE_LIMIT" -ge "\$MANUAL_REQUIRED_LIMIT" \]',
                         "the startup guard is missing")

    def test_the_bounded_steps_use_the_constants(self):
        text, _ = constants()
        for constant in ("MANUAL_COORDINATOR_LIMIT", "MANUAL_OBSERVE_LIMIT",
                         "MANUAL_LOADED_AFTER_LIMIT", "MANUAL_STARTUP_LIMIT"):
            self.assertIn('"$' + constant + '"', text, constant + " is defined but not used")
        self.assertIn("Set :ProgramArguments:3 $MANUAL_CAPTURE_LIMIT", text,
                      "the recorder is not given the budget")

    def test_collector_accepts_the_manual_budget(self):
        text = COLLECTOR.read_text(encoding="utf-8")
        _, v = constants()
        bounds = re.search(r'-ge (\d+) \] && \[ "\$CAPTURE_DURATION" -le (\d+)', text)
        self.assertIsNotNone(bounds, "collector duration bounds not found")
        self.assertLessEqual(int(bounds.group(1)), v["MANUAL_CAPTURE_LIMIT"],
                             "the budget is below the collector's minimum")
        self.assertGreaterEqual(int(bounds.group(2)), v["MANUAL_CAPTURE_LIMIT"],
                                "the budget exceeds the collector's maximum")


if __name__ == "__main__":
    unittest.main(verbosity=2)
