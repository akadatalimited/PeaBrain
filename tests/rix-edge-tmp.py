import json, subprocess, os, shutil, sys, sqlite3
import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
_PB_ST = pb_harness.require_state()

OLD = "/scratch/fasm-webserver/tinythink/tinythink"
NEW = "/scratch/tmp/rixbuild"
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:400], flush=True)

def spawn(work):
    return subprocess.Popen([work + "/tt"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, cwd=work, text=True, bufsize=1)
_i = [10]
def call(p, name, args):
    _i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":_i[0],"method":"tools/call",
                              "params":{"name":name,"arguments":args}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())
def text(r):
    return r.get("result", {}).get("content", [{}])[0].get("text", "")
def stop(p):
    try: p.stdin.close(); p.wait(timeout=10)
    except Exception: p.kill()

def case(tag, setup_fn, extra_names=()):
    """Build DB via NEW binary, apply raw legacy rows, compare OLD vs NEW."""
    wd = f"/scratch/tmp/rix-{tag}"
    shutil.rmtree(wd, ignore_errors=True); os.makedirs(wd)
    shutil.copy(NEW, wd + "/tt")
    p = spawn(wd)
    call(p, "write_fact", {"name": "edgefact", "text": "edge body"})
    call(p, "create_entities", {"name": "edgeent", "observations": ["edge obs"]})
    call(p, "delete_fact", {"name": "edgefact"})
    stop(p)
    con = sqlite3.connect(wd + "/tinythink.db")
    frow = con.execute("select rowid from facts where name='edgefact'").fetchone()[0]
    orow = con.execute("select rowid from observations limit 1").fetchone()[0]
    K = lambda kind, rid: str((kind << 56) | rid)
    # malformed + edge legacy rows (ukey TEXT, hits TEXT)
    rows = [
        (K(3, 5), "7"),          # invalid kind
        (K(2, 0), "9"),          # rowid 0
        (K(2, 999999999), "3"),  # rowid beyond table
        (K(2, frow), "42"),      # valid legacy for tombstoned fact
        (K(1, 999999), "5"),     # legacy obs, nonexistent rowid (accepted identity)
        (K(1, orow), "6"),       # legacy obs, real rowid
        (K(0, 999999999), "2"),  # entity kind, unresolvable
    ]
    extra = setup_fn(con, frow, orow, K)
    rows += extra
    con.executemany("insert into usage values (?, 'x', null,null,null,null,null,null)".replace("'x','", "'x',").replace("values (?, 'x',", "values (?, 'x',"), [(r[0],) for r in []]) if False else None
    for ukey, hits in rows:
        con.execute("insert into usage(name,kind,access,pos,neg,last,conf,v) values(?,?,?,?,?,?,?,?)",
                    (ukey, "0", None, None, None, None, None, None))
        # NOTE: legacy shape is 2 cols; emulate by inserting then blanking? engine
        # reads raw cells — instead write minimal 2-col rows via raw SQL below.
    con.commit()
    # rewrite those rows as true 2-col cells: delete + reinsert name-only pairs
    con.execute("delete from usage where access is null")
    for ukey, hits in rows:
        con.execute("insert into usage(rowid,name) values(null,?)", (ukey,))
        # fix: need (ukey,hits) 2-col — use explicit column list on 8-col table:
    con.commit()
    con.close()
    # The above attempt can't make 2-col rows via SQL on an 8-col table; the
    # engine keys shape off the RECORD, so emulate legacy by NULLing cols is
    # wrong. Redo properly below with raw record surgery instead.
    return wd, frow, orow

print("setup helper defined (real cases constructed inline below)", flush=True)
