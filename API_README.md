# PoB API: Headless JSON-RPC (stdio)

This implementation adds a stdio-based JSON-RPC API server to Path of Building, enabling programmatic access to build calculations and modifications.

## Table of Contents
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Error Handling](#error-handling)
- [Environment Variables](#environment-variables)
- [Security Considerations](#security-considerations)
- [Limitations](#limitations)
- [Examples](#examples)

## Quick Start

### Running the Server

From the repository root:

```bash
cd src
POB_API_STDIO=1 luajit HeadlessWrapper.lua
```

### Initial Handshake

Upon startup, the server sends a ready message to stdout:

```json
{"ok":true,"ready":true,"version":{"number":"3.x.x","branch":"dev","platform":"linux","apiVersion":"1.0.0"}}
```

### Sending Commands

Commands are sent as single-line JSON objects to stdin. Each command must include an `action` field:

```json
{"action":"ping"}
```

Responses are returned as single-line JSON objects on stdout:

```json
{"ok":true,"pong":true}
```

## API Reference

All successful responses include `"ok": true`. Error responses include `"ok": false` and an `"error"` field with a descriptive message.

### General Commands

#### `ping`
Health check to verify the server is responsive.

**Request:**
```json
{"action":"ping"}
```

**Response:**
```json
{"ok":true,"pong":true}
```

#### `version`
Get version information about Path of Building and the API.

**Request:**
```json
{"action":"version"}
```

**Response:**
```json
{
  "ok":true,
  "version":{
    "number":"3.x.x",
    "branch":"dev",
    "platform":"linux",
    "apiVersion":"1.0.0"
  }
}
```

#### `quit`
Gracefully shut down the server.

**Request:**
```json
{"action":"quit"}
```

**Response:**
```json
{"ok":true,"quit":true}
```

### Build Management

#### `load_build_xml`
Load a Path of Building build from XML.

**Parameters:**
- `xml` (string, required): PathOfBuilding XML export
- `name` (string, optional): Build display name (default: "API Build")

**Request:**
```json
{
  "action":"load_build_xml",
  "params":{
    "xml":"<PathOfBuilding>...</PathOfBuilding>",
    "name":"My Awesome Build"
  }
}
```

**Response:**
```json
{"ok":true,"build_id":1}
```

**Errors:**
- `missing xml` - No XML provided
- `headless wrapper not initialized` - Server not ready

#### `export_build_xml`
Export the current build as XML.

**Request:**
```json
{"action":"export_build_xml"}
```

**Response:**
```json
{"ok":true,"xml":"<PathOfBuilding>...</PathOfBuilding>"}
```

**Errors:**
- `build not initialized` - No build loaded

#### `get_build_info`
Get basic information about the current build.

**Request:**
```json
{"action":"get_build_info"}
```

**Response:**
```json
{
  "ok":true,
  "info":{
    "name":"My Build",
    "level":95,
    "className":"Ranger",
    "ascendClassName":"Pathfinder",
    "treeVersion":"3_25"
  }
}
```

### Stats and Calculations

#### `get_stats`
Export calculated character stats.

**Parameters:**
- `fields` (array of strings, optional): Specific stats to return. If omitted, returns default set.

**Request:**
```json
{
  "action":"get_stats",
  "params":{
    "fields":["Life","EnergyShield","Armour","DPS"]
  }
}
```

**Response:**
```json
{
  "ok":true,
  "stats":{
    "Life":5243,
    "EnergyShield":0,
    "Armour":12453,
    "_meta":{
      "treeVersion":"3_25",
      "level":95,
      "buildName":"My Build"
    }
  }
}
```

**Default Fields:**
Life, EnergyShield, Armour, Evasion, FireResist, ColdResist, LightningResist, ChaosResist, BlockChance, SpellBlockChance, LifeRegen, Mana, ManaRegen, Ward, DodgeChance, SpellDodgeChance

#### `calc_with`
Calculate what-if scenario without persisting changes.

**Parameters:**
- `addNodes` (array of numbers, optional): Node IDs to temporarily allocate
- `removeNodes` (array of numbers, optional): Node IDs to temporarily deallocate
- `useFullDPS` (boolean, optional): Use full DPS calculation

**Request:**
```json
{
  "action":"calc_with",
  "params":{
    "addNodes":[12345,12346],
    "removeNodes":[54321]
  }
}
```

**Response:**
```json
{
  "ok":true,
  "output":{
    "Life":5500,
    "DPS":1234567
  }
}
```

### Passive Tree

#### `get_tree`
Get current passive tree allocation.

**Request:**
```json
{"action":"get_tree"}
```

**Response:**
```json
{
  "ok":true,
  "tree":{
    "treeVersion":"3_25",
    "classId":2,
    "ascendClassId":1,
    "secondaryAscendClassId":0,
    "nodes":[123,456,789],
    "masteryEffects":{"1234":5678}
  }
}
```

#### `set_tree`
Replace the entire passive tree allocation.

**Parameters:**
- `classId` (number, required): Character class ID
- `ascendClassId` (number, required): Ascendancy class ID
- `secondaryAscendClassId` (number, optional): Secondary ascendancy (for Scion)
- `nodes` (array of numbers, required): Allocated node IDs
- `masteryEffects` (object, optional): Mastery selections `{masteryId: effectId}`
- `treeVersion` (string, optional): Tree version identifier

**Request:**
```json
{
  "action":"set_tree",
  "params":{
    "classId":2,
    "ascendClassId":1,
    "nodes":[123,456,789],
    "masteryEffects":{"1234":5678}
  }
}
```

**Response:**
```json
{
  "ok":true,
  "tree":{...}
}
```

#### `update_tree_delta`
Modify tree by adding/removing specific nodes.

**Parameters:**
- `addNodes` (array of numbers, optional): Node IDs to allocate
- `removeNodes` (array of numbers, optional): Node IDs to deallocate
- `classId` (number, optional): Update character class
- `ascendClassId` (number, optional): Update ascendancy class

**Request:**
```json
{
  "action":"update_tree_delta",
  "params":{
    "addNodes":[999,1000],
    "removeNodes":[123]
  }
}
```

**Response:**
```json
{
  "ok":true,
  "tree":{...}
}
```

### Character Configuration

#### `set_level`
Set character level.

**Parameters:**
- `level` (number, required): Level between 1 and 100

**Request:**
```json
{
  "action":"set_level",
  "params":{"level":95}
}
```

**Response:**
```json
{"ok":true}
```

**Errors:**
- `missing level` - No level parameter provided
- `invalid level (must be 1-100)` - Level out of range

#### `get_config`
Get current build configuration.

**Request:**
```json
{"action":"get_config"}
```

**Response:**
```json
{
  "ok":true,
  "config":{
    "bandit":"None",
    "pantheonMajorGod":"Lunaris",
    "pantheonMinorGod":"Garukhan",
    "enemyLevel":83
  }
}
```

#### `set_config`
Update build configuration.

**Parameters:**
- `bandit` (string, optional): "None", "Oak", "Kraityn", or "Alira"
- `pantheonMajorGod` (string, optional): Major pantheon god name
- `pantheonMinorGod` (string, optional): Minor pantheon god name
- `enemyLevel` (number, optional): Enemy level for calculations

**Request:**
```json
{
  "action":"set_config",
  "params":{
    "bandit":"Oak",
    "enemyLevel":85
  }
}
```

**Response:**
```json
{
  "ok":true,
  "config":{...}
}
```

### Items

#### `get_items`
Get all equipped items.

**Request:**
```json
{"action":"get_items"}
```

**Response:**
```json
{
  "ok":true,
  "items":[
    {
      "slot":"Weapon 1",
      "id":123,
      "name":"Paradoxica",
      "baseName":"Rapier",
      "type":"One Handed Melee Weapon",
      "rarity":"UNIQUE",
      "raw":"..."
    }
  ]
}
```

#### `add_item_text`
Add an item from text (PoB import format).

**Parameters:**
- `text` (string, required): Item text in PoB format (max 10KB)
- `slotName` (string, optional): Slot to equip item in
- `noAutoEquip` (boolean, optional): Don't auto-equip the item

**Request:**
```json
{
  "action":"add_item_text",
  "params":{
    "text":"Rarity: UNIQUE\nParadoxica\n...",
    "slotName":"Weapon 1"
  }
}
```

**Response:**
```json
{
  "ok":true,
  "item":{
    "id":456,
    "name":"Paradoxica",
    "slot":"Weapon 1"
  }
}
```

**Errors:**
- `item text cannot be empty` - Empty text provided
- `item text too long (max 10240 bytes)` - Text exceeds size limit
- `invalid item text: ...` - Item parsing failed

#### `set_flask_active`
Set flask activation state.

**Parameters:**
- `index` (number, required): Flask slot 1-5
- `active` (boolean, required): Activation state

**Request:**
```json
{
  "action":"set_flask_active",
  "params":{
    "index":1,
    "active":true
  }
}
```

**Response:**
```json
{"ok":true}
```

**Errors:**
- `invalid flask index (must be 1-5)` - Index out of range

### Skills

#### `get_skills`
Get skill socket groups and active skill information.

**Request:**
```json
{"action":"get_skills"}
```

**Response:**
```json
{
  "ok":true,
  "skills":{
    "mainSocketGroup":1,
    "calcsSkillNumber":1,
    "groups":[
      {
        "index":1,
        "label":"Main 6L",
        "slot":"Weapon 1",
        "enabled":true,
        "includeInFullDPS":true,
        "mainActiveSkill":1,
        "skills":["Blade Vortex","Unleash Support","...]
      }
    ]
  }
}
```

#### `set_main_selection`
Set the main active skill selection.

**Parameters:**
- `mainSocketGroup` (number, optional): Socket group index
- `mainActiveSkill` (number, optional): Active skill index within group
- `skillPart` (number, optional): Skill part/mode selection

**Request:**
```json
{
  "action":"set_main_selection",
  "params":{
    "mainSocketGroup":1,
    "mainActiveSkill":1
  }
}
```

**Response:**
```json
{
  "ok":true,
  "skills":{...}
}
```

## Error Handling

All errors follow a consistent format:

```json
{
  "ok":false,
  "error":"descriptive error message"
}
```

Common error patterns:
- `build not initialized` - No build loaded, use `load_build_xml` first
- `missing <parameter>` - Required parameter not provided
- `invalid <parameter>` - Parameter validation failed

The API uses Lua's tuple return pattern `(result, error)` internally. When an operation fails, `result` is `nil` and `error` contains the message.

## Environment Variables

### `POB_API_STDIO`
**Required.** Set to `1` to enable the stdio API server.

```bash
POB_API_STDIO=1 luajit HeadlessWrapper.lua
```

### `POB_API_DEBUG`
**Optional.** Set to `1` to enable verbose debug logging to stderr.

```bash
POB_API_DEBUG=1 POB_API_STDIO=1 luajit HeadlessWrapper.lua
```

Debug logs include:
- Module loading paths and attempts
- Handler initialization steps
- Internal state changes

## Security Considerations

**This API is designed for trusted local use only.**

### Security Limitations:
- **No authentication or authorization** - Anyone with access to the process can execute commands
- **Code execution via imports** - Loading builds/items can execute Lua code
- **Single shared build state** - Not isolated between requests
- **Input validation is basic** - Size limits but minimal sanitization

### Safe Usage Guidelines:
1. **Only process trusted builds** - Don't load XML from untrusted sources
2. **Run in sandboxed environment** - Use containers/VMs if processing user content
3. **Don't expose over network** - stdio is designed for local IPC only
4. **Validate all inputs** - Add application-level validation on top of API

**DO NOT** expose this server to:
- Untrusted networks
- Public internet
- Untrusted clients or data sources

## Limitations

### Single Build Context
All operations work on one global build state. Loading a new build replaces the current one.

### Synchronous Operations
All calculations are synchronous and block the event loop. Large builds may take 100-500ms per calculation.

### No Transactions
Changes are applied immediately with no rollback capability. Use `calc_with` for non-destructive what-if analysis.

### Stdio Protocol
- Line-based: Each request/response must be a single line
- Sequential: Requests are processed in order
- No multiplexing: One request at a time

## Examples

### Complete Workflow: Load, Modify, Export

```bash
# Start server
POB_API_STDIO=1 luajit src/HeadlessWrapper.lua

# 1. Load a build
{"action":"load_build_xml","params":{"xml":"<PathOfBuilding>...</PathOfBuilding>"}}

# 2. Get initial stats
{"action":"get_stats"}

# 3. Set level to 95
{"action":"set_level","params":{"level":95}}

# 4. Modify passive tree
{"action":"update_tree_delta","params":{"addNodes":[12345,12346]}}

# 5. Get updated stats
{"action":"get_stats"}

# 6. Export modified build
{"action":"export_build_xml"}

# 7. Exit
{"action":"quit"}
```

### What-If Analysis

```json
// Get baseline stats
{"action":"get_stats"}

// Test adding nodes without committing
{"action":"calc_with","params":{"addNodes":[12345,12346,12347]}}

// Tree is unchanged - repeat with different nodes
{"action":"calc_with","params":{"addNodes":[99999,99998]}}

// Commit the better option
{"action":"update_tree_delta","params":{"addNodes":[12345,12346,12347]}}
```

### Flask Management

```json
// See what flasks are equipped
{"action":"get_items"}

// Activate diamond flask (slot 1)
{"action":"set_flask_active","params":{"index":1,"active":true}}

// Check updated stats with flask
{"action":"get_stats","params":{"fields":["CritChance","CritMultiplier"]}}

// Deactivate flask
{"action":"set_flask_active","params":{"index":1,"active":false}}
```

## API Version History

### v1.0.0 (Initial Release)
- Basic build operations (load, export, get info)
- Stats export with field selection
- Passive tree manipulation (get, set, delta updates)
- Character configuration (level, bandit, pantheon)
- Item management (get, add, flask activation)
- Skill selection
- What-if calculations
- Stdio transport with line-based JSON-RPC

## Support

For issues specific to this API implementation, please open an issue on the fork repository. For general Path of Building questions, refer to the main PoB project.
