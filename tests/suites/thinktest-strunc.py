import json, subprocess, sys

BIN = "/scratch/fasm-webserver/think"
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)
        print("   extra:", str(extra)[:300])

p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
rid = 0
def send(o):
    global rid
    if isinstance(o, dict) and "id" not in o:
        pass
    p.stdin.write((json.dumps(o) if isinstance(o, dict) else o) + "\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())

def call(tool, args, rid):
    return send({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                 "params": {"name": tool, "arguments": args}})

def ttext(r):
    return r["result"]["content"][0]["text"]

# 2025 era init
r = send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
check("init", r.get("result", {}).get("serverInfo", {}).get("name") == "tinythink", r)
# 2026 era discover (no handshake needed, with id here)
r = send({"jsonrpc": "2.0", "id": 2, "method": "server/discover"})
check("discover", r.get("result", {}).get("protocolVersion") == "2026-07-28"
      and any(t["name"] == "sequential_thinking" for t in r["result"].get("tools", [])), r)
# discover without id = silent, then ping proves framing
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "server/discover"}) + "\n"); p.stdin.flush()
r = send({"jsonrpc": "2.0", "id": 3, "method": "ping"})
check("discover-noid-silent+ping", r.get("result") == {} and r.get("id") == 3, r)
# tools/list schema
r = send({"jsonrpc": "2.0", "id": 4, "method": "tools/list"})
tools = r.get("result", {}).get("tools", [])
st = next((t for t in tools if t.get("name") == "sequential_thinking"), None)
props = (st or {}).get("inputSchema", {}).get("properties", {})
req = (st or {}).get("inputSchema", {}).get("required", [])
check("tools/list-schema",
      st is not None and props.get("thought", {}).get("type") == "string"
      and props.get("thoughtNumber", {}).get("type") == "integer"
      and props.get("nextThoughtNeeded", {}).get("type") == "boolean"
      and sorted(req) == sorted(["thought", "nextThoughtNeeded", "thoughtNumber", "totalThoughts"]), st)

# thought 1: plain
r = call("sequential_thinking", {"thought": "First, survey the problem space.",
                                 "nextThoughtNeeded": True, "thoughtNumber": 1,
                                 "totalThoughts": 3}, 10)
inner = json.loads(ttext(r))
check("think1", inner == {"thoughtNumber": 1, "totalThoughts": 3,
                          "nextThoughtNeeded": True, "thoughtHistoryLength": 1}, inner)
# thought 2: with branch
r = call("sequential_thinking", {"thought": "Branch: consider the risky option.",
                                 "nextThoughtNeeded": True, "thoughtNumber": 2,
                                 "totalThoughts": 3, "branchFromThought": 1,
                                 "branchId": "risk"}, 11)
inner = json.loads(ttext(r))
check("think2-branch", inner.get("branchFromThought") == 1 and inner.get("branchId") == "risk"
      and inner.get("thoughtHistoryLength") == 2, inner)
# thought 3: revision + needsMoreThoughts false + done
r = call("sequential_thinking", {"thought": "Revised plan is solid.",
                                 "nextThoughtNeeded": False, "thoughtNumber": 3,
                                 "totalThoughts": 3, "isRevision": True,
                                 "revisesThought": 1, "needsMoreThoughts": False}, 12)
inner = json.loads(ttext(r))
check("think3-revision", inner.get("isRevision") is True and inner.get("revisesThought") == 1
      and inner.get("needsMoreThoughts") is False and inner.get("thoughtHistoryLength") == 3, inner)

# errors
r = call("sequential_thinking", {"nextThoughtNeeded": True, "thoughtNumber": 1, "totalThoughts": 1}, 20)
check("missing-thought", "error" in r, r)
r = call("sequential_thinking", {"thought": "x", "nextThoughtNeeded": "yes", "thoughtNumber": 1, "totalThoughts": 1}, 21)
check("bad-bool", "error" in r, r)
r = call("sequential_thinking", {"thought": "x", "nextThoughtNeeded": True, "thoughtNumber": "one", "totalThoughts": 1}, 22)
check("bad-int", "error" in r, r)
r = call("nope_tool", {"thought": "x"}, 23)
check("unknown-tool", "error" in r, r)
r = send({"jsonrpc": "2.0", "id": 24, "method": "frobnicate"})
check("unknown-method", r.get("error", {}).get("code") == -32601, r)
# notifications/initialized emits nothing: write it raw, then ping must be the next reply
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
p.stdin.flush()
# silent: next reply must be the ping, proving nothing was emitted
r = send({"jsonrpc": "2.0", "id": 25, "method": "ping"})
check("notif-silent", r.get("id") == 25, r)
# history kept growing across calls in this connection (next one must be #4)
r = call("sequential_thinking", {"thought": "One more.", "nextThoughtNeeded": False,
                                 "thoughtNumber": 4, "totalThoughts": 4}, 26)
inner = json.loads(ttext(r))
check("history-persists", inner.get("thoughtHistoryLength") == 4, inner)

p.stdin.close(); p.wait(timeout=5)
print()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
