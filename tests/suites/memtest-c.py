import json, subprocess, os, sys
import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pb_harness
_PB_ST = pb_harness.require_state()

SRC = sys.argv[1] if len(sys.argv) > 1 else "/scratch/tmp/int3-b1"
WORK = "/scratch/tmp/rk-ttmem"
os.system(f"rm -rf {WORK}")
os.makedirs(WORK)
os.system(f"cp {SRC} {WORK}/tt0 && chmod +x {WORK}/tt0")
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)
        print("   extra:", str(extra)[:400])

p = subprocess.Popen([f"{WORK}/tt0"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=WORK, text=True, bufsize=1)
rid = [0]
def send(o):
    p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
def call(tool, args):
    rid[0] += 1
    return send({"jsonrpc": "2.0", "id": rid[0], "method": "tools/call",
                 "params": {"name": tool, "arguments": args}})
def tx(r):
    return r["result"]["content"][0]["text"]

# tools advertised?
r = send({"jsonrpc": "2.0", "id": 999, "method": "tools/list"})
names = sorted(t["name"] for t in r["result"]["tools"])
for t in ["read_fact", "write_fact", "list_facts", "create_entities", "add_observations",
          "search_nodes", "open_nodes", "create_task_or_note", "query_tasks", "update_task",
          "create_relations", "sequential_thinking", "conclusion", "thought_history", "thought_reset"]:
    check("adv-" + t, t in names, names)

# facts
r = call("write_fact", {"name": "cap", "text": "Paris"})
check("f-write", json.loads(tx(r))["rowid"] == 1, r)
r = call("read_fact", {"name": "cap"})
check("f-read", json.loads(tx(r)) == {"rowid": 1, "name": "cap", "body": "Paris"}, r)
r = call("write_fact", {"name": "cap", "text": "Paris, France"})
r = call("read_fact", {"name": "cap"})
d = json.loads(tx(r))
check("f-version", d["body"] == "Paris, France" and d["rowid"] == 2, d)
r = call("write_fact", {"name": "sky", "text": "blue"})
r = call("list_facts", {})
check("f-list", "sky" in tx(r) and "cap" in tx(r), r)
r = call("read_fact", {"name": "nope"})
check("f-missing", "error" in r, r)
r = call("write_fact", {"name": "bad/name", "text": "x"})
check("f-badname", "error" in r, r)

# entities + observations
r = call("create_entities", {"name": "ada", "type": "person", "project": "hist",
                              "observations": ["first programmer", "loved numbers"]})
d = json.loads(tx(r))
check("e-create", d["name"] == "ada" and d["created"] is True, d)
r = call("create_entities", {"name": "ada"})
d = json.loads(tx(r))
check("e-dup", d["created"] is False and d["rowid"] == 1, d)
r = call("add_observations", {"name": "ada", "observations": ["wrote the Bernoulli notes"]})
check("e-addobs", json.loads(tx(r))["added"] == 1, r)
r = call("add_observations", {"name": "grace", "observations": ["cobol"]})
check("e-autocreate", json.loads(tx(r))["added"] == 1, r)

# relations
r = call("create_relations", {"from": "ada", "to": "grace", "type": "influenced"})
check("r-create", "error" not in r, r)
r = call("create_relations", {"from": "ada", "to": "grace", "type": "influenced"})
check("r-dup-ok", "error" not in r, r)

# search + open (direct array results)
r = call("search_nodes", {"query": "programmer"})
res = json.loads(r["result"]["content"][0]["text"])["results"]
check("s-hit", isinstance(res, list) and any("programmer" in json.dumps(x) for x in res), res)
r = call("search_nodes", {"query": "zzz-no-match"})
check("s-miss", json.loads(r["result"]["content"][0]["text"]) == {"results": []}, r)
r = call("open_nodes", {"names": ["ada", "ghost"]})
nodes = json.loads(r["result"]["content"][0]["text"])["nodes"]
ada = next((n for n in nodes if n.get("name") == "ada"), None)
ghost = next((n for n in nodes if n.get("name") == "ghost"), None)
check("o-ada", ada is not None and len(ada.get("observations", [])) == 3
      and any(x.get("to") == "grace" for x in ada.get("relations", [])), ada)
check("o-ghost", ghost is not None and ghost.get("missing") is True, ghost)

# tasks
r = call("create_task_or_note", {"title": "Write docs", "body": "explain stuff",
                                  "project": "tt", "priority": "high"})
d = json.loads(tx(r))
check("t-create", d["id"] == 1 and d["status"] == "not_started", d)
r = call("create_task_or_note", {"title": "Fix bug", "status": "in_progress"})
d = json.loads(tx(r))
check("t-create2", d["id"] == 2, d)
r = call("query_tasks", {})
ts = json.loads(r["result"]["content"][0]["text"])["tasks"]
check("t-query-all", len(ts) == 2 and ts[0]["id"] == 2, ts)
r = call("query_tasks", {"status": "not_started"})
check("t-query-status", len(json.loads(r["result"]["content"][0]["text"])["tasks"]) == 1, r)
r = call("query_tasks", {"search": "docs"})
check("t-query-search", len(json.loads(r["result"]["content"][0]["text"])["tasks"]) == 1, r)
r = call("update_task", {"id": 1, "status": "done"})
d = json.loads(tx(r))
check("t-update", d["id"] == 1 and d["status"] == "done" and d["title"] == "Write docs", d)
r = call("query_tasks", {"status": "done"})
ts = json.loads(r["result"]["content"][0]["text"])["tasks"]
check("t-query-updated", len(ts) == 1 and ts[0]["id"] == 1 and ts[0]["body"] == "explain stuff", ts)
r = call("query_tasks", {"status": "not_started"})
check("t-old-gone", json.loads(r["result"]["content"][0]["text"]) == {"tasks": []}, r)
r = call("update_task", {"id": 99, "status": "done"})
check("t-missing", "error" in r, r)
r = call("update_task", {"id": 1, "status": "bogus"})
check("t-badstatus", "error" in r, r)
r = call("update_task", {"id": 1})
check("t-nofields", "error" in r, r)

p.stdin.close(); p.wait(timeout=10)
print()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
