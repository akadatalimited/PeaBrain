"""Tomb-perf baseline: cold vs warm search latency, pread64 counts, RSS.
Uses the DEPLOYED binary on scratch copies only. Never touches live state."""
import json, subprocess, os, shutil, sys, time

import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
_PB_BASE = pb_harness.require_state()
BIN = "/scratch/tmp/PeaBrain"
QUERIES = [("a", 20), ("the", 20), ("probe", 20), ("quux-live-1", 5)]

def fresh_copy(tag):
    d = pb_harness.new_state(f"tombase-{tag}")
    return pb_harness.seed_from_live(d)

def run_session(work, reqs, timing=False, strace=False):
    env = dict(os.environ, PEABRAIN_STATE_DIR=work)
    if timing:
        env["PEABRAIN_TIMING"] = "1"
    cmd = []
    if strace:
        cmd = ["strace", "-c", "-e", "trace=pread64", "-o", os.path.join(work, "strace.out")]
    cmd += [BIN]
    js = [json.dumps({"jsonrpc": "2.0", "id": i + 1, "method": "tools/call",
                      "params": {"name": n, "arguments": a}}) for i, (n, a) in enumerate(reqs)]
    t0 = time.monotonic()
    p = subprocess.run(cmd, input="\n".join(js) + "\n", capture_output=True, text=True,
                       timeout=600, cwd="/tmp", env=env)
    dt = time.monotonic() - t0
    outs = [json.loads(l) for l in p.stdout.strip().split("\n") if l.strip()]
    preads = None
    if strace:
        for line in open(os.path.join(work, "strace.out")):
            if "pread64" in line and "%" not in line and "total" not in line:
                parts = line.split()
                if len(parts) >= 4 and parts[0].replace(".", "").isdigit():
                    preads = (preads or 0) + 0  # summary format varies; parse below
        txt = open(os.path.join(work, "strace.out").replace("strace.out", "strace.out")).read()
        preads = txt
    return dt, outs, p.stderr, preads

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "cold"
    for q, lim in QUERIES:
        if mode == "cold":
            w = fresh_copy(f"cold-{q[:8]}-{lim}")
            reqs = [("search_nodes", {"query": q, "limit": lim})]
            dt, outs, err, _ = run_session(w, reqs, timing=True, strace=True)
            nres = len(outs[0]["result"]["content"][0]["text"])
            print(f"COLD q={q!r} lim={lim}: wall={dt:.3f}s resp_bytes={nres}")
            print("--- strace ---")
            print(open(os.path.join(w, "strace.out")).read()[-600:])
        else:
            w = fresh_copy(f"warm-{q[:8]}-{lim}")
            reqs = [("search_nodes", {"query": q, "limit": lim})] * 3
            dt, outs, err, _ = run_session(w, reqs, timing=True, strace=False)
            print(f"WARM q={q!r} lim={lim}: wall={dt:.3f}s for 3x")
            for e in (err or "").split("\n"):
                if e.startswith("PB ") or e.startswith("READY"):
                    print("   ", e)

if __name__ == "__main__":
    main()
