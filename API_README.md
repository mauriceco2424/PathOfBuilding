# PoB API Fork: Headless JSON-RPC (stdio)

This fork adds a minimal stdio-based API server, gated by `POB_API_STDIO=1`.

## Quick Start (system LuaJIT)

From repo root:

```bash
cd src
POB_API_STDIO=1 luajit HeadlessWrapper.lua
```

You should see a single JSON line printed:

```json
{"ok":true,"ready":true,"version":{"number":"?","branch":"?","platform":"?"}}
```

Send commands by writing JSON lines to stdin; responses are printed to stdout.

### Actions
- `{"action":"ping"}` -> `{ ok: true, pong: true }`
- `{"action":"version"}` -> `{ ok: true, version: { number, branch, platform } }`
- `{"action":"load_build_xml","params":{"xml":"<PathOfBuilding>...</PathOfBuilding>","name":"MyBuild"}}` -> `{ ok: true, build_id: 1 }`
- `{"action":"get_stats","params":{"fields":["Life","EnergyShield","Armour"]}}` -> `{ ok: true, stats: { ... } }`
- `{"action":"quit"}` -> `{ ok: true, quit: true }` and exit

## Notes
- Requires PoB runtime libs for JSON: if `require('dkjson')` fails, the server tries `../runtime/lua/dkjson.lua`.
- This is an initial scaffold; more actions (tree edits, config, what‑if calcs) will be added.
- For robust use, spawn this process from your MCP server and communicate over stdio.
