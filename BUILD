tinythink - sequential-thinking MCP server in pure x86-64 assembly
===============================================================

Mimics @modelcontextprotocol/server-sequential-thinking as a ~14K
statically-linked Linux binary with no libc and no dependencies, plus a
conclusion tool backed by a real SQLite database written in pure asm
(no includes).

Needs: fasm (flat assembler) 1.73+, Linux x86-64.

Build
-----
  fasm tinythink.asm tinythink

Run (MCP stdio: newline-delimited JSON-RPC on stdin/stdout)
-----
  ./tinythink

Use
---
Register as a local MCP server, e.g. opencode.json:

  { "mcp": { "tinythink": {
      "type": "local",
      "command": ["/path/to/tinythink"],
      "enabled": true } } }

Serves both protocol eras: 2026-07-28 clients (server/discover, no
handshake) and 2025-era clients (initialize). Methods: initialize,
server/discover, ping, tools/list, tools/call.

Tools
-----
sequential_thinking: record thoughts, revise, branch, track progress.
  Required: thought (1..2048), nextThoughtNeeded (bool),
  thoughtNumber (int), totalThoughts (int). Optional: isRevision,
  revisesThought, branchFromThought, branchId (0..40), needsMoreThoughts.
  History lives in RAM for the connection (64-slot ring).

conclusion {reason, thought?, conclusion?, valid?} against tinythink.db,
  created on first use beside the executable:
  conclusions(reason TEXT, thought TEXT, conclusion TEXT, valid INTEGER).
  reason 1..64 ascii; thought 0..512 ascii; conclusion 1..512 ascii.
  conclusion present -> insert (duplicate reason refused); else valid
  present -> set the valid flag (invalidate with false, revalidate with
  true); else read the row by reason.

SQLite subset (genuine on-disk format: pragma integrity_check passes,
opens in real sqlite3, bidirectional): page size 4096, UTF-8, single
table + sqlite_master, rowid leaf pages, size-ordered leaf splits, root
interior on first split, dead space on the freelist, whole-db flock,
fsync per write txn. Limits: cell <= ~1100B, interior never splits
(~600 leaves, thousands of conclusions), no overflow pages, no journal.

Smoke test
----------
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sequential_thinking","arguments":{"thought":"hi","nextThoughtNeeded":false,"thoughtNumber":1,"totalThoughts":1}}}' \
  | ./tinythink
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"conclusion","arguments":{"reason":"sky","conclusion":"blue"}}}' \
  | ./tinythink
  sqlite3 tinythink.db "select rowid,reason,conclusion,valid from conclusions;"
