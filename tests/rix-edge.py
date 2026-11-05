"""Forge TRUE 2-col legacy usage records via in-place cell truncation, then
differentially verify old vs new binary. Also sparse-rowid + fallback DBs."""
import json, subprocess, os, shutil, sys, sqlite3, struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
BASE = pb_harness.require_state()
OLD = sys.argv[1] if len(sys.argv) > 1 else "/scratch/fasm-webserver/tinythink/tinythink"
NEW = sys.argv[2] if len(sys.argv) > 2 else "/scratch/tmp/tixbuild"
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:400], flush=True)

def varint_encode(v):
    assert 0 <= v < 1 << 64
    if v.bit_length() <= 56:
        groups = []
        vv = v
        while True:
            groups.append(vv & 0x7F); vv >>= 7
            if vv == 0: break
        out = bytearray()
        for g in reversed(groups[1:]): out.append(0x80 | g)
        out.append(groups[0])
        return bytes(out)
    out = bytearray()
    for i in range(7, -1, -1):
        out.append(0x80 | ((v >> (8 * i + 8)) & 0x7F))
    out.append(v & 0xFF)
    return bytes(out)

def varint_decode(d, o):
    r = 0
    for i in range(9):
        b = d[o + i]
        if i == 8:
            r = (r << 8) | b; return r, 9
        r = (r << 7) | (b & 0x7F)
        if not b & 0x80: return r, i + 1
    raise ValueError("bad varint")

def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]

def walk_leaves(pg_bytes, pgno, pages):
    """pages: pgno->bytes. Yields (pgno, cell_off) for leaf cells."""
    d = pages[pgno]
    base = 100 if pgno == 1 else 0
    t = d[base]
    if t == 0x0D:
        n = u16(d, base + 3)
        for i in range(n):
            yield pgno, u16(d, base + 8 + 2 * i)
    elif t == 0x05:
        n = u16(d, base + 3)
        for i in range(n):
            co = u16(d, base + 8 + 2 * i)
            child = struct.unpack(">I", d[co:co + 4])[0]
            yield from walk_leaves(pg_bytes, child, pages)
        right = struct.unpack(">I", d[base + 8:base + 12])[0]
        yield from walk_leaves(pg_bytes, right, pages)
    else:
        raise ValueError(f"bad page type {t} at {pgno}")

def parse_cell(d, off):
    plen, l1 = varint_decode(d, off); o = off + l1
    rowid, l2 = varint_decode(d, o); o += l2
    hsize, l3 = varint_decode(d, o); ho = o; o += l3
    serials = []
    while o < ho + hsize:
        s, l = varint_decode(d, o); serials.append(s); o += l
    vals = []
    for s in serials:
        if s == 0: vals.append(b""); ln = 0
        elif s == 1: vals.append(d[o:o + 1]); ln = 1
        elif 2 <= s <= 6:
            ln = {2: 2, 3: 3, 4: 4, 5: 6, 6: 8}[s]
            vals.append(int.from_bytes(d[o:o + ln], "big", signed=(s in (3, 5))))
        elif s == 8: vals.append(0); ln = 0
        elif s == 9: vals.append(1); ln = 0
        elif s >= 13 and s % 2 == 1: ln = (s - 13) // 2; vals.append(d[o:o + ln])
        elif s >= 12 and s % 2 == 0: ln = (s - 12) // 2; vals.append(bytes(d[o:o + ln]))
        else: raise ValueError(f"non-text serial {s}")
        o += ln
    return plen, l1, rowid, l2, serials, vals

def forge_2col(path, table, match_rowid, c0, c1):
    """Rewrite cell with rowid in table as 2-col (c0,c1) TEXT record in place."""
    raw = bytearray(open(path, "rb").read())
    pages = {}
    npg = len(raw) // 4096
    for p in range(1, npg + 1): pages[p] = raw[(p - 1) * 4096:p * 4096]
    # master: find table root
    root = None
    for _, co in walk_leaves(pages, 1, pages):
        d = pages[1]
        plen, l1, rowid, l2, serials, vals = parse_cell(d, co)
        if len(vals) >= 5 and vals[0].decode() == "table" and vals[1].decode() == table:
            root = int.from_bytes(vals[3], "big") if isinstance(vals[3], (bytes, bytearray)) else int(vals[3]); break
    assert root, f"table {table} not found"
    c0b, c1b = c0.encode(), c1.encode()
    s0 = 13 + 2 * len(c0b); s1 = 13 + 2 * len(c1b)
    hdr = varint_encode(0)  # placeholder
    hdr = varint_encode(1 + len(varint_encode(s0)) + len(varint_encode(s1))) + varint_encode(s0) + varint_encode(s1)
    # fix: hdrsize must equal len(hdr); iterate once (values small, stable)
    while True:
        h = varint_encode(len(hdr)) + varint_encode(s0) + varint_encode(s1)
        if len(h) == len(hdr): hdr = h; break
        hdr = h
    done = False
    for pgno, co in walk_leaves(pages, root, pages):
        d = pages[pgno]
        plen, l1, rowid, l2, serials, vals = parse_cell(d, co)
        if rowid != match_rowid: continue
        base = (pgno - 1) * 4096
        ridbytes = bytes(d[co + l1:co + l1 + l2])
        newrec = ridbytes + hdr + c0b + c1b
        oldlen = (co + l1 + plen) - co
        assert len(newrec) <= oldlen, f"new {len(newrec)} > old {oldlen}"
        raw[co + base:co + base + len(newrec)] = newrec
        for i in range(len(newrec), oldlen): raw[co + base + i] = 0
        # fix payload_len prefix (covers rowid+header+values, not itself)
        newplen = varint_encode(len(newrec))
        assert len(newplen) == l1, "payload len size changed; unsupported"
        raw[co + base:co + base + l1] = newplen
        done = True
        break
    assert done, f"rowid {match_rowid} not found in {table}"
    open(path, "wb").write(raw)

def spawn(work, state):
    env = dict(os.environ, PEABRAIN_STATE_DIR=state)
    return subprocess.Popen([work + "/tt"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, cwd=work, text=True, bufsize=1, env=env)
_i = [100]
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

def build_edge_db():
    wd = "/scratch/tmp/rix-edge-src"
    pb_harness.safe_rmtree(wd); os.makedirs(wd)
    shutil.copy(NEW, wd + "/tt")
    st = pb_harness.new_state("rix-edge-src")
    p = spawn(wd, st)
    for i in range(8):
        call(p, "write_fact", {"name": f"edge{i}", "text": f"edge body {i}"})
    call(p, "create_entities", {"name": "edgeent", "observations": ["edge obs"]})
    for i in range(8):
        call(p, "feedback", {"name": f"edge{i}", "signal": "useful" if i % 2 else "misleading"})
    call(p, "delete_fact", {"name": "edge0"})
    stop(p)
    db = st + "/tinythink.db"
    c0 = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    print("post-engine integrity:", c0.execute("pragma integrity_check").fetchone()[0], flush=True)
    print("post-engine usage rows:", c0.execute("select count(*) from usage").fetchone()[0], flush=True)
    c0.close()
    con = sqlite3.connect(db)
    frow = {r[0]: r[1] for r in con.execute("select name,rowid from facts")}
    orow = con.execute("select rowid from observations limit 1").fetchone()[0]
    con.close()
    # map current v2 usage rows (name -> rowid) to forge
    con = sqlite3.connect(db)
    urows = {r[0]: r[1] for r in con.execute("select name,rowid from usage")}
    con.close()
    plan = [  # (usage rowid to forge, new c0, new c1)
        (urows["edge1"], K(3, 5), "7"),                    # invalid kind
        (urows["edge2"], K(2, 0), "9"),                    # rowid 0
        (urows["edge3"], K(2, 999999999), "3"),            # beyond table
        (urows["edge4"], K(2, frow["edge0"]), "42"),       # valid, tombstoned target
        (urows["edge5"], K(1, 999999), "5"),               # obs, phantom rowid
        (urows["edge6"], K(1, orow), "6"),                 # obs, real rowid
        (urows["edge7"], K(0, 999999999), "2"),            # ent kind, unresolvable
        # edge0's row stays v2 (control); add non-decimal malformed:
    ]
    for urid, c0, c1 in plan:
        forge_2col(db, "usage", urid, c0, c1)
    return db, ["edge0", "edge1", "edge2", "edge3", "edge4", "edge5", "edge6", "edge7", "edgeent", str(orow)]

db, names = build_edge_db()
# verify forged shapes via raw parse
raw = open(db, "rb").read()
pages = {p: raw[(p-1)*4096:p*4096] for p in range(1, len(raw)//4096 + 1)}
uroot = None
for _, co in walk_leaves(pages, 1, pages):
    plen, l1, rid, l2, ss, vv = parse_cell(pages[1], co)
    if len(vv) >= 5 and vv[0].decode() == "table" and vv[1].decode() == "usage": uroot = int.from_bytes(vv[3], "big") if isinstance(vv[3], (bytes, bytearray)) else int(vv[3]); break
twos = 0
for pgno, co in walk_leaves(pages, uroot, pages):
    plen, l1, rid, l2, ss, vv = parse_cell(pages[pgno], co)
    if len(ss) == 2: twos += 1
check("7 forged 2-col rows", twos == 7, twos)

def run_all(binary, work, tag):
    pb_harness.safe_rmtree(work); os.makedirs(work)
    shutil.copy(binary, work + "/tt")
    st = pb_harness.new_state(f"rix-edge-{tag}")
    shutil.copy(db, st + "/tinythink.db")
    p = spawn(work, st)
    h = text(call(p, "health", {}))
    ex = {}
    for n in names:
        kw = {"name": n}
        if n == str(orow := names[-1]):
            kw = {"name": n, "kind": "observation"}
        ex[n] = text(call(p, "explain_rank", kw))
    s = text(call(p, "search_nodes", {"query": "edge", "limit": 20}))
    stop(p)
    return h, ex, s

ho, exo, so = run_all(OLD, "/scratch/tmp/rix-edge-old", "old")
hn, exn, sn = run_all(NEW, "/scratch/tmp/rix-edge-new", "new")
check("edge health tracked equal",
      '"usage_tracked":' in ho and ho.split('"usage_tracked":')[1].split(",")[0] ==
      hn.split('"usage_tracked":')[1].split(",")[0], (ho, hn))
mm = sum(1 for n in names if exo[n] != exn[n])
for n in names:
    if exo[n] != exn[n]: print(f"   DIFF {n}: {exo[n][-140:]} vs {exn[n][-140:]}", flush=True)
check("edge explains identical", mm == 0, f"{mm} diffs")
check("edge search identical", so == sn, f"{so[:200]} vs {sn[:200]}")
print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
