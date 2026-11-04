tinythink - sequential-thinking MCP server in pure x86-64 assembly
===============================================================

Mimics @modelcontextprotocol/server-sequential-thinking as a ~6K
statically-linked Linux binary with no libc and no dependencies.

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
server/discover, ping, tools/list, tools/call. Tool: sequential_thinking
(thought, nextThoughtNeeded, thoughtNumber, totalThoughts + optional
isRevision, revisesThought, branchFromThought, branchId,
needsMoreThoughts). Thought history lives in RAM for the connection
(64-slot ring).

Smoke test
----------
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sequential_thinking","arguments":{"thought":"hi","nextThoughtNeeded":false,"thoughtNumber":1,"totalThoughts":1}}}' \
  | ./tinythink
