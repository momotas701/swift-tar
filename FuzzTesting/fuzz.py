#!/usr/bin/env python3
"""Build and run libFuzzer-based fuzz targets for swift-tar.

Usage:
    ./fuzz.py build <target>              # compile the fuzzer
    ./fuzz.py run   <target> [-- <args>]  # build + run
    ./fuzz.py seed                        # generate seed corpus from real tars
"""

import argparse
import json
import os
import subprocess
import struct
import sys


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class CommandRunner:
    def __init__(self, verbose: bool = False, dry_run: bool = False):
        self.verbose = verbose
        self.dry_run = dry_run

    def run(self, args, **kwargs):
        if self.verbose or self.dry_run:
            print(" ".join(args))
        if self.dry_run:
            return
        return subprocess.run(args, **kwargs)


def available_libfuzzer_targets():
    """Return the names of all static-library products in this package."""
    result = subprocess.run(
        ["swift", "package", "dump-package"],
        stdout=subprocess.PIPE, check=True,
    )
    package = json.loads(result.stdout)
    return [
        p["name"]
        for p in package["products"]
        if "library" in p["type"]
    ]


def executable_path(target_name: str) -> str:
    return f"./.build/debug/{target_name}"


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def build(args, runner: CommandRunner):
    print(f"Building fuzzer for {args.target_name}")

    driver_flags = []
    if args.sanitizer == "coverage":
        driver_flags += [
            "-profile-generate", "-profile-coverage-mapping",
            "-sanitize=fuzzer",
        ]
    else:
        driver_flags += [f"-sanitize=fuzzer,{args.sanitizer}"]

    # Step 1 - build the static library with fuzzer instrumentation.
    build_args = ["swift", "build", "--product", args.target_name]
    for flag in driver_flags:
        build_args += ["-Xswiftc", flag]
    runner.run(build_args, check=True)

    # Step 2 - link the static library + fuzzer runtime into an executable.
    output = executable_path(args.target_name)
    link_args = [
        "swiftc",
        f"./.build/debug/lib{args.target_name}.a",
        "-g",
        "-static-stdlib",
        "-o", output,
    ]
    link_args += driver_flags
    runner.run(link_args, check=True)

    print(f"Fuzzer built successfully: {output}")


def run(args, runner: CommandRunner):
    if not args.skip_build:
        build(args, runner)

    corpus_dir = "./.build/fuzz-corpus"
    os.makedirs(corpus_dir, exist_ok=True)

    artifact_dir = f"./FailCases/{args.target_name}/"
    os.makedirs(artifact_dir, exist_ok=True)

    print(f"Running fuzzer {args.target_name}")
    fuzzer_args = [
        executable_path(args.target_name),
        corpus_dir,
        "-fork=2",
        "-timeout=5",
        "-ignore_timeouts=1",
        f"-artifact_prefix={artifact_dir}",
    ] + args.extra
    runner.run(
        fuzzer_args,
        env={**os.environ, "SWIFT_BACKTRACE": "enable=off"},
    )


def seed(args, runner: CommandRunner):
    """Generate a minimal seed corpus of synthetic tar archives."""
    import tarfile
    from io import BytesIO

    corpus_dir = "./.build/fuzz-corpus"
    os.makedirs(corpus_dir, exist_ok=True)

    def write_seed(name: str, buf: bytes):
        path = os.path.join(corpus_dir, name)
        with open(path, "wb") as f:
            f.write(buf)
        print(f"  {path}  ({len(buf)} bytes)")

    # 1) Empty archive (just two zero blocks).
    write_seed("empty.tar", b"\x00" * 1024)

    # 2) Single-file archive.
    bio = BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf:
        info = tarfile.TarInfo(name="hello.txt")
        payload = b"Hello from seed corpus!\n"
        info.size = len(payload)
        tf.addfile(info, BytesIO(payload))
    write_seed("single-file.tar", bio.getvalue())

    # 3) Archive with a directory and a symlink.
    bio = BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf:
        d = tarfile.TarInfo(name="mydir/")
        d.type = tarfile.DIRTYPE
        tf.addfile(d)
        s = tarfile.TarInfo(name="mylink")
        s.type = tarfile.SYMTYPE
        s.linkname = "mydir/target"
        tf.addfile(s)
    write_seed("dir-symlink.tar", bio.getvalue())

    # 4) GNU long-name archive.
    bio = BytesIO()
    with tarfile.open(fileobj=bio, mode="w:" ) as tf:
        long_name = "a" * 200 + ".txt"
        info = tarfile.TarInfo(name=long_name)
        payload = b"long path test"
        info.size = len(payload)
        tf.addfile(info, BytesIO(payload))
    write_seed("gnu-longname.tar", bio.getvalue())

    # 5) PAX archive.
    bio = BytesIO()
    with tarfile.open(fileobj=bio, mode="w", format=tarfile.PAX_FORMAT) as tf:
        info = tarfile.TarInfo(name="pax-file.txt")
        info.pax_headers = {"comment": "fuzz seed", "mtime": "1234567890.123"}
        payload = b"pax test data"
        info.size = len(payload)
        tf.addfile(info, BytesIO(payload))
    write_seed("pax.tar", bio.getvalue())

    # 6) A handful of random byte blobs (to exercise error paths).
    import random
    random.seed(42)
    for i in range(5):
        size = random.randint(64, 2048)
        write_seed(f"random-{i}.bin", random.randbytes(size))

    print(f"\nSeed corpus written to {corpus_dir}/")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Build and run libFuzzer targets for swift-tar",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("-n", "--dry-run", action="store_true")

    sub = parser.add_subparsers(required=True)

    targets = available_libfuzzer_targets()

    # -- build --
    bp = sub.add_parser("build", help="Build a fuzzer")
    bp.add_argument("target_name", choices=targets)
    bp.add_argument("--sanitizer", default="address")
    bp.set_defaults(func=build)

    # -- run --
    rp = sub.add_parser("run", help="Build and run a fuzzer")
    rp.add_argument("target_name", choices=targets)
    rp.add_argument("--skip-build", action="store_true")
    rp.add_argument("--sanitizer", default="address")
    rp.add_argument("extra", nargs=argparse.REMAINDER)
    rp.set_defaults(func=run)

    # -- seed --
    sp = sub.add_parser("seed", help="Generate seed corpus")
    sp.set_defaults(func=seed)

    args = parser.parse_args()
    runner = CommandRunner(verbose=args.verbose, dry_run=args.dry_run)
    args.func(args, runner)


if __name__ == "__main__":
    main()
