import json, subprocess, sys, os, shutil
import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pb_harness
_PB_ST = pb_harness.require_state()

BIN_SRC = "/scratch/tmp/int3-b1"
WORK = "/scratch/tmp/rk-ttadvwork"
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
shutil.copy(BIN_SRC, WORK + "/tt")
BIN = WORK + "/tt"
p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=WORK, text=True, bufsize=1)
fails = []
def raw(line, note=""):
    p.stdin.write(line if line.endswith("\n") else line + "\n"); p.stdin.flush()
    r = p.stdout.readline()
    try:
        return json.loads(r)
    except Exception:
        fails.append(note or line[:80])
        print("BADJSON", note, repr(r[:120]))
        return {"_badjson": True}

def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)
        print("   extra:", str(extra)[:300])

L = '"jsonrpc":"2.0"'
# 1. reviewer's PoC: nested decoy EARLIER, outer real value later
r = raw('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sequential_thinking","arguments":{"decoy":{"thought":"DECOY-SELECTED-BY-PARSER"},"thought":"INTENDED-OUTER-VALUE","nextThoughtNeeded":false,"thoughtNumber":1,"totalThoughts":1}}}', "decoy-think")
t = r.get("result", {}).get("content", [{}])[0].get("text", "")
check("nested-decoy-ignored", "INTENDED-OUTER-VALUE" not in t or "DECOY" not in t, r)
# history must show the outer value, not the decoy
r = raw('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"thought_history","arguments":{}}}', "hist")
h = r.get("result", {}).get("content", [{}])[0].get("text", "")
check("history-has-outer", "INTENDED-OUTER-VALUE" in h and "DECOY" not in h, h[:200])

# 2. decoy tool name earlier at wrong depth
r = raw('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"meta":{"name":"write_fact"},"name":"sequential_thinking","arguments":{"thought":"real","nextThoughtNeeded":false,"thoughtNumber":2,"totalThoughts":2}}}', "decoy-tool")
t = r.get("result", {}).get("content", [{}])[0].get("text", "")
check("decoy-tool-ignored", '"thoughtNumber":2' in t, r)

# 3. key-like text inside strings must not match
r = raw('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"sequential_thinking","arguments":{"thought":"say \\"thoughtNumber\\": 99 here","nextThoughtNeeded":false,"thoughtNumber":3,"totalThoughts":3}}}', "str-key")
t = r.get("result", {}).get("content", [{}])[0].get("text", "")
check("string-key-ignored", '"thoughtNumber":3' in t, r)

# 4. duplicate keys same object -> rejected
r = raw('{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"sequential_thinking","arguments":{"thought":"a","thought":"b","nextThoughtNeeded":false,"thoughtNumber":4,"totalThoughts":4}}}', "dup-args")
check("dup-in-object", "error" in r and "duplicate key" in json.dumps(r), r)
r = raw('{"jsonrpc":"2.0","id":6,"method":"ping","method":"ping"}', "dup-top")
check("dup-top-level", "error" in r, r)

# 5. malformed: unbalanced, unterminated string
r = raw('{"jsonrpc":"2.0","id":7,"method":"ping"', "unbalanced")
check("unbalanced-rejected", "error" in r, r)
r = raw('{"jsonrpc":"2.0","id":8,"method":"pin', "unterminated")
check("unterminated-rejected", "error" in r, r)

# 6. legit traffic still fine (all arg shapes incl. arrays, nested none)
r = raw('{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"conclusion","arguments":{"reason":"adv","conclusion":"ok"}}}', "legit-conc")
check("legit-conclusion", "rowid" in json.dumps(r.get("result", {})), r)
r = raw('{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"open_nodes","arguments":{"names":["a","b"]}}}', "legit-open")
check("legit-open", "error" not in r, r)
r = raw('{"jsonrpc":"2.0","id":11,"method":"tools/list"}', "legit-list")
# 21 base + 6 model_* (model_init/train/predict/save/load/status)
check("legit-list", len(r.get("result", {}).get("tools", [])) == 27, len(r.get("result", {}).get("tools", [])))

# 7. feedback + explain_rank learning tools
r = raw('{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"write_fact","arguments":{"name":"learnable","text":"rank me"}}}', "learn-write")
check("learn-write", "rowid" in json.dumps(r.get("result", {})), r)
r = raw('{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"feedback","arguments":{"name":"learnable","signal":"useful"}}}', "learn-fb")
check("learn-feedback", 'recorded' in json.dumps(r.get("result", {})) and ':true' in json.dumps(r.get("result", {})), r)
r = raw('{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"explain_rank","arguments":{"name":"learnable"}}}', "learn-explain")
d = json.dumps(r.get("result", {}))
check("learn-explain", 'useful' in d and 'score' in d and 'weights' in d, d[:200])
r = raw('{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"feedback","arguments":{"name":"learnable","signal":"bogus"}}}', "learn-fbbad")
check("learn-feedback-badsignal", "error" in r, r)
r = raw('{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"feedback","arguments":{"name":"learnable"}}}', "learn-fbmissing")
check("learn-feedback-missingsignal", "error" in r, r)

p.stdin.close(); p.wait(timeout=10)
print()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
