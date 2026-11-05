"""Rename-aware oracle: OLD (pre-rename bytes) vs NEW (PeaBrain) must agree
on everything EXCEPT the intended renames (serverInfo name, *.db tool
descriptions). Any other divergence fails. Uses twin seeded states."""
import json, subprocess, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness

BASE = pb_harness.require_state()
OLD = "/scratch/tmp/tixbuild"
NEW = "/scratch/tmp/PeaBrain"
CASES = [
    ("search_nodes", {"query": "probe", "limit": 20}),
    ("search_nodes", {"query": "probe", "limit": 1}),
    ("search_nodes", {"query": "a", "limit": 20}),
    ("search_nodes", {"query": "the", "limit": 20}),
    ("search_nodes", {"query": "e", "limit": 20}),
    ("search_nodes", {"query": "zzz-no-such-thing", "limit": 20}),
    ("list_facts", {}),
    ("open_nodes", {"names": ["peabrain_flush_20261104_00001", "quux-live-1", "nope-missing"]}),
    ("read_fact", {"name": "peabrain_flush_20261104_00001"}),
    ("health", {}),
    ("model_status", {}),
    ("explain_rank", {"name": "peabrain_flush_20261104_00001"}),
]
ALLOW = ("peabrain", "tinythink")  # intended renames appear in these substrings

def run(binary, state, reqs):
    env = dict(os.environ, PEABRAIN_STATE_DIR=state)
    js = "\n".join(json.dumps({"jsonrpc": "2.0", "id": i + 1, "method": "tools/call",
                               "params": {"name": n, "arguments": a}})
                    for i, (n, a) in enumerate(reqs))
    p = subprocess.run([binary], input=js + "\n", capture_output=True, text=True,
                       timeout=900, cwd="/tmp", env=env)
    return p.stdout

def norm(s):
    return s.replace("tinythink.db", "peabrain.db").replace(
        '"name":"tinythink"', '"name":"peabrain"')

def dual_seed(tag):
    """Seed BOTH filename eras so OLD (tinythink.db) and NEW (peabrain.db)
    binaries each find their own files in the same state dir."""
    import shutil
    d = pb_harness.new_state(tag)
    live = os.path.expanduser("~/.local/share/peabrain")
    for src_names, dst_names in ((("peabrain.db", "tinythink.db"), ("tinythink.db", "peabrain.db")),
                               (("peabrain-rank.pbmd", "rank.pbmd"), ("rank.pbmd", "peabrain-rank.pbmd"))):
        src = next((os.path.join(live, c) for c in src_names if os.path.isfile(os.path.join(live, c))), None)
        assert src is not None
        b = open(src, "rb").read()
        for dst in dst_names:
            open(os.path.join(d, dst), "wb").write(b)
            os.chmod(os.path.join(d, dst), 0o600)
    return d

def main():
    fails = 0
    for i, (n, a) in enumerate(CASES):
        so = run(OLD, dual_seed(f"rn-o{i}"), [(n, a)])
        sn = run(NEW, dual_seed(f"rn-n{i}"), [(n, a)])
        if norm(so) == norm(sn):
            print(f"PASS {n} {json.dumps(a)[:50]} (modulo intended renames)")
        else:
            fails += 1
            print(f"FAIL {n} {json.dumps(a)[:50]}")
            open(f"/tmp/rn-{i}-old.txt", "w").write(so)
            open(f"/tmp/rn-{i}-new.txt", "w").write(sn)
    # raw check: NEW output must not mention tinythink.db at all
    sn_all = run(NEW, dual_seed("rn-leak"),
                 [("search_nodes", {"query": "probe", "limit": 5})])
    if "tinythink" in sn_all:
        fails += 1
        print("FAIL new binary leaks 'tinythink' in output")
    else:
        print("PASS no tinythink leakage in new output")
    print("FAILURES:", fails)
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
