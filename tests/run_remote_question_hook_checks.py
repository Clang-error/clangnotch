"""Exercise the installed hook script's jq and Python paths without a network request."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time

root = Path(__file__).resolve().parents[1]
source = (root / "ClangNotch/Core/ClaudeCode/RemoteClaudeManager.swift").read_text()
script = textwrap.dedent(source.split('private nonisolated static let hookScript = #"""', 1)[1].split('"""#', 1)[0]).lstrip()
question = {"session_id": "fixture", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_use_id": "q", "tool_input": {"questions": [{"header": "선택", "question": "어떤 방식인가요?", "multiSelect": True, "options": [{"label": "방식", "description": "긴 설명 " * 100}]}]}}
normal = {"session_id": "fixture", "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "x" * 500, "nested": [1, 2]}, "tool_output": "not forwarded"}
jq = shutil.which("jq")
assert jq, "jq is required to verify both installed script paths"
with tempfile.TemporaryDirectory(prefix="clangnotch-hook-checks-") as folder:
    temp = Path(folder)
    hook = temp / "hook.sh"
    hook.write_text(script.replace("__HOST__", "fixture"))
    subprocess.run(["/bin/sh", "-n", str(hook)], check=True)
    for use_jq in [True, False]:
        binary_dir = temp / ("jq" if use_jq else "python")
        binary_dir.mkdir()
        (binary_dir / "cat").symlink_to("/bin/cat")
        (binary_dir / "python3").symlink_to(sys.executable)
        if use_jq:
            (binary_dir / "jq").symlink_to(jq)
        curl = binary_dir / "curl"
        curl.write_text(f"#!{sys.executable}\nimport os, pathlib, sys\npathlib.Path(os.environ['CLANGNOTCH_CAPTURE']).write_text(sys.argv[sys.argv.index('--data-binary') + 1])\n")
        curl.chmod(0o755)
        for index, payload in enumerate([question, normal]):
            capture = temp / f"{use_jq}-{index}.json"
            env = dict(os.environ, PATH=str(binary_dir), CLANGNOTCH_CAPTURE=str(capture))
            subprocess.run(["/bin/sh", str(hook)], input=json.dumps(payload), text=True, env=env, check=True)
            for _ in range(100):
                if capture.exists() and capture.stat().st_size:
                    break
                time.sleep(0.01)
            body = json.loads(capture.read_text())
            assert body["clangnotch_host"] == "fixture"
            if index == 0:
                assert body["tool_input"] == question["tool_input"], "Question arrays and long descriptions must survive SSH forwarding"
            else:
                assert body["tool_input"] == {"command": "x" * 200}
                assert "tool_output" not in body
        print(f"PASS: {'jq' if use_jq else 'Python'} hook preserves questions and descriptions; ordinary tool fields stay trimmed")
