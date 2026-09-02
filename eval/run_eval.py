"""Fish.AI evaluation - drive the agent through a fixed set of data questions and grade it.

    python eval/run_eval.py --label new --config app/workspace
    python eval/run_eval.py --label baseline --config eval/configs/baseline --tasks 1,2,3

Needs llama-server already running on :8080 (start.ps1 does that; or run
engine/scripts/03-start-server.ps1 by itself). The script starts its own `opencode serve`
on --port with a throwaway copy of the config, so the user's sessions are untouched.

Grading is mechanical on purpose: expected numbers come from pandas in make_data.py, a
task passes when every expected value appears in the final answer, and every number the
agent reports is checked against the outputs of the tools it ran (provenance).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from make_data import make  # noqa: E402

OPENCODE_EXE = None


def tasks_for(t: dict) -> list[dict]:
    """The question set. `expect` items: {"num": value, "rel"|"abs": tol} or {"str": text}."""
    missing = ", ".join(f"{c}={v}" for c, v in t["missing"].items())
    return [
        {"id": 1, "q": "employees.xlsx 里有几个 sheet？每个 sheet 各有多少行、多少列？",
         "expect": [{"num": t["employees_rows"], "abs": 0}, {"num": t["employees_cols"], "abs": 0},
                    {"num": t["bonus_rows"], "abs": 0}, {"num": t["bonus_cols"], "abs": 0}]},
        {"id": 2, "q": "employees.xlsx 的 Employees 表里，salary 的平均值、中位数和样本标准差分别是多少？",
         "expect": [{"num": t["salary_mean"], "rel": 0.002}, {"num": t["salary_median"], "rel": 0.002},
                    {"num": t["salary_sd"], "rel": 0.005}]},
        {"id": 3, "q": "employees.xlsx 里哪个部门的平均薪资最高？平均是多少？",
         "expect": [{"str": t["top_dept"]}, {"num": t["top_dept_mean"], "rel": 0.005}]},
        {"id": 4, "q": "employees.xlsx 的 salary 列有没有异常值？用 1.5 倍 IQR 的规则判断，一共有几个？",
         "expect": [{"num": t["outlier_count"], "abs": 0}]},
        {"id": 5, "q": f"employees.xlsx 的 Employees 表里哪些列有缺失值？各缺多少个？",
         "expect": [{"str": c} for c in t["missing"]] + [{"num": v, "abs": 0} for v in t["missing"].values()],
         "note": missing},
        {"id": 6, "q": "sales.csv 按月份汇总 amount，哪个月的总额最高？那个月的总额是多少？",
         "expect": [{"num": t["top_month"], "abs": 0}, {"num": t["top_month_total"], "rel": 0.002}]},
        {"id": 7, "q": "employees.xlsx 里 age 和 salary 的皮尔逊相关系数是多少？（保留三位小数就行）",
         "expect": [{"num": t["corr_age_salary"], "abs": 0.0015}]},
        {"id": 8, "q": "把 employees.xlsx 的 Employees 和 Bonus 两个 sheet 按 id 左连接（以 Employees 为准），合并后有多少行？其中 bonus 为空的有多少人？",
         "expect": [{"num": t["merged_rows"], "abs": 0}, {"num": t["merged_bonus_missing"], "abs": 0}]},
        {"id": 9, "q": "employees.xlsx 里男性和女性的平均薪资分别是多少？差异显著吗？请用合适的检验并给出 p 值。",
         "expect": [{"num": t["male_mean"], "rel": 0.005}, {"num": t["female_mean"], "rel": 0.005},
                    {"any": [{"num": t["ttest_p_welch"], "rel": 0.15}, {"num": t["ttest_p_student"], "rel": 0.15},
                             {"num": t["mw_p"], "rel": 0.15}]}]},
        {"id": 10, "q": "这组数的样本标准差是多少：4, 8, 15, 16, 23, 42",
         "expect": [{"num": t["small_sd"], "rel": 0.002}]},
    ]


# ----------------------------------------------------------------------------- opencode api
def api(base: str, method: str, path: str, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"content-type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read().decode("utf-8")
    j = json.loads(raw) if raw else {}
    return j.get("data", j) if isinstance(j, dict) else j


def wait_health(base: str, secs: int) -> bool:
    for _ in range(secs * 2):
        try:
            api(base, "GET", "/api/health", timeout=3)
            return True
        except Exception:
            time.sleep(0.5)
    return False


# ----------------------------------------------------------------------------- grading
NUM_RE = re.compile(r"(?<![\w.])-?\d[\d,]*(?:\.\d+)?(?:[eE][-+]?\d+)?(?![\w])")


def numbers_in(text: str) -> list[float]:
    out = []
    for m in NUM_RE.finditer(text or ""):
        s = m.group(0).replace(",", "")
        try:
            out.append(float(s))
        except ValueError:
            pass
    return out


def num_matches(nums: list[float], value: float, tol_abs: float | None, tol_rel: float | None) -> bool:
    for n in nums:
        if tol_abs is not None and abs(n - value) <= tol_abs + 1e-9:
            return True
        if tol_rel is not None and abs(n - value) <= abs(value) * tol_rel + 1e-9:
            return True
    return False


def check_expect(e: dict, answer: str, nums: list[float]) -> bool:
    if "any" in e:
        return any(check_expect(x, answer, nums) for x in e["any"])
    if "str" in e:
        return e["str"] in answer
    return num_matches(nums, e["num"], e.get("abs"), e.get("rel"))


COMMON = {0.05, 0.01, 0.001, 0.1, 0.5, 0.9, 0.95, 0.99, 1.5, 1.96, 2.576, 90, 95, 99, 100}


def provenance(answer: str, tool_outputs: list[str], question: str = "") -> tuple[int, int, list[str]]:
    """How many 'reportable' numbers in the answer can be traced to a tool output.
    Numbers the user typed themselves and conventional constants (alpha levels, IQR
    multipliers) are not computations and do not count."""
    pool = set(COMMON)
    pool.update(numbers_in(question))
    for t in tool_outputs:
        pool.update(numbers_in(t))
    checked = unverified = 0
    bad = []
    for m in NUM_RE.finditer(answer or ""):
        raw = m.group(0).replace(",", "")
        if "." not in raw and len(raw.lstrip("-")) < 3:
            continue  # list markers, small counts, years-ish things: not worth flagging
        try:
            v = float(raw)
        except ValueError:
            continue
        checked += 1
        decimals = len(raw.split(".")[1]) if "." in raw else 0
        half = 0.5 * 10 ** (-decimals)
        if not any(abs(p - v) <= half + 1e-9 or (p != 0 and abs(p - v) / abs(p) <= 5e-4) for p in pool):
            unverified += 1
            bad.append(raw)
    return checked, unverified, bad


# ----------------------------------------------------------------------------- one task
def norm(msgs: list) -> list[dict]:
    """v1 history entries are {info, parts}; flatten to one dict per message."""
    out = []
    for m in msgs or []:
        info = dict(m.get("info") or m)
        info["parts"] = m.get("parts") or m.get("content") or []
        out.append(info)
    return out


def run_task(base: str, task: dict, timeout: float) -> dict:
    # v1 API on purpose: it is the one that hands MCP tools (the Python kernel) to the model.
    sid = api(base, "POST", "/session", {})["id"]
    t0 = time.time()
    api(base, "POST", f"/session/{sid}/prompt_async", {"parts": [{"type": "text", "text": task["q"]}]})
    first = None
    msgs = []
    status = "timeout"
    while time.time() - t0 < timeout:
        time.sleep(1.5)
        try:
            msgs = norm(api(base, "GET", f"/session/{sid}/message"))
        except Exception:
            continue
        assistants = [m for m in msgs if m.get("role") == "assistant"]
        if assistants and first is None:
            for m in assistants:
                if any(p.get("type") in ("text", "tool") for p in m["parts"]):
                    first = time.time() - t0
                    break
        # anything waiting on a human? approve permissions, reject questions
        try:
            for p in api(base, "GET", "/permission") or []:
                if p.get("sessionID") == sid:
                    api(base, "POST", f"/session/{sid}/permissions/{p['id']}", {"response": "once"})
            for q in api(base, "GET", "/question") or []:
                if q.get("sessionID") == sid:
                    api(base, "POST", f"/question/{q['id']}/reject", {})
        except Exception:
            pass
        if assistants:
            last = max(assistants, key=lambda m: m.get("time", {}).get("created", 0))
            fin = last.get("finish")
            if fin and fin != "tool-calls":
                status = "error" if last.get("error") else "done"
                break
    total = time.time() - t0
    if status == "timeout":
        try:
            api(base, "POST", f"/session/{sid}/abort", {})
        except Exception:
            pass

    assistants = sorted([m for m in msgs if m.get("role") == "assistant"],
                        key=lambda m: m.get("time", {}).get("created", 0))
    texts, tools = [], []
    tok_in = tok_out = tok_cache = 0
    for m in assistants:
        tk = m.get("tokens") or {}
        tok_in += tk.get("input", 0) or 0
        tok_out += tk.get("output", 0) or 0
        tok_cache += (tk.get("cache") or {}).get("read", 0) or 0
        for p in m["parts"]:
            if p.get("type") == "text" and p.get("text"):
                texts.append(p["text"])
            elif p.get("type") == "tool":
                st = p.get("state", {})
                out = st.get("output")
                if not isinstance(out, str):
                    out = json.dumps(st.get("result", {}).get("value", ""), ensure_ascii=False) if st.get("result") else ""
                err = st.get("error")
                if isinstance(err, dict):
                    err = err.get("message")
                tools.append({"name": p.get("name") or p.get("tool"), "status": st.get("status"),
                              "input": st.get("input"), "output": out or "", "error": err})
    final = texts[-1] if texts else ""
    all_text = "\n".join(texts)
    nums_final = numbers_in(final)
    nums_all = numbers_in(all_text)
    ok_final = all(check_expect(e, final, nums_final) for e in task["expect"])
    ok_any = all(check_expect(e, all_text, nums_all) for e in task["expect"])
    checked, unverified, bad = provenance(final, [t["output"] or "" for t in tools] + [t["error"] or "" for t in tools], task["q"])
    return {
        "id": task["id"], "q": task["q"], "status": status,
        "correct": ok_final, "correct_anywhere": ok_any,
        "prov_checked": checked, "prov_unverified": unverified, "prov_bad": bad,
        "steps": len(assistants), "tool_calls": len(tools),
        "tool_errors": sum(1 for t in tools if t["status"] == "error"),
        "tools": [t["name"] for t in tools],
        "first_token_s": round(first, 1) if first else None, "total_s": round(total, 1),
        "tokens": {"input": tok_in, "cache_read": tok_cache, "output": tok_out},
        "final": final, "tool_log": tools, "session": sid,
    }


# ----------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--config", default=str(ROOT / "app" / "workspace"),
                    help="directory holding opencode.json and AGENTS.md to evaluate")
    ap.add_argument("--port", type=int, default=4097)
    ap.add_argument("--tasks", default="", help="comma-separated task ids, default all")
    ap.add_argument("--timeout", type=float, default=600)
    args = ap.parse_args()

    global OPENCODE_EXE
    npm_root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True, shell=True).stdout.strip()
    OPENCODE_EXE = Path(npm_root) / "opencode-ai" / "bin" / "opencode.exe"
    if not OPENCODE_EXE.exists():
        print("opencode not found at", OPENCODE_EXE)
        return 2

    # throwaway workspace: config copy + fresh data
    run_dir = HERE / ".run" / args.label
    if run_dir.exists():
        shutil.rmtree(run_dir)
    run_dir.mkdir(parents=True)
    cfg_src = Path(args.config)
    cfg = json.loads((cfg_src / "opencode.json").read_text(encoding="utf-8"))
    cfg.setdefault("permission", {})
    for k in ("bash", "edit", "write"):
        cfg["permission"][k] = "allow"
    # MCP command paths in the shipped config are relative to app/workspace; make them absolute here
    for name, m in (cfg.get("mcp") or {}).items():
        if isinstance(m, dict) and m.get("type") == "local":
            cmd = list(m.get("command", []))
            m["command"] = [str((ROOT / "app" / "workspace" / c).resolve()) if c.endswith(".py") and not Path(c).is_absolute() else c for c in cmd]
    (run_dir / "opencode.json").write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    if (cfg_src / "AGENTS.md").exists():
        shutil.copy(cfg_src / "AGENTS.md", run_dir / "AGENTS.md")
    truth = make(run_dir)
    (run_dir / "truth.json").write_text(json.dumps(truth, ensure_ascii=False, indent=1), encoding="utf-8")

    all_tasks = tasks_for(truth)
    if args.tasks:
        want = {int(x) for x in args.tasks.split(",")}
        all_tasks = [t for t in all_tasks if t["id"] in want]

    base = f"http://127.0.0.1:{args.port}"
    log = open(run_dir / "opencode.log", "w", encoding="utf-8")
    env = dict(os.environ, PYTHONUTF8="1")
    # Under git-bash SHELL=/usr/bin/bash leaks in and opencode's bash tool then runs a
    # shell that does not exist on Windows - every command returns nothing.
    env.pop("SHELL", None)
    proc = subprocess.Popen([str(OPENCODE_EXE), "serve", "--port", str(args.port)], cwd=str(run_dir),
                            stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        if not wait_health(base, 60):
            print("opencode did not come up; see", run_dir / "opencode.log")
            return 2
        # the first session right after boot has been seen to get the default config;
        # touch the agent list and wait before starting
        try:
            api(base, "GET", "/agent")
        except Exception:
            pass
        time.sleep(4)
        print(f"[{args.label}] {len(all_tasks)} tasks, config={cfg_src}, workspace={run_dir}")
        results = []
        for task in all_tasks:
            print(f"  task {task['id']:2d} ... ", end="", flush=True)
            r = run_task(base, task, args.timeout)
            results.append(r)
            mark = "PASS" if r["correct"] else ("pass*" if r["correct_anywhere"] else "FAIL")
            print(f"{mark:5s} {r['status']:7s} steps={r['steps']} tools={r['tool_calls']} err={r['tool_errors']} "
                  f"unverified={r['prov_unverified']}/{r['prov_checked']} first={r['first_token_s']}s total={r['total_s']}s")
    finally:
        proc.kill()
        log.close()

    # ---- report
    out_dir = HERE / "results"
    out_dir.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    (out_dir / f"{stamp}-{args.label}.json").write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")
    n = len(results)
    passed = sum(r["correct"] for r in results)
    lines = [f"# Fish.AI eval - {args.label} ({stamp})", "",
             f"config: `{cfg_src}` · tasks: {n} · **passed: {passed}/{n}** · "
             f"tool errors: {sum(r['tool_errors'] for r in results)} · "
             f"unverified numbers: {sum(r['prov_unverified'] for r in results)}/{sum(r['prov_checked'] for r in results)} · "
             f"median total: {sorted(r['total_s'] for r in results)[n // 2] if n else 0}s", "",
             "| # | result | steps | tools | errors | unverified | first token | total | tokens in (cached) / out |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        mark = "✅" if r["correct"] else ("🟡" if r["correct_anywhere"] else "❌")
        if r["status"] != "done":
            mark += f" {r['status']}"
        tk = r["tokens"]
        lines.append(f"| {r['id']} | {mark} | {r['steps']} | {r['tool_calls']} | {r['tool_errors']} | "
                     f"{r['prov_unverified']}/{r['prov_checked']} | {r['first_token_s']}s | {r['total_s']}s | "
                     f"{tk['input']} ({tk['cache_read']}) / {tk['output']} |")
    lines += ["", "🟡 = correct numbers appeared, but not in the final answer.", ""]
    for r in results:
        lines += [f"## {r['id']}. {r['q']}", "", f"tools: {', '.join(r['tools']) or '-'}",
                  (f"unverified numbers: {', '.join(r['prov_bad'])}" if r["prov_bad"] else ""), "",
                  "```", (r["final"] or "(no final text)")[:1500], "```", ""]
    (out_dir / f"{stamp}-{args.label}.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"\npassed {passed}/{n}  ->  {out_dir / f'{stamp}-{args.label}.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
