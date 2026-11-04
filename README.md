# tinythink

Persistent agent memory in ~53 KB: a pure-FASM x86-64 MCP server backed by
a genuine on-disk SQLite database. No libc, no interpreter, no runtime —
raw syscalls only. It speaks MCP stdio JSON-RPC and stores thoughts,
facts, entities, relations, and tasks in `tinythink.db` next to the binary.

## Features

- **19 MCP tools**: `sequential_thinking`, `thought_history`, `thought_reset`,
  `conclusion`, `write_fact`, `read_fact`, `list_facts`, `read_fact_versions`,
  `delete_fact`, `delete_fact_prefix`, `create_entities`, `add_observations`,
  `create_relations`, `search_nodes`, `open_nodes`, `create_task_or_note`,
  `query_tasks`, `update_task`, `health`.
- **Real SQLite format**: 4096-byte pages, UTF-8, rowid leaf pages.
  `pragma integrity_check` passes and the file opens in stock `sqlite3`.
- **Unbounded growth**: interiors split at any depth (right-edge appends;
  the root keeps its page number, so `sqlite_master` is never rewritten).
  Validated with a 100,000-row volume: depth 3, 1369 pages, zero orphans,
  integrity clean at every checkpoint.
- **Crash-safe**: rollback journal with torn-tail-tolerant recovery on open,
  `fsync` + `unlink` + dirsync commit on close. Reads take `LOCK_SH`,
  writers `LOCK_EX`, so concurrent clients share one database.
- **Lifecycle, not just storage**: versioned facts (`read_fact_versions`
  newest-first with `current`/`tombstoned` flags), write-once tombstones
  (`delete_fact`, bulk `delete_fact_prefix` capped at 128 names) that hide
  names from reads, search, and open-nodes. Tombstoned bytes are retained
  (hidden, not wiped — not secure deletion) and names never resurrect.
- **It learns**: an 8192-slot usage table ranks search results and persists
  across restarts in the `usage` table; a 16-slot LRU page cache serves hot
  reads (~140x on large files).
- **Hardened input**: ASCII-only names (`[A-Za-z0-9._-]`, 1–64 chars) and
  text, duplicate-key rejection, header-last parsing, `0600` database file
  with uid check, non-executable stack, PIE.

## Requirements

- Linux x86-64, CPU with x86-64-v3 (AVX/AVX2/FMA/BMI1/BMI2/LZCNT —
  verified by a CPUID gate at startup with a clear error otherwise).
- [FASM](https://flatassembler.net/) 1.73+ to build.

## Build

```sh
fasm tinythink.asm tinythink        # vector build (default)
fasm -dUSE_SCALAR=1 tinythink.asm tinythink-scalar   # portable fallback
```

Both builds are behaviorally identical (differential suites assert this).
If the linker complains the target is busy (`ETXTBSY`), build to a temp
file and rename over it:

```sh
fasm tinythink.asm /tmp/tt0 && mv /tmp/tt0 tinythink
```

## Run

The repo ships the built application as `tinythink` — no build needed,
no dependencies (not even libc). It runs on any Linux x86-64 machine
with an x86-64-v3 CPU (AVX/AVX2/FMA/BMI1/BMI2/LZCNT; anything from ~2013
onward — it refuses with a clear error otherwise):

```sh
chmod +x tinythink
./tinythink   # speaks MCP stdio JSON-RPC; Ctrl-D / stdin close to stop
```

`tinythink` is an MCP stdio server: newline-delimited JSON-RPC on
stdin/stdout. The database (`tinythink.db`) is created **next to the
executable** on first write, so each copy of the binary is a separate
store — copy it somewhere else for a scratch database. Minimal client
config (opencode):

```json
{ "mcp": { "tinythink": {
  "type": "local",
  "command": ["/path/to/tinythink"],
  "enabled": true } } }
```

Smoke test:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call",
  "params":{"name":"write_fact","arguments":{"name":"hello","text":"world"}}}' \
  | ./tinythink
```

Every response uses the MCP `content` envelope.
`health` reports `{tables, pages, journal, cache_used, usage_tracked,
pending_flush}`; `pending_flush:true` after reads is normal (learned
hits flush on exit or piggyback on the next write commit).

## Documented limits

- Cells ≤ ~1100 bytes; names 1–64 chars `[A-Za-z0-9._-]`; text ASCII only.
- Listing budgets cap large outputs; distinct-name scans are capped
  (facts 128, tasks 512); prefix deletion caps at 128 names (`capped:true`).
- No overflow pages; growth comes from page splits, bounded only by the
  file format and disk.

## Benchmarks

Fresh scratch databases, same machine (medians; `bench*.py` methodology:
pinned rounds, warmup discarded):

| Workload | v3 | scalar |
|---|---|---|
| think record | 0.017 ms (42k op/s) | ~2x slower |
| 1 KB fact write (durable) | 0.090 ms (10–11k op/s) | ~2x slower |
| 1 KB fact read | 0.033–0.059 ms (19k op/s) | ~2x slower |
| search, 2k-observation corpus (miss / hit) | 0.088 / 0.108 ms | 0.123 / 0.138 ms |
| open_nodes (50-observation entity) | 0.029 ms | same (memory-bound) |
| list_facts | 0.20 ms | 0.14 ms |

End-to-end through MCP on the live database: 1,000
write→update→read→tombstone→verify cycles at **15.59 cycles/s**
(31.18 durable writes/s), **132.56 warm reads/s**, 0 errors; 10/10
sequential checkpoints accepted. Extended stress: **3,000 cycles
(15,000 MCP ops, 6,000 durable writes, 3,000 tombstones) at 14.5
cycles/s (29.01 writes/s), 0 errors**, pages growing 716→1,146
through real splits with integrity clean throughout.

Crash recovery is tested, not just designed: SIGKILL mid-transaction
(4 KB journal on disk, splits in flight) followed by reopen recovers
via the journal, leaves no journal behind, and verifies clean
(structure + `integrity_check` + exact row counts).

## Repository

- `tinythink` — the built application, committed so anyone can run it
  immediately (rebuilt from `tinythink.asm` byte-identically; see Build).
- `tinythink.asm` — the entire server (~11.5k lines, no includes).
- `BUILD` — build notes, tool/capacity/security documentation.
- Databases (`tinythink.db*`) and backups (`*.bak-*`) are untracked by
  design (see `.gitignore`) — your memory stays yours.

## Binary layout (for the curious)

`readelf -lW` shows an `ET_DYN` static PIE with two `LOAD` segments
(R+E code, RW data), no `INTERP` (there is no libc to load), a
flagless `GNU_STACK` (non-executable stack), and no section headers —
all normal for a FASM `format ELF64 dynamic` binary that only issues
syscalls. ASLR is effective (two live instances map their code at
distinct randomized bases) since all addressing is RIP-relative.

Size split (~53 KB on disk, ~1.1 MB resident): ~44 KB code, ~11 KB
file-backed writable data, ~1.1 MB BSS. The binary used to be ~1 MB
because FASM emits leading `rb` blocks as file zeros and only trailing
`rb` becomes NOBITS (verified with a minimal probe: 1 MB `rb` before an
8-byte `dq` → 1 MB file; after → 193 bytes). Moving the giant tables
(`childtab`, `utab`, `thslots`, caches) after the last initialized datum
shrunk it 19x with a byte-identical runtime footprint.
