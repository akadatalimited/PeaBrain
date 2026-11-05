"""Payload edge-case differential (Gate 1: state-isolated). Compares two
binaries (default: shipped Master vs tix build) on write/read verdicts for
boundary payloads. Each side gets its own scratch state dir; a missing
PEABRAIN_STATE_DIR refuses execution (never touches live canonical)."""
import json, subprocess, os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pb_harness

BASE = pb_harness.require_state()
OLD = sys.argv[1] if len(sys.argv) > 1 else "/scratch/fasm-webserver/tinythink/tinythink"
NEW = sys.argv[2] if len(sys.argv) > 2 else "/scratch/tmp/tixbuild"

def fresh(tag, binpath):
    d = f"/scratch/tmp/rk-diff-{tag}-{os.getpid()}"
    pb_harness.safe_rmtree(d)
    os.makedirs(d)
    st = pb_harness.new_state(f"v3diff-{tag}")
    shutil_copy = __import__('shutil').copy
    shutil_copy(binpath, d + "/tt")
    env = dict(os.environ, PEABRAIN_STATE_DIR=st)
    return d, env

def run(d, env, reqs):
    p = subprocess.Popen(["./tt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         cwd=d, text=True, bufsize=1, env=env)
    out = []
    for o in reqs:
        p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
        out.append(json.loads(p.stdout.readline()))
    p.stdin.close(); p.wait(timeout=15)
    return out

def w(i, name, text):
    return {"jsonrpc": "2.0", "id": i, "method": "tools/call",
            "params": {"name": "write_fact", "arguments": {"name": name, "text": text}}}

def r(i, name):
    return {"jsonrpc": "2.0", "id": i, "method": "tools/call",
            "params": {"name": "read_fact", "arguments": {"name": name}}}

cases = [
    ("empty", ""), ("one", "a"), ("31", "x" * 31), ("32", "y" * 32),
    ("33", "z" * 33 + "\n"), ("63tab", "a" * 30 + "\t" + "b" * 32),
    ("64", "q" * 64), ("65", "q" * 65), ("quote31", "a" * 31 + '"'),
    ("bs32", "b" * 32 + "\\"), ("ctrl33", "c" * 31 + "\x01" + "d"),
    ("del34", "d" * 32 + "\x7f" + "e"), ("high35", "e" * 33 + "\x80" + "f"),
    ("crlf", "line1\r\nline2\nline3"), ("1023", "g" * 1023), ("1024", "h" * 1024),
    ("1025", "i" * 1025),
    ("mix", "a" * 100 + '"q"' + "\\" + "\x7f" * 0 + "z" * 100),
]
fails = []
results = {}
for tag, binpath in (("old", OLD), ("new", NEW)):
    d, env = fresh(tag, binpath)
    reqs = [w(100 + i, n, t) for i, (n, t) in enumerate(cases)]
    reqs += [r(300 + i, n) for i, (n, t) in enumerate(cases)]
    outs = run(d, env, reqs)
    results[tag] = outs
    print(f"{tag}: {sum('result' in o for o in outs)}/{len(outs)} ok")

n = len(cases)
ok = True
for i, (name, text) in enumerate(cases):
    a, b = results["old"][i], results["new"][i]
    same_verdict = ("result" in a) == ("result" in b)
    same_body = True
    if "result" in a:
        ta = a["result"]["content"][0]["text"]
        tb = b["result"]["content"][0]["text"]
        same_body = ta == tb
    ra, rb = results["old"][n + i], results["new"][n + i]
    same_read = json.dumps(ra) == json.dumps(rb)
    if not (same_verdict and same_body and same_read):
        ok = False
        print(f"DIFF {name}: wold={str(a)[:100]} wnew={str(b)[:100]}")
        print(f"   read equal: {same_read}")
print("IDENTICAL" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
