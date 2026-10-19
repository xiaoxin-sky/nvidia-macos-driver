"""Check this batch against clean pinned source trees without building a kext.

Copies inputs into a disposable directory, applies both patches using Git's real
patch parser, checks shared C ABI declarations, and prepares the native iterator
fixture. No driver is loaded and no original source checkout is modified.
"""

import argparse
import ast
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from prepare_pci_fixture import prepare
from enable_ccache import enable
from prepare_bridge_fixture import prepare as prepare_bridge
from prepare_irq_fixture import prepare as prepare_irq


def check(port, drm, package):
    """Apply the reviewed patch pair to disposable copies and check integration.

    port/drm must be the clean revisions in sources.json. This validates source
    integration and cross-module ABI consistency, not hardware or memory timing.
    """
    with tempfile.TemporaryDirectory(prefix="uhd770-source-check-") as temporary:
        root = Path(temporary)
        x = root / "xkpi"
        d = root / "drm-kmod"
        shutil.copytree(port, x)
        shutil.copytree(drm, d)
        for tree, patch in [(x, "xkpi.patch"), (d, "drm-kmod.patch")]:
            path = package / "patches" / patch
            subprocess.run(["git", "-C", str(tree), "apply", "--check", str(path)], check=True)
            subprocess.run(["git", "-C", str(tree), "apply", str(path)], check=True)
        for name in ["nmx_port.h", "nmx_xnu.h", "nmx_gamma_lut.h", "nmx_checked_ranges.h"]:
            assert (x / "bsdcompat/include" / name).read_text(encoding="utf-8") == (x / "bsdcompat/include/nmxxnu" / name).read_text(encoding="utf-8"), name
        for script in (package / "tools").glob("*.py"):
            ast.parse(script.read_text(encoding="utf-8"))
        prepare(x / "xnu/nmx_pci.cpp", package / "tests/pci_class_fixture.cpp.in", root / "pci-class-test.cpp")
        prepare_bridge(x / "override/src/nmx_fb_bridge.c", package / "tests/fb_bridge_fixture.c.in", root / "fb-bridge-test.c")
        prepare_irq(x / "bsdcompat/src/nmx_bus.c", package / "tests/irq_drain_fixture.c.in", root / "irq-drain-test.c")
        assert (x / "xnu/nmx_fb_interrupts.h").is_file()
        assert (x / "xnu/nmx_attach_lifecycle.h").is_file()
        enable(x)
        subprocess.run([sys.executable, str(x / "gen_flags.py"), str(d), str(root / "amd.flags")], check=True)
        flags = (root / "amd.flags").read_text(encoding="utf-8")
        assert "CONFIG_DRM_DISPLAY_DP_TUNNEL" not in flags and "CONFIG_DRM_I915_DP_TUNNEL" not in flags
        result = {
            "patch_application": "passed",
            "shared_headers": "passed",
            "python_syntax": "passed",
            "fixture_preparation": "passed; compilation/execution requires a C++ host compiler",
            "display_fixture_preparation": "passed; host behavior/concurrency execution is separate from GPU validation",
            "compiler_cache_launchers": "passed against patched pinned scripts; runtime cache probe requires macOS",
            "dp_tunnel_configuration": "passed",
            "macos_kernel_compilation": "not performed",
            "hardware_test": "not performed",
        }
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, type=Path)
    parser.add_argument("--drm", required=True, type=Path)
    parser.add_argument("--package", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    check(args.port, args.drm, args.package)
