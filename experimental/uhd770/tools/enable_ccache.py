"""Route the pinned port's compiler entry points through ccache on the runner.

Only the compiler launch changes. All source enumeration, generated flags,
headers, per-source failure accounting and final linking remain authoritative.
Fail if the historical script shape changes instead of bypassing an entry point.
"""

import argparse
from pathlib import Path


def enable(root):
    """Wrap all five active C/C++ launchers, leaving their arguments unchanged.

    root is the freshly staged and patched xkpi tree. xcrun resolves the actual
    compiler before ccache sees it, so compiler_check=content checks Clang itself.
    This deliberately does not wrap the linker or reuse final kext artifacts.
    """
    scripts = {
        "cc.sh": "clang",
        "cc-i915.sh": "clang",
        "cclk.sh": "clang",
        "ccsrc.sh": "clang",
        "ccxx.sh": "clang++",
    }
    for name, compiler in scripts.items():
        path = root / name
        source = path.read_text(encoding="utf-8")
        anchor = f"exec xcrun {compiler} "
        assert source.count(anchor) == 1, name
        path.write_text(
            source.replace(anchor, f'exec ccache "$(xcrun --find {compiler})" ', 1),
            encoding="utf-8",
        )
        print(f"ccache launcher enabled: {name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    enable(parser.parse_args().root)
