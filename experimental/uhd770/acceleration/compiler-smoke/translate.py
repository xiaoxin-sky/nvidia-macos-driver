"""Exercise the built Rust translator ABI offline, without loading a GPU ICD.

The caller supplies decoded textual AIR, not bitcode. The hand-authored fixture
tests the translator ABI alone; genuine Apple AIR must first pass the independent
Apple compiler/LLVM-reader steps. Rust-owned output is always freed by the matching
export, including on validation/write failures. The supervising process bounds a
native crash or hang without pretending it can recover a corrupted native heap.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys


def validate_spirv(data):
    """Check SPIR-V framing and require a compute entry point and buffer store.

    This intentionally does not replace spirv-val or execute the shader. It rejects
    empty/short/partial native output before writing the diagnostic artifact.
    """
    if len(data) < 20 or len(data) % 4:
        raise ValueError("translator returned an invalid SPIR-V byte length")
    words = struct.unpack("<" + "I" * (len(data) // 4), data)
    if words[0] != 0x07230203 or words[4] != 0:
        raise ValueError("translator returned an invalid SPIR-V header")
    if not 0x00010000 <= words[1] <= 0x00010600 or words[3] == 0:
        raise ValueError("invalid SPIR-V version or ID bound")
    position, instructions, compute, store = 5, 0, False, False
    while position < len(words):
        word_count, opcode = words[position] >> 16, words[position] & 0xFFFF
        if not word_count or position + word_count > len(words):
            raise ValueError("truncated or zero-length SPIR-V instruction")
        if opcode == 15:  # OpEntryPoint: execution model, function ID, name...
            if word_count < 4:
                raise ValueError("truncated SPIR-V entry point")
            compute |= words[position + 1] == 5  # ExecutionModel GLCompute.
        store |= opcode == 62  # OpStore must survive this buffer-writing shader.
        instructions += 1
        position += word_count
    if not compute or not store:
        raise ValueError("SPIR-V lacks the expected compute entry point or store")
    return {"version": f"0x{words[1]:08x}", "id_bound": words[3],
            "instructions": instructions, "bytes": len(data)}


def translate(library_path, input_path, output_path, kind):
    """Call nvmtl_translate with its exact pointer/size ABI and matching free.

    These signatures match wrapper/src/lib.rs: output is a Rust boxed byte slice,
    so neither libc free nor a size reconstructed from copied data is valid.
    """
    raw = input_path.read_bytes()
    if not raw or len(raw) > 4 * 1024 * 1024 or b"\0" in raw:
        raise ValueError("expected nonempty NUL-free textual AIR, at most 4 MiB")
    text = raw.decode("utf-8")
    if "!air.kernel" not in text:
        raise ValueError("input has no AIR kernel metadata; decode .air bitcode first")
    if input_path == output_path:
        raise ValueError("output must not overwrite the textual AIR input")
    mode = getattr(os, "RTLD_NOW", 0) | getattr(os, "RTLD_LOCAL", 0)
    library = ctypes.CDLL(str(library_path), mode=mode)
    byte_pointer = ctypes.POINTER(ctypes.c_uint8)
    invoke = library.nvmtl_translate
    invoke.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                       ctypes.POINTER(byte_pointer), ctypes.POINTER(ctypes.c_size_t),
                       ctypes.POINTER(ctypes.c_char), ctypes.c_size_t]
    invoke.restype = ctypes.c_int32
    release = library.nvmtl_translate_free
    release.argtypes = [byte_pointer, ctypes.c_size_t]
    release.restype = None
    pointer, length = byte_pointer(), ctypes.c_size_t(0)
    error = ctypes.create_string_buffer(8192)
    try:
        result = invoke(raw, b"kernel", ctypes.byref(pointer), ctypes.byref(length),
                        error, ctypes.sizeof(error))
        if result != 0:
            raise RuntimeError(f"nvmtl_translate returned {result}: " + error.value.decode("utf-8", "replace"))
        if not pointer or not 20 <= length.value <= 64 * 1024 * 1024:
            raise ValueError("native translator returned an invalid pointer/size pair")
        binary = ctypes.string_at(pointer, length.value)
        properties = validate_spirv(binary)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(binary)
    finally:
        if pointer:
            release(pointer, length.value)
    print(json.dumps({"check": "offline-translator-abi", "input_kind": kind,
                      "library": str(library_path), "input": str(input_path),
                      "input_sha256": hashlib.sha256(raw).hexdigest(),
                      "output": str(output_path), "output_sha256": hashlib.sha256(binary).hexdigest(),
                      "spirv": properties, "gpu_executed": False}, sort_keys=True), flush=True)


def main():
    """Supervise the native call so a translator crash/hang is a failed check."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--kind", required=True, choices=["text-air", "decoded-apple-air"])
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    options = parser.parse_args()
    if not 1 <= options.timeout <= 300:
        parser.error("--timeout must be 1..300 seconds")
    paths = [path.resolve() for path in (options.library, options.input, options.output)]
    try:
        if options.worker:
            translate(*paths, options.kind)
            return 0
        invocation = [sys.executable, str(Path(__file__).resolve()), "--worker",
                      "--library", str(paths[0]), "--input", str(paths[1]),
                      "--output", str(paths[2]), "--kind", options.kind]
        result = subprocess.run(invocation, check=False, timeout=options.timeout)
        if result.returncode:
            print(f"FAIL: translator child exited {result.returncode}", file=sys.stderr)
            return 2
        return 0
    except subprocess.TimeoutExpired:
        print("FAIL: offline translator deadline exceeded", file=sys.stderr)
        return 124
    except (OSError, ValueError, RuntimeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
