"""IO + RSS measurement via /proc/PID/io (strace unavailable in this env).
Reports syscr (read-syscall count ~ pread64 + a couple pipe reads),
read_bytes, and VmHWM for one search per fresh process."""
import json, subprocess, os, shutil, sys, time

import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
_PB_BASE = pb_harness.require_state()

def fresh(tag):
    d = pb_harness.new_state(f"tixio-{tag}")
    return pb_harness.seed_from_live(d)

def measure(binpath, query, lim):
    w = fresh(f"m-{os.path.basename(binpath)}-{query[:8]}")
    env = dict(os.environ, PEABRAIN_STATE_DIR=w)
    t0 = time.monotonic()
    p = subprocess.Popen([binpath], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, cwd="/tmp", env=env, text=True, bufsize=1)
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                              "params": {"name": "search_nodes",
                                         "arguments": {"query": query, "limit": lim}}}) + "\n")
    p.stdin.flush()
    line = p.stdout.readline()
    t_resp = time.monotonic() - t0
    io = {}
    for ln in open(f"/proc/{p.pid}/io"):
        k, v = ln.split(":")
        io[k.strip()] = int(v)
    hwm = int([l for l in open(f"/proc/{p.pid}/status") if l.startswith("VmHWM")][0].split()[1])
    p.stdin.close()
    p.wait(timeout=60)
    n = len(json.loads(line)["result"]["content"][0]["text"])
    return t_resp, io["syscr"], io["read_bytes"], hwm, n

if __name__ == "__main__":
    old, new = sys.argv[1], sys.argv[2]
    for q, lim in [("probe", 20), ("a", 20), ("the", 20)]:
        for label, b in (("OLD", old), ("NEW", new)):
            t, sc, rb, hwm, n = measure(b, q, lim)
            print(f"{label} q={q!r}: first-response={t:.3f}s syscr={sc} "
                  f"read_bytes={rb} VmHWM={hwm}kB resp={n}B", flush=True)
