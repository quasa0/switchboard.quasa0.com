#!/bin/bash
set -euo pipefail

# This verification is deliberately separate from smoke.sh: it never exercises
# credential storage, a real CLI process, account files, or authentication.
SWITCHBOARD_UI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWITCHBOARD_UI_TARGET="${1:-$SWITCHBOARD_UI_ROOT/.build/debug/Switchboard}"
SWITCHBOARD_UI_ARTIFACTS="${2:-$SWITCHBOARD_UI_ROOT/artifacts/ui-smoke}"

python3 - "$SWITCHBOARD_UI_TARGET" "$SWITCHBOARD_UI_ARTIFACTS" <<'PY'
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile

target = pathlib.Path(sys.argv[1]).expanduser().resolve()
binary = target / "Contents/MacOS/Switchboard" if target.is_dir() else target
if not binary.is_file() or not os.access(binary, os.X_OK):
    raise SystemExit(f"Build the app first. Executable not found: {binary}")

base = pathlib.Path(sys.argv[2]).expanduser().resolve()
base.mkdir(parents=True, exist_ok=True)
output = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=base))
# Specify demo mode explicitly so this launcher's isolation is visible at the call site.
process = subprocess.Popen(
    [str(binary), "--demo", "--ui-smoke-test", str(output)],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    start_new_session=True,
)
try:
    stdout, _ = process.communicate(timeout=45)
except BaseException:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)
    raise
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)

if stdout:
    print(stdout, end="")
if process.returncode != 0:
    raise SystemExit(f"UI smoke failed with exit code {process.returncode}. Artifacts: {output}")

report_path = output / "ui-smoke-report.json"
if not report_path.is_file():
    raise SystemExit("UI smoke did not complete its normal quit lifecycle.")
report = json.loads(report_path.read_text())
if report.get("credentialAccess") is not False or report.get("quitCleanupPassed") is not True:
    raise SystemExit("UI smoke safety or quit verification failed.")
expected = {
    "accounts-light.png", "accounts-dark.png", "empty.png", "loading.png",
    "error.png", "unavailable.png", "exhausted.png", "switching.png", "long-label.png", "minimum-width.png",
    "missing-five-hour.png", "five-hour-restored.png", "one-provider-error.png", "only-claude.png", "only-chatgpt.png",
    "manual-reset-states.png", "automatic-billing.png",
    "fable-enabled.png", "fable-enabled-dark.png", "switch-completed.png", "switching-minimum-width.png",
    "update-available.png", "update-downloading.png", "update-ready.png", "update-error.png",
}
if {entry["file"] for entry in report["renders"]} != expected:
    raise SystemExit("UI smoke did not render every required state.")
if any(entry.get("provider") != "all" for entry in report["renders"]):
    raise SystemExit("UI smoke rendered a provider-specific screen instead of the unified dashboard.")
for name in sorted(expected):
    image = output / name
    if not image.is_file() or image.stat().st_size <= 1000:
        raise SystemExit(f"Missing or empty preview: {name}")
if process.poll() is None:
    raise SystemExit("UI smoke left its app process running.")
print(f"PASS: {len(expected)} unified dashboard previews; independent provider actions; clean quit. Review {output}")
PY
