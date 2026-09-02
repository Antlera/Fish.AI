"""Fish.AI Python kernel - an MCP server that gives the agent a persistent Python session.

Why this exists instead of `bash python -c "..."`:
  * State persists between calls: the table is loaded once and reused as `df`, so each
    step the model writes is a couple of lines instead of a whole script. For a 3B-active
    model, shorter code is far more reliable code.
  * Multi-line code just works. On Windows, `python -c` with embedded newlines silently
    prints nothing and exits 0 - the single most confusing failure the old setup had.
  * `inspect_file` answers the questions the model otherwise wastes a turn on (what
    sheets, what columns, what types, what is missing) and loads the data in one go.
  * Output is captured and bounded, and a hung computation is killed and the kernel
    restarted instead of hanging the whole agent.

Two processes: the MCP server (this file, run by OpenCode over stdio) and a kernel child
(this file with --kernel) that actually runs the user's code, so a crash or timeout in
user code never takes the tool server down.

Configured in app/workspace/opencode.json under "mcp". Tools appear to the agent as
python_run, python_inspect_file, python_list_files, python_reset.
"""
from __future__ import annotations

import ast
import io
import json
import os
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

MAX_OUTPUT = 6000
TIMEOUT = float(os.environ.get("FISH_KERNEL_TIMEOUT", "180"))
WORKSPACE = Path(os.environ.get("FISH_WORKSPACE") or os.getcwd()).resolve()

# --------------------------------------------------------------------------- kernel
PRELUDE = """
import os, sys, json, math, re, statistics as st
from pathlib import Path
import numpy as np
import pandas as pd
try:
    from scipy import stats
except Exception: pass
try:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
except Exception: pass
pd.set_option("display.width", 200); pd.set_option("display.max_columns", 60); pd.set_option("display.max_rows", 80)
"""

INSPECT = r'''
def _fish_inspect(path):
    import os, pandas as pd
    p = str(path)
    if not os.path.exists(p):
        cands = [f for f in os.listdir(".") if f.lower() == os.path.basename(p).lower()]
        if cands: p = cands[0]
        else: return f"not found: {path}\nfiles here: {sorted(os.listdir('.'))}"
    ext = os.path.splitext(p)[1].lower()
    out = []
    def desc(d, label):
        out.append(f"## {label}: {d.shape[0]} rows x {d.shape[1]} cols")
        out.append("columns: " + ", ".join(f"{c} ({d[c].dtype})" for c in d.columns))
        na = d.isna().sum(); na = na[na > 0]
        out.append("missing: " + (", ".join(f"{c}={int(v)}" for c, v in na.items()) if len(na) else "none"))
        out.append(d.head(5).to_string())
    g = globals()
    if ext in (".xlsx", ".xlsm", ".xls"):
        sheets = pd.read_excel(p, sheet_name=None)
        first = next(iter(sheets))
        g["sheets"], g["df"] = sheets, sheets[first]
        out.append(f"{p}: {len(sheets)} sheet(s): {list(sheets)}")
        for name, d in sheets.items(): desc(d, f"sheet '{name}'")
        out.append(f"\nLoaded into the session: df = sheet '{first}'; sheets['<name>'] for every sheet.")
    elif ext in (".csv", ".tsv"):
        sep = "\t" if ext == ".tsv" else ","
        try: d = pd.read_csv(p, sep=sep)
        except UnicodeDecodeError: d = pd.read_csv(p, sep=sep, encoding="gbk")
        g["df"] = d; desc(d, p); out.append("\nLoaded into the session as df.")
    elif ext == ".parquet":
        d = pd.read_parquet(p); g["df"] = d; desc(d, p); out.append("\nLoaded into the session as df.")
    elif ext == ".json":
        try:
            d = pd.read_json(p); g["df"] = d; desc(d, p); out.append("\nLoaded into the session as df.")
        except Exception:
            txt = open(p, encoding="utf-8").read(); out.append(txt[:2000])
    elif ext == ".sav":
        d = pd.read_spss(p); g["df"] = d; desc(d, p); out.append("\nLoaded into the session as df.")
    elif ext == ".dta":
        d = pd.read_stata(p); g["df"] = d; desc(d, p); out.append("\nLoaded into the session as df.")
    elif ext == ".sas7bdat":
        d = pd.read_sas(p); g["df"] = d; desc(d, p); out.append("\nLoaded into the session as df.")
    elif ext in (".rds", ".rdata"):
        import pyreadr
        r = pyreadr.read_r(p); key = next(iter(r)); d = r[key]; g["df"] = d; desc(d, f"{p} [{key}]"); out.append("\nLoaded into the session as df.")
    else:
        try:
            lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
            out.append(f"{p}: text, {len(lines)} lines. First 40:"); out.extend(lines[:40])
        except Exception as e:
            out.append(f"cannot read {p}: {e}")
    return "\n".join(out)
'''


def _truncate(s: str) -> str:
    if len(s) <= MAX_OUTPUT:
        return s
    head, tail = s[: MAX_OUTPUT * 2 // 3], s[-MAX_OUTPUT // 3 :]
    return f"{head}\n... [{len(s) - len(head) - len(tail)} chars omitted] ...\n{tail}"


def kernel_main() -> None:
    """Child process: read {"code": ...} lines on stdin, answer {"ok", "output"} lines."""
    os.chdir(WORKSPACE)
    ns: dict = {"__name__": "__main__"}
    exec(PRELUDE, ns)
    exec(INSPECT, ns)
    real_out = sys.stdout
    sys.stdin.reconfigure(encoding="utf-8")
    real_out.reconfigure(encoding="utf-8")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        code = req.get("code", "")
        buf = io.StringIO()
        ok = True
        sys.stdout = sys.stderr = buf
        try:
            tree = ast.parse(code, mode="exec")
            # Notebook behaviour: echo the value of a trailing bare expression.
            last = tree.body[-1] if tree.body and isinstance(tree.body[-1], ast.Expr) else None
            if last is not None:
                tree.body = tree.body[:-1]
                exec(compile(tree, "<run>", "exec"), ns)
                val = eval(compile(ast.Expression(last.value), "<run>", "eval"), ns)
                if val is not None:
                    print(val if not hasattr(val, "to_string") else val.to_string() if getattr(val, "ndim", 0) == 2 else val)
            else:
                exec(compile(tree, "<run>", "exec"), ns)
        except SystemExit:
            pass
        except BaseException:
            ok = False
            tb = traceback.format_exc().splitlines()
            # Drop the frames that belong to this kernel, keep the user's.
            keep = [l for l in tb if "fishkernel.py" not in l]
            buf.write("\n".join(keep[-12:]))
        finally:
            sys.stdout = sys.stderr = real_out
        real_out.write(json.dumps({"ok": ok, "output": _truncate(buf.getvalue())}, ensure_ascii=False) + "\n")
        real_out.flush()


# --------------------------------------------------------------------------- server side
class Kernel:
    def __init__(self) -> None:
        self.proc: subprocess.Popen | None = None
        self.lock = threading.Lock()
        self.started_at = 0.0

    def start(self) -> None:
        env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8", FISH_WORKSPACE=str(WORKSPACE))
        self.proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--kernel"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            cwd=str(WORKSPACE), env=env, text=True, encoding="utf-8", bufsize=1,
        )
        self.started_at = time.time()

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
        self.proc = None

    def run(self, code: str) -> str:
        with self.lock:
            if not self.proc or self.proc.poll() is not None:
                self.start()
            assert self.proc and self.proc.stdin and self.proc.stdout
            try:
                self.proc.stdin.write(json.dumps({"code": code}, ensure_ascii=False) + "\n")
                self.proc.stdin.flush()
            except OSError:
                self.stop()
                return "kernel had died; restarted. Variables are gone - load the data again."
            result: dict = {}
            def reader() -> None:
                line = self.proc.stdout.readline()
                if line:
                    result.update(json.loads(line))
            t = threading.Thread(target=reader, daemon=True)
            t.start()
            t.join(TIMEOUT)
            if t.is_alive():
                self.stop()
                return (f"timed out after {TIMEOUT:.0f}s and the kernel was restarted. Variables are gone - "
                        f"load the data again and use a cheaper computation.")
            if not result:
                self.stop()
                return "kernel crashed (no output). Restarted; variables are gone - load the data again."
            out = result.get("output", "")
            if not result.get("ok", False):
                return f"ERROR\n{out}" if out else "ERROR (no traceback)"
            return out if out.strip() else "(no output - use print(...) or end with a bare expression)"


def server_main() -> None:
    from mcp.server.mcpserver import MCPServer  # mcp >= 2

    kernel = Kernel()
    srv = MCPServer("python", instructions="Persistent Python session for data analysis in the workspace.")

    @srv.tool(name="run", structured_output=False,
              description=("Run Python code in a persistent session (variables, imports and loaded data "
                           "survive between calls). numpy as np, pandas as pd, scipy.stats as stats are "
                           "pre-imported. print() what you need; the value of a trailing bare expression is "
                           "echoed like a notebook. Returns stdout/stderr, or ERROR with a traceback."))
    def run(code: str) -> str:
        return kernel.run(code)

    @srv.tool(name="inspect_file", structured_output=False,
              description=("Look inside a data file (.xlsx/.xls, .csv/.tsv, .parquet, .json, .sav, .dta, "
                           ".sas7bdat, .rds, text): sheets, shape, columns with dtypes, missing counts and "
                           "the first rows. Also loads it into the session as `df` (all sheets in `sheets`). "
                           "Call this first for any new file."))
    def inspect_file(path: str) -> str:
        return kernel.run(f"print(_fish_inspect({path!r}))")

    @srv.tool(name="list_files", structured_output=False,
              description="List the files in the workspace (the directory the user put data in) with sizes.")
    def list_files() -> str:
        rows = []
        for p in sorted(WORKSPACE.iterdir()):
            if p.name.startswith(".") or p.name in ("AGENTS.md", "opencode.json"):
                continue
            rows.append(f"{p.name}\t{p.stat().st_size / 1024:.0f} KB" if p.is_file() else f"{p.name}/")
        return "\n".join(rows) or "(empty)"

    @srv.tool(name="reset", structured_output=False,
              description="Restart the Python session, dropping all variables. Only if the session is in a bad state.")
    def reset() -> str:
        kernel.stop()
        kernel.start()
        return "session restarted"

    srv.run(transport="stdio")


if __name__ == "__main__":
    if "--kernel" in sys.argv:
        kernel_main()
    else:
        server_main()
