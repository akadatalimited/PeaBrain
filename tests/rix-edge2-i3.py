"""Edge-case differential: unique dir per case, long target names (forge fits),
verify-after-each-write. Compares shipped Master (legacy resolver) vs index build."""
import json, subprocess, os, shutil, sys, sqlite3, struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
BASE = pb_harness.require_state()
OLD = "/scratch/tmp/tixbuild"
NEW = "/scratch/tmp/int3-b1"
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:400], flush=True)

def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def vd(d, o):
    r = 0
    for i in range(9):
        b = d[o + i]
        if i == 8: r = (r << 8) | b; return r, 9
        r = (r << 7) | (b & 0x7F)
        if not b & 0x80: return r, i + 1
    raise ValueError("bad varint")
def ve(v):
    assert 0 <= v < 1 << 64
    if v.bit_length() <= 56:
        groups = []; vv = v
        while True:
            groups.append(vv & 0x7F); vv >>= 7
            if vv == 0: break
        out = bytearray()
        for g in reversed(groups[1:]): out.append(0x80 | g)
        out.append(groups[0])
        return bytes(out)
    out = bytearray()
    for i in range(7, -1, -1): out.append(0x80 | ((v >> (8 * i + 8)) & 0x7F))
    out.append(v & 0xFF)
    return bytes(out)
def walk(d, pgno, pages):
    b = 100 if pgno == 1 else 0
    t = d[b]
    if t == 0x0D:
        for i in range(u16(d, b + 3)): yield pgno, u16(d, b + 8 + 2 * i)
    elif t == 0x05:
        for i in range(u16(d, b + 3)):
            co = u16(d, b + 8 + 2 * i)
            ch = struct.unpack(">I", d[co:co + 4])[0]
            yield from walk(d, ch, pages)
        yield from walk(d, struct.unpack(">I", d[b + 8:b + 12])[0], pages)
    else: raise ValueError((pgno, t))
def pc(d, off):
    plen, l1 = vd(d, off); o = off + l1
    rid, l2 = vd(d, o); o += l2
    hs, l3 = vd(d, o); ho = o; o += l3
    ss = []
    while o < ho + hs:
        s, l = vd(d, o); ss.append(s); o += l
    vv = []; oo = o
    for s in ss:
        if s == 0: vv.append(b""); ln = 0
        elif s == 1: vv.append(bytes(d[oo:oo + 1])); ln = 1
        elif 2 <= s <= 6:
            ln = {2: 2, 3: 3, 4: 4, 5: 6, 6: 8}[s]
            vv.append(int.from_bytes(d[oo:oo + ln], "big"))
        elif s >= 13:
            ln = (s - 13) // 2 if s % 2 == 1 else (s - 12) // 2
            vv.append(bytes(d[oo:oo + ln]))
        else: raise ValueError(s)
        oo += ln
    return plen, l1, rid, l2, ss, vv

def table_root(pages, table):
    for _, co in walk(pages[1], 1, pages):
        plen, l1, rid, l2, ss, vv = pc(pages[1], co)
        if len(vv) >= 5 and vv[0] == b"table" and vv[1] == table.encode():
            r = vv[3]
            return r if isinstance(r, int) else int.from_bytes(r, "big")
    raise ValueError(f"no table {table}")

def forge_2col(path, match_rowid, c0, c1):
    raw = bytearray(open(path, "rb").read())
    pages = {p: raw[(p - 1) * 4096:p * 4096] for p in range(1, len(raw) // 4096 + 1)}
    root = table_root(pages, "usage")
    c0b, c1b = c0.encode(), c1.encode()
    s0, s1 = 13 + 2 * len(c0b), 13 + 2 * len(c1b)
    hdr = ve(1 + len(ve(s0)) + len(ve(s1))) + ve(s0) + ve(s1)
    while True:
        h = ve(len(hdr)) + ve(s0) + ve(s1)
        if len(h) == len(hdr): hdr = h; break
        hdr = h
    for pgno, co in walk(pages[root], root, pages):
        plen, l1, rid, l2, ss, vv = pc(pages[pgno], co)
        if rid != match_rowid: continue
        base = (pgno - 1) * 4096
        print(f"   match pg{pgno} off{co} plen={plen} l1={l1} rid={rid} l2={l2} ncols={len(ss)} c0={vv[0][:30] if vv else None}", flush=True)
        newrec = bytes(raw[base + co + l1:base + co + l1 + l2]) + hdr + c0b + c1b
        print(f"   body={newrec.hex()}", flush=True)
        oldlen = l1 + plen
        newplen = ve(len(newrec))
        assert len(newplen) == l1
        full = newplen + newrec
        assert len(full) <= oldlen, f"forge too big {len(full)} > {oldlen}"
        raw[base + co:base + co + len(full)] = full
        for i in range(len(full), oldlen): raw[base + co + i] = 0
        open(path, "wb").write(raw)
        # immediate verification: re-parse forged cell with our own reader
        # (stock sqlite may grumble about free accounting; the engine, which
        # navigates by pointer array, is the arbiter and is checked below)
        raw2 = open(path, "rb").read()
        d2 = raw2[base:base + 4096]
        print(f"   reread: {bytes(d2[co:co+30]).hex()}", flush=True)
        plen2, l12, rid2, l22, ss2, vv2 = pc(d2, co)
        assert rid2 == match_rowid and len(ss2) == 2, (rid2, len(ss2))
        assert vv2[0].decode() == c0 and vv2[1].decode() == c1
        return
    raise ValueError(f"rowid {match_rowid} not found")

def spawn(work, binary, state):
    shutil.copy(binary, work + "/tt")
    env = dict(os.environ, PEABRAIN_STATE_DIR=state)
    return subprocess.Popen([work + "/tt"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, cwd=work, text=True, bufsize=1, env=env)
_i = [1000]
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

K = lambda kind, rid: str((kind << 56) | rid)
LONG = "edge-target-with-a-long-name-"
names = [f"{LONG}{i:02d}" for i in range(8)]

def build_src():
    wd = "/scratch/tmp/rix-edge2-src"
    pb_harness.safe_rmtree(wd); os.makedirs(wd)
    st = pb_harness.new_state("rix-edge2-src")
    p = spawn(wd, NEW, st)
    for n in names:
        call(p, "write_fact", {"name": n, "text": f"body of {n}"})
    call(p, "create_entities", {"name": "edgeent-xyz", "observations": ["edge obs here"]})
    for n in names:
        call(p, "feedback", {"name": n, "signal": "useful"})
    call(p, "delete_fact", {"name": names[0]})
    stop(p)
    db = st + "/peabrain.db"
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    assert con.execute("pragma integrity_check").fetchone()[0] == "ok"
    frow = {r[0]: r[1] for r in
            sqlite3.connect(db).execute("select name,rowid from facts").fetchall()}
    orow = sqlite3.connect(db).execute("select rowid from observations limit 1").fetchone()[0]
    urows = {r[0]: r[1] for r in
             sqlite3.connect(db).execute("select name,rowid from usage").fetchall()}
    return db, frow, orow, urows

db, frow, orow, urows = build_src()
plan = [
    ("kind3", urows[names[1]], K(3, 5), "7"),
    ("rowid0", urows[names[2]], K(2, 0), "9"),
    ("beyond", urows[names[3]], K(2, 999999999), "3"),
    ("tombvalid", urows[names[4]], K(2, frow[names[0]]), "42"),
    ("obsphantom", urows[names[5]], K(1, 999999), "5"),
    ("obsreal", urows[names[6]], K(1, orow), "6"),
    ("entunres", urows[names[7]], K(0, 999999999), "2"),
]
for tag, urid, c0, c1 in plan:
    forge_2col(db, urid, c0, c1)
    print(f"forged {tag}", flush=True)

con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
raw = open(db, "rb").read()
pages = {p: raw[(p-1)*4096:p*4096] for p in range(1, len(raw)//4096 + 1)}
uroot = table_root(pages, "usage")
twos = sum(1 for pgno, co in walk(pages[uroot], uroot, pages)
           if pc(pages[pgno], co)[4].__len__() == 2)
check("7 forged 2-col rows", twos == 7, twos)
# NOTE: stock integrity_check is not the gate for surgically forged pages
# (freeblock accounting); the engine differential below is the arbiter.
con.close()

def run_all(binary, work, tag):
    pb_harness.safe_rmtree(work); os.makedirs(work)
    st = pb_harness.new_state(f"rix-edge2-{tag}")
    shutil.copy(db, st + "/peabrain.db")
    shutil.copy(binary, work + "/tt")
    p = spawn(work, binary, st)
    h = text(call(p, "health", {}))
    targets = names + ["edgeent-xyz", str(orow)]
    ex = {}
    for n in targets:
        kw = {"name": n, "kind": "observation"} if n == str(orow) else {"name": n}
        ex[n] = text(call(p, "explain_rank", kw))
    s = text(call(p, "search_nodes", {"query": "edge-target", "limit": 20}))
    stop(p)
    return h, ex, s

ho, exo, so = run_all(OLD, "/scratch/tmp/rix-edge2-old", "old")
hn, exn, sn = run_all(NEW, "/scratch/tmp/rix-edge2-new", "new")
def tracked(h):
    return h.split('"usage_tracked":')[1].split(",")[0]
check("edge tracked equal", tracked(ho) == tracked(hn), (tracked(ho), tracked(hn)))
mm = 0
for n in ["edge0"] + names[1:] + ["edgeent-xyz", str(orow)]:
    pass
for n in list(exo.keys()):
    if exo[n] != exn[n]:
        mm += 1
        print(f"   DIFF {n}: {exo[n][-140:]} vs {exn[n][-140:]}", flush=True)
check("edge explains identical", mm == 0, f"{mm} diffs")
check("edge search identical", so == sn, f"{so[:200]} vs {sn[:200]}")
print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
