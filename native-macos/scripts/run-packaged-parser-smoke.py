#!/usr/bin/env python3
"""Run the packaged parser smoke with a hard outer timeout."""

import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: run-packaged-parser-smoke.py <app-executable>", file=sys.stderr)
        return 2
    try:
        result = subprocess.run(
            [sys.argv[1], "--lumen-parser-smoke"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or b""
        stderr = error.stderr or b""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        sys.stdout.write(stdout)
        sys.stderr.write(stderr)
        sys.stderr.write("Packaged parser smoke timed out after 10 seconds.\n")
        return 1
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
