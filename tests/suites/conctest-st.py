import json, subprocess, os, sys
import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pb_harness
_PB_ST = pb_harness.require_state()

BIN_SRC = sys.argv[1] if len(sys.argv) > 1 else "/scratch/tmp/stbuild"
WORK = "/scratch/tmp/rk-ttdb-test"
os.system(f"rm -rf {WORK}")
os.makedirs(WORK)
os.system(f"cp {BIN_SRC} {WORK}/tt0 && chmod +x {WORK}/tt0")
BIN = f"{WORK}/tt0"
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)
        print("   extra:", str(extra)[:400])

def spawn():
    return subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            cwd=WORK, text=True, bufsize=1)
def call(p, tool, args, rid):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                              "params": {"name": tool, "arguments": args}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())
def txt(r):
    return r["result"]["content"][0]["text"]
def close(p):
    try:
        p.stdin.close()
    except Exception:
        pass
    p.wait(timeout=10)

DB = os.path.join(os.environ.get("PEABRAIN_STATE_DIR", WORK), "peabrain.db")

# 1 lazy create: no db file before first conclusion op
check("no-db-before-use", not os.path.exists(DB))
p = spawn()
r = call(p, "conclusion", {"reason": "sky", "thought": "It is blue.", "conclusion": "The sky is blue."}, 1)
check("insert", json.loads(txt(r)) == {"rowid": 1, "reason": "sky", "valid": True}, r)
check("db-created", os.path.exists(DB))
check("magic", open(DB, "rb").read(16) == b"SQLite format 3\x00")
close(p)

# 2 read back in a NEW process (restart persistence)
p = spawn()
r = call(p, "conclusion", {"reason": "sky"}, 2)
check("read-back", json.loads(txt(r)) == {"rowid": 1, "reason": "sky", "thought": "It is blue.",
                                          "conclusion": "The sky is blue.", "valid": True}, r)
# 3 dup refused
r = call(p, "conclusion", {"reason": "sky", "conclusion": "Other."}, 3)
check("dup-refused", "error" in r and "already recorded" in json.dumps(r), r)
# 4 invalidate + revalidate
r = call(p, "conclusion", {"reason": "sky", "valid": False}, 4)
check("invalidate", json.loads(txt(r)) == {"rowid": 1, "reason": "sky", "valid": False}, r)
r = call(p, "conclusion", {"reason": "sky"}, 5)
check("read-invalid", json.loads(txt(r))["valid"] is False, r)
r = call(p, "conclusion", {"reason": "sky", "valid": True}, 6)
check("revalidate", json.loads(txt(r))["valid"] is True, r)
# 5 missing + bad params
r = call(p, "conclusion", {"reason": "nope"}, 7)
check("read-missing", "error" in r, r)
r = call(p, "conclusion", {"reason": "x", "thought": "lonely"}, 8)
check("thought-alone-params", "error" in r, r)
r = call(p, "conclusion", {"reason": "../evil", "conclusion": "x"}, 9)
# reason allows dots/slashes? ascii only: ../evil IS ascii -> allowed as DB key (flat, safe)
got = r.get("result", {})
check("reason-dots-allowed-as-key", "rowid" in json.dumps(got), r)
r = call(p, "conclusion", {"reason": "caf\u00e9", "conclusion": "x"}, 10)
check("nonascii-reason", "error" in r, r)
nr = call(p, "conclusion", {"reason": "../evil"}, 11)
check("dotted-key-read", json.loads(txt(nr))["conclusion"] == "x", nr)
close(p)

# 6 bulk: 40 big conclusions (~350B each) -> forces root split + interior page
p = spawn()
for i in range(40):
    r = call(p, "conclusion", {"reason": f"bulk-{i:02d}", "thought": f"thought number {i} here",
                               "conclusion": f"Conclusion {i}: " + "padding " * 40}, 100 + i)
    if "error" in r:
        check(f"bulk-{i}", False, r)
        break
else:
    check("bulk-40-inserts", True)
size = os.path.getsize(DB)
pages = size // 4096
print(f"   db size={size} pages={pages}")
check("split-happened", pages >= 4, f"pages={pages}")
ok = True
for i in range(40):
    r = call(p, "conclusion", {"reason": f"bulk-{i:02d}"}, 200 + i)
    try:
        d = json.loads(txt(r))
        good = (d["conclusion"] == f"Conclusion {i}: " + "padding " * 40
                and d["rowid"] == 3 + i and d["thought"] == f"thought number {i} here")
    except Exception:
        good = False
    if not good:
        ok = False
        print("   bad row", i, str(r)[:200])
check("bulk-read-all-40", ok)
close(p)

# 7 think tool regression on new binary
p = spawn()
r = call(p, "sequential_thinking", {"thought": "regression?", "nextThoughtNeeded": False,
                                    "thoughtNumber": 1, "totalThoughts": 1}, 300)
check("think-regression", json.loads(txt(r))["thoughtHistoryLength"] == 1, r)
close(p)

print()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
