-- API/Server.lua
-- Simple stdio JSON-RPC loop exposing a tiny PoB API

-- json loader with fallback to runtime path
local ok, json = pcall(require, 'dkjson')
if not ok then
  local p = '../runtime/lua/dkjson.lua'
  local ok2, mod = pcall(dofile, p)
  if ok2 then json = mod else error('dkjson not found; ensure PoB runtime or dkjson is available') end
end

local function j_encode(tbl)
  return json.encode(tbl, { indent = false })
end
local function j_decode(txt)
  return json.decode(txt)
end

local function write_line(tbl)
  io.write(j_encode(tbl), "\n")
  io.flush()
end

local function read_line()
  return io.read("*l")
end

-- Load helpers
local BuildOps = dofile('API/BuildOps.lua')

-- Metadata
local version_meta = {
  number   = _G.launch and launch.versionNumber or '?',
  branch   = _G.launch and launch.versionBranch or '?',
  platform = _G.launch and launch.versionPlatform or '?',
}

-- Commands
local handlers = {}

handlers.ping = function(params)
  return { ok = true, pong = true }
end

handlers.version = function(params)
  return { ok = true, version = version_meta }
end

handlers.load_build_xml = function(params)
  if not params or type(params.xml) ~= 'string' then
    return { ok = false, error = 'missing xml' }
  end
  local name = (params.name and tostring(params.name)) or 'API Build'
  if not _G.loadBuildFromXML then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  _G.loadBuildFromXML(params.xml, name)
  return { ok = true, build_id = 1 }
end

handlers.get_stats = function(params)
  local fields = params and params.fields or nil
  local stats, err = BuildOps.export_stats(fields)
  if not stats then
    return { ok = false, error = err or 'failed to get stats' }
  end
  return { ok = true, stats = stats }
end

handlers.get_items = function(params)
  local list, err = BuildOps.get_items()
  if not list then return { ok = false, error = err or 'failed to get items' } end
  return { ok = true, items = list }
end


handlers.get_skills = function(params)
  local info, err = BuildOps.get_skills()
  if not info then return { ok = false, error = err or "failed to get skills" } end
  return { ok = true, skills = info }
end


handlers.get_tree = function(params)
  local tree, err = BuildOps.get_tree()
  if not tree then
    return { ok = false, error = err or 'failed to get tree' }
  end
  return { ok = true, tree = tree }
end

handlers.set_main_selection = function(params)
  local ok2, err = BuildOps.set_main_selection(params or {})
  if not ok2 then return { ok = false, error = err or "failed to set main selection" } end
  local skills = BuildOps.get_skills()
  return { ok = true, skills = skills }
end

handlers.set_tree = function(params)
  local ok2, err = BuildOps.set_tree(params or {})
  if not ok2 then
    return { ok = false, error = err or 'failed to set tree' }
  end
  local tree = BuildOps.get_tree()
  return { ok = true, tree = tree }
end


handlers.add_item_text = function(params)
  local res, err = BuildOps.add_item_text(params or {})
  if not res then return { ok = false, error = err or "failed to add item" } end
  return { ok = true, item = res }
end

handlers.export_build_xml = function(params)
  local xml, err = BuildOps.export_build_xml()
  if not xml then return { ok = false, error = err or 'failed to export xml' } end
  return { ok = true, xml = xml }
end

handlers.set_level = function(params)
  if not params or params.level == nil then
    return { ok = false, error = 'missing level' }
  end
  local ok2, err = BuildOps.set_level(params.level)
  if not ok2 then return { ok = false, error = err or 'failed to set level' } end
  return { ok = true }
end

handlers.set_flask_active = function(params)
  local ok2, err = BuildOps.set_flask_active(params or {})
  if not ok2 then return { ok = false, error = err or "failed to set flask" } end
  return { ok = true }
end

handlers.get_build_info = function(params)
  local info, err = BuildOps.get_build_info()
  if not info then return { ok = false, error = err or 'failed to get info' } end
  return { ok = true, info = info }
end

handlers.update_tree_delta = function(params)
  local ok2, err = BuildOps.update_tree_delta(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to update tree' } end
  local tree = BuildOps.get_tree()
  return { ok = true, tree = tree }
end

handlers.calc_with = function(params)
  local out, base = BuildOps.calc_with(params or {})
  if not out then return { ok = false, error = base or "failed to calc" } end
  return { ok = true, output = out }
end

handlers.get_config = function(params)
  local cfg, err = BuildOps.get_config()
  if not cfg then return { ok = false, error = err or "failed to get config" } end
  return { ok = true, config = cfg }
end

handlers.set_config = function(params)
  local ok2, err = BuildOps.set_config(params or {})
  if not ok2 then return { ok = false, error = err or "failed to set config" } end
  local cfg = BuildOps.get_config()
  return { ok = true, config = cfg }
end

handlers.quit = function(params)
  return { ok = true, quit = true }
end

-- Main loop
write_line({ ok = true, ready = true, version = version_meta })
while true do
  local line = read_line()
  if not line then break end
  if #line == 0 then goto continue end
  local msg = j_decode(line)
  if not msg or type(msg) ~= 'table' then
    write_line({ ok = false, error = 'invalid json' })
    goto continue
  end
  local action = msg.action
  local params = msg.params or {}
  local handler = handlers[action]
  if not handler then
    write_line({ ok = false, error = 'unknown action: '..tostring(action) })
    goto continue
  end
  local ok2, res = pcall(handler, params)
  if not ok2 then
    write_line({ ok = false, error = 'exception: '..tostring(res) })
  else
    write_line(res)
    if action == 'quit' then break end
  end
  ::continue::
end
