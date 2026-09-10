#!/usr/bin/env python3
"""Launch a packaged native app and retain validated window-smoke evidence."""

import json
import hashlib
from pathlib import Path
import platform
import subprocess
import sys
import tempfile


def usage() -> int:
    print(
        "usage: run-packaged-window-smoke.py <app-bundle> [evidence-json]",
        file=sys.stderr,
    )
    return 2


def find_evidence(output: str) -> dict[str, object] | None:
    for line in reversed(output.splitlines()):
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict) and payload.get("probe") == "native-macos-packaged-window":
            return payload
    return None


def write_evidence(path: str | None, payload: dict[str, object]) -> None:
    if path is None:
        return
    evidence_path = Path(path)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def validate(payload: dict[str, object]) -> None:
    window = payload.get("window")
    if payload.get("schemaVersion") != 1 or payload.get("status") != "passed":
        raise ValueError("the packaged window probe did not report a passing schema-v1 result")
    if payload.get("bundleIdentifier") != "com.lumen.editor.native-preview":
        raise ValueError("the packaged window probe reported an unexpected bundle identity")
    if not isinstance(payload.get("editorSessionCount"), int) or payload["editorSessionCount"] < 1:
        raise ValueError("the packaged window probe did not connect an editor session")
    if not isinstance(payload.get("mainActorRoundTrips"), int) or payload["mainActorRoundTrips"] < 2:
        raise ValueError("the packaged window probe did not prove main-actor responsiveness")
    if not isinstance(window, dict):
        raise ValueError("the packaged window probe did not report a window")
    if window.get("visible") is not True or window.get("canBecomeKey") is not True:
        raise ValueError("the packaged editor window was not visible and key-capable")
    if window.get("hasContentView") is not True:
        raise ValueError("the packaged editor window had no content view")
    if not isinstance(window.get("width"), int) or window["width"] <= 0:
        raise ValueError("the packaged editor window had an invalid width")
    if not isinstance(window.get("height"), int) or window["height"] <= 0:
        raise ValueError("the packaged editor window had an invalid height")


def main() -> int:
    if len(sys.argv) not in (2, 3):
        return usage()
    app_bundle = Path(sys.argv[1])
    evidence_path = sys.argv[2] if len(sys.argv) == 3 else None
    if not app_bundle.is_dir() or app_bundle.suffix != ".app":
        print(f"Packaged app bundle does not exist: {app_bundle}", file=sys.stderr)
        return 1
    executable = app_bundle / "Contents" / "MacOS" / "LumenEditor"
    if not executable.is_file():
        print(f"Packaged app executable does not exist: {executable}", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix="lumen-window-smoke-") as temporary:
        stdout_path = Path(temporary) / "stdout.log"
        stderr_path = Path(temporary) / "stderr.log"
        stdout_path.touch(mode=0o600)
        stderr_path.touch(mode=0o600)
        try:
            result = subprocess.run(
                [
                    "/usr/bin/open", "-W", "-n",
                    "--stdout", str(stdout_path),
                    "--stderr", str(stderr_path),
                    str(app_bundle), "--args", "--lumen-window-smoke",
                ],
                capture_output=True,
                text=True,
                timeout=35,
                check=False,
            )
        except subprocess.TimeoutExpired:
            stdout = stdout_path.read_text(encoding="utf-8", errors="replace")
            stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
            sys.stdout.write(stdout)
            sys.stderr.write(stderr)
            sys.stderr.write("Packaged window smoke timed out after 35 seconds.\n")
            write_evidence(evidence_path, {
                "schemaVersion": 1,
                "probe": "native-macos-packaged-window",
                "status": "failed",
                "failure": "The packaged application did not complete the window smoke within 35 seconds.",
            })
            return 1
        stdout = stdout_path.read_text(encoding="utf-8", errors="replace")
        stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
        if result.stdout:
            stdout += result.stdout
        if result.stderr:
            stderr += result.stderr
        sys.stdout.write(stdout)
        sys.stderr.write(stderr)
    payload = find_evidence(stdout) or find_evidence(stderr)
    if result.returncode != 0:
        write_evidence(evidence_path, payload or {
            "schemaVersion": 1,
            "probe": "native-macos-packaged-window",
            "status": "failed",
            "failure": f"The packaged application exited with status {result.returncode}.",
        })
        return result.returncode
    if payload is None:
        print("Packaged window smoke emitted no structured evidence.", file=sys.stderr)
        write_evidence(evidence_path, {
            "schemaVersion": 1,
            "probe": "native-macos-packaged-window",
            "status": "failed",
            "failure": "The packaged application emitted no structured window evidence.",
        })
        return 1
    try:
        validate(payload)
    except ValueError as error:
        print(f"Invalid packaged window smoke evidence: {error}", file=sys.stderr)
        write_evidence(evidence_path, {
            "schemaVersion": 1,
            "probe": "native-macos-packaged-window",
            "status": "failed",
            "failure": f"Invalid packaged window smoke evidence: {error}",
            "reportedEvidence": payload,
        })
        return 1
    payload["gracefulExit"] = True
    payload["architecture"] = platform.machine()
    payload["executableSha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()

    write_evidence(evidence_path, payload)
    print("Packaged window smoke passed and exited through the app lifecycle.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
