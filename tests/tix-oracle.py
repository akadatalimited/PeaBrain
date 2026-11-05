"""Oracle diff: deployed binary vs tixbuild must emit byte-identical stdout.
Fresh identical copies per case (writes pollute). Exits nonzero on mismatch."""
import json, subprocess, os, shutil, sys

import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
_PB_BASE = pb_harness.require_state()
OLD = "/scratch/fasm-webserver/tinythink/tinythink"
NEW = "/scratch/tmp/tixbuild"

CASES = [
    ("search_nodes", {"query": "probe", "limit": 20}),
    ("search_nodes", {"query": "probe", "limit": 1}),
    ("search_nodes", {"query": "a", "limit": 20}),
    ("search_nodes", {"query": "the", "limit": 20}),
    ("search_nodes", {"query": "quux-live-1", "limit": 5}),
    ("search_nodes", {"query": "zzz-no-such-thing", "limit": 20}),
    ("search_nodes", {"query": "peabrain", "limit": 20}),
    ("search_nodes", {"query": "sequential", "limit": 10}),
    ("list_facts", {}),
    ("open_nodes", {"names": ["peabrain_flush_20261104_00001", "quux-live-1", "nope-missing"]}),
    ("read_fact", {"name": "peabrain_flush_20261104_00001"}),
    ("read_fact", {"name": "quux-live-1"}),
    ("health", {}),
    ("model_status", {}),
    ("search_nodes", {"query": "e", "limit": 20}),
]

def fresh(tag):
    d = pb_harness.new_state(f"tixoracle-{tag}")
    return pb_harness.seed_from_live(d)

def run(binpath, work, reqs):
    env = dict(os.environ, PEABRAIN_STATE_DIR=work)
    js = "\n".join(json.dumps({"jsonrpc": "2.0", "id": i + 1, "method": "tools/call",
                               "params": {"name": n, "arguments": a}})
                    for i, (n, a) in enumerate(reqs))
    p = subprocess.run([binpath], input=js + "\n", capture_output=True, text=True,
                       timeout=900, cwd="/tmp", env=env)
    return p.stdout

def main():
    fails = 0
    # single-query cases first (isolated), then a multi-query session case
    for i, (n, a) in enumerate(CASES):
        wo, wn = fresh(f"o{i}"), fresh(f"n{i}")
        so, sn = run(OLD, wo, [(n, a)]), run(NEW, wn, [(n, a)])
        ok = so == sn
        print(("PASS " if ok else "FAIL ") + f"{n} {json.dumps(a)[:60]} "
              f"(old {len(so)}B, new {len(sn)}B)", flush=True)
        if not ok:
            fails += 1
            open(f"/tmp/oracle-{i}-old.txt", "w").write(so)
            open(f"/tmp/oracle-{i}-new.txt", "w").write(sn)
    # session case: same stream through both (warm paths, usage ticks)
    sess = [("search_nodes", {"query": "probe", "limit": 5}),
            ("search_nodes", {"query": "a", "limit": 5}),
            ("list_facts", {}),
            ("search_nodes", {"query": "probe", "limit": 5})]
    wo, wn = fresh("sess-o"), fresh("sess-n")
    so, sn = run(OLD, wo, sess), run(NEW, wn, sess)
    ok = so == sn
    print(("PASS " if ok else "FAIL ") + f"session-4x (old {len(so)}B, new {len(sn)}B)", flush=True)
    fails += 0 if ok else 1
    print("FAILURES:", fails, flush=True)
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
