-- API/Handlers.lua
-- Shared JSON-RPC handlers for PoB API (transport-agnostic)

-- Debug logging control
local DEBUG = os.getenv('POB_API_DEBUG') == '1'
local function debug_log(msg)
  if DEBUG then io.stderr:write('[Handlers] ' .. msg .. '\n') end
end

-- Resolve BuildOps reliably regardless of CWD
local BuildOps
do
  debug_log('Attempting to require API.BuildOps')
  local ok_ops, mod = pcall(require, 'API.BuildOps')
  debug_log('pcall require result: ok=' .. tostring(ok_ops) .. ', mod=' .. tostring(mod))
  if ok_ops and mod then
    debug_log('Successfully loaded BuildOps via require')
    BuildOps = mod
  else
    debug_log('require failed, trying dofile fallbacks')
    -- Try path relative to this file's directory
    local dir = ''
    local info = debug and debug.getinfo and debug.getinfo(1, 'S')
    local src = info and info.source or ''
    if type(src) == 'string' and src:sub(1,1) == '@' then
      local p = src:sub(2)
      dir = (p:gsub('[^/\\]+$', ''))
    end
    local tried = {}
    local function try(p)
      if p then table.insert(tried, p) end
      if not p then return false end
      debug_log('Trying to load: ' .. tostring(p))
      local ok2, m = pcall(dofile, p)
      if ok2 and m then
        debug_log('Successfully loaded BuildOps from: ' .. tostring(p))
        BuildOps = m
        return true
      end
      debug_log('Failed to load from: ' .. tostring(p) .. ' - error: ' .. tostring(m))
      return false
    end
    if not BuildOps then
      local _ = try(dir .. 'BuildOps.lua')
              or try((rawget(_G,'POB_SCRIPT_DIR') or '.') .. '/API/BuildOps.lua')
              or try('API/BuildOps.lua')
              or try('src/API/BuildOps.lua')
    end
    if not BuildOps then
      io.stderr:write('[Handlers] BuildOps.lua not found. Tried paths: ' .. table.concat(tried, ', ') .. '\n')
      error('API/BuildOps.lua not found. Tried: ' .. table.concat(tried, ', '))
    end
  end
end

-- API version (semantic versioning)
local API_VERSION = "1.0.0"

local function version_meta()
  return {
    number      = _G.launch and launch.versionNumber or '?',
    branch      = _G.launch and launch.versionBranch or '?',
    platform    = _G.launch and launch.versionPlatform or '?',
    apiVersion  = API_VERSION,
  }
end

-- Memory-aware GC: prevents LuaJIT OOM by collecting when memory exceeds threshold.
-- collectgarbage("count") is essentially free (reads an internal counter).
-- Full GC only runs when threshold is exceeded (~20-50ms, rare).
local GC_THRESHOLD_KB = 512000  -- 500MB
local function checkMemoryPressure()
  local memKB = collectgarbage("count")
  if memKB > GC_THRESHOLD_KB then
    collectgarbage("collect")
    collectgarbage("collect")
    local afterKB = collectgarbage("count")
    print(string.format("[GC] Memory pressure: %.1fMB -> %.1fMB", memKB/1024, afterKB/1024))
  end
end

local handlers = {}

handlers.ping = function(params)
  return { ok = true, pong = true }
end

handlers.version = function(params)
  return { ok = true, version = version_meta() }
end

handlers.new_build = function(params)
  if not _G.newBuild then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  _G.newBuild()
  return { ok = true }
end

handlers.load_build_xml = function(params)
  checkMemoryPressure()
  if not params or type(params.xml) ~= 'string' then
    return { ok = false, error = 'missing xml' }
  end
  local name = (params.name and tostring(params.name)) or 'API Build'
  if not _G.loadBuildFromXML then
    return { ok = false, error = 'headless wrapper not initialized' }
  end

  -- NOTE: Do NOT call newBuild() before loadBuildFromXML - it breaks the import!
  -- loadBuildFromXML already calls SetMode which clears previous state.
  _G.loadBuildFromXML(params.xml, name)

  -- Run additional OnFrame to ensure PostLoad and cluster jewel graphs are built
  if _G.runCallback then
    _G.runCallback("OnFrame")
    _G.runCallback("OnFrame")
  end

  -- CRITICAL: After SetMode, _G.build may be stale - we need to update it!
  -- SetMode creates a new build object in mainObject.main.modes["BUILD"]
  -- But _G.build was set once at startup and points to the OLD object
  if _G.mainObject and _G.mainObject.main and _G.mainObject.main.modes then
    local newBuild = _G.mainObject.main.modes["BUILD"]
    if newBuild and newBuild ~= _G.build then
      io.stderr:write("[load_build_xml] Updating _G.build to new build object\n")
      _G.build = newBuild
    end
  end

  -- Check for failure conditions
  local build = _G.build
  if not build then
    io.stderr:write("[load_build_xml] ERROR: build object is nil after load\n")
  end

  return { ok = true, build_id = 1 }
end

handlers.get_stats = function(params)
  local fields = params and params.fields or nil
  local stats, err = BuildOps.export_stats(fields)
  if not stats then
    return { ok = false, error = err }
  end
  return { ok = true, stats = stats }
end

handlers.get_full_calcs = function(params)
  checkMemoryPressure()
  local calcs, err = BuildOps.get_full_calcs()
  if not calcs then
    return { ok = false, error = err }
  end
  return { ok = true, data = calcs }
end

handlers.get_items = function(params)
  local list, err = BuildOps.get_items()
  if not list then return { ok = false, error = err } end
  return { ok = true, items = list }
end

handlers.get_attribute_requirements = function(params)
  local result, err = BuildOps.get_attribute_requirements()
  if not result then return { ok = false, error = err } end
  return { ok = true, requirements = result }
end

handlers.get_skills = function(params)
  local info, err = BuildOps.get_skills()
  if not info then return { ok = false, error = err } end
  return { ok = true, skills = info }
end

handlers.get_tree = function(params)
  local tree, err = BuildOps.get_tree()
  if not tree then
    return { ok = false, error = err }
  end
  return { ok = true, tree = tree }
end

handlers.get_cluster_nodes = function(params)
  local nodes, err = BuildOps.get_cluster_nodes()
  if not nodes then return { ok = false, error = err } end
  return { ok = true, clusterNodes = nodes }
end

handlers.set_main_selection = function(params)
  local ok2, err = BuildOps.set_main_selection(params or {})
  if not ok2 then return { ok = false, error = err } end
  local skills = BuildOps.get_skills()
  return { ok = true, skills = skills }
end

handlers.set_tree = function(params)
  checkMemoryPressure()
  local ok2, err = BuildOps.set_tree(params or {})
  if not ok2 then
    return { ok = false, error = err }
  end
  local tree = BuildOps.get_tree()
  return { ok = true, tree = tree }
end

handlers.add_item_text = function(params)
  local res, err = BuildOps.add_item_text(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, item = res }
end

handlers.add_items_batch = function(params)
  local res, err = BuildOps.add_items_batch(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, results = res.results, successCount = res.successCount }
end

handlers.export_build_xml = function(params)
  local xml, err = BuildOps.export_build_xml()
  if not xml then return { ok = false, error = err } end
  return { ok = true, xml = xml }
end

handlers.set_level = function(params)
  if not params or params.level == nil then
    return { ok = false, error = 'missing level' }
  end
  local ok2, err = BuildOps.set_level(params.level)
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.set_flask_active = function(params)
  local ok2, err = BuildOps.set_flask_active(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.get_build_info = function(params)
  local info, err = BuildOps.get_build_info()
  if not info then return { ok = false, error = err } end
  return { ok = true, info = info }
end

handlers.update_tree_delta = function(params)
  local ok2, err = BuildOps.update_tree_delta(params or {})
  if not ok2 then return { ok = false, error = err } end
  local tree = BuildOps.get_tree()
  return { ok = true, tree = tree }
end

handlers.calc_with = function(params)
  checkMemoryPressure()
  local result, err = BuildOps.calc_with(params or {})
  if not result then return { ok = false, error = err } end
  return { ok = true, output = result.output, baseOutput = result.baseOutput, diagnostics = result.diagnostics }
end

handlers.calc_with_gems = function(params)
  checkMemoryPressure()
  local result, err = BuildOps.calc_with_gems(params or {})
  if not result then return { ok = false, error = err } end
  return { ok = true, output = result.output, baseOutput = result.baseOutput }
end

handlers.calc_with_jewel = function(params)
  checkMemoryPressure()
  local result, err = BuildOps.calc_with_jewel(params or {})
  if not result then return { ok = false, error = err } end
  return {
    ok = true,
    beforeOutput = result.beforeOutput,
    afterOutput = result.afterOutput,
    allocatedNotables = result.allocatedNotables,
  }
end

handlers.calc_with_cluster_chain = function(params)
  checkMemoryPressure()
  local result, err = BuildOps.calc_with_cluster_chain(params or {})
  if not result then return { ok = false, error = err } end
  return {
    ok = true,
    beforeOutput = result.beforeOutput,
    afterOutput = result.afterOutput,
    allocatedNotables = result.allocatedNotables,
    totalPointCost = result.totalPointCost,
  }
end

handlers.get_config = function(params)
  local cfg, err = BuildOps.get_config()
  if not cfg then return { ok = false, error = err } end
  return { ok = true, config = cfg }
end

handlers.get_full_config = function(params)
  local cfg, err = BuildOps.get_full_config()
  if not cfg then return { ok = false, error = err } end
  return { ok = true, config = cfg }
end

handlers.set_config = function(params)
  local ok2, err = BuildOps.set_config(params or {})
  if not ok2 then return { ok = false, error = err } end
  local cfg = BuildOps.get_full_config()
  return { ok = true, config = cfg }
end

handlers.create_socket_group = function(params)
  local res, err = BuildOps.create_socket_group(params or {})
  if not res then return { ok = false, error = err or 'failed to create socket group' } end
  return { ok = true, socketGroup = res }
end

handlers.add_gem = function(params)
  local res, err = BuildOps.add_gem(params or {})
  if not res then return { ok = false, error = err or 'failed to add gem' } end
  return { ok = true, gem = res }
end

handlers.set_gem_level = function(params)
  local ok2, err = BuildOps.set_gem_level(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to set gem level' } end
  return { ok = true }
end

handlers.set_gem_quality = function(params)
  local ok2, err = BuildOps.set_gem_quality(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to set gem quality' } end
  return { ok = true }
end

handlers.remove_skill = function(params)
  local ok2, err = BuildOps.remove_skill(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to remove skill' } end
  return { ok = true }
end

handlers.remove_gem = function(params)
  local ok2, err = BuildOps.remove_gem(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to remove gem' } end
  return { ok = true }
end

handlers.search_nodes = function(params)
  local res, err = BuildOps.search_nodes(params or {})
  if not res then return { ok = false, error = err or 'failed to search nodes' } end
  return { ok = true, results = res }
end

handlers.find_path = function(params)
  checkMemoryPressure()
  local res, err = BuildOps.find_path(params or {})
  if not res then return { ok = false, error = err or 'failed to find path' } end
  return { ok = true, result = res }
end

handlers.generate_trade_query = function(params)
  checkMemoryPressure()
  local result, err = BuildOps.generate_trade_query(params or {})
  if not result then return { ok = false, error = err or 'failed to generate trade query' } end
  return { ok = true, query = result.query, modWeights = result.modWeights, itemCategory = result.itemCategory, itemCategoryQueryStr = result.itemCategoryQueryStr, currentStatDiff = result.currentStatDiff, minWeight = result.minWeight }
end

handlers.get_tree_stats = function(params)
  local stats, err = BuildOps.get_tree_stats()
  if not stats then return { ok = false, error = err } end
  return { ok = true, treeStats = stats }
end

handlers.set_skill_config = function(params)
  local res, err = BuildOps.set_skill_config(params or {})
  if not res then return { ok = false, error = err or 'failed to set skill config' } end
  return { ok = true, varName = res.varName, value = res.value }
end

handlers.set_batch_skill_config = function(params)
  local res, err = BuildOps.set_batch_skill_config(params or {})
  if not res then return { ok = false, error = err or 'failed to batch set skill config' } end
  return { ok = true, applied = res.applied, count = res.count }
end

handlers.load_build_json = function(params)
  if not params or type(params.itemsJson) ~= 'string' or type(params.passiveSkillsJson) ~= 'string' then
    return { ok = false, error = 'missing itemsJson or passiveSkillsJson' }
  end
  if not _G.loadBuildFromJSON then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  -- NOTE: Do NOT call newBuild() before loadBuildFromJSON - it can break the import!
  -- loadBuildFromJSON already calls SetMode which clears previous state.
  _G.loadBuildFromJSON(params.itemsJson, params.passiveSkillsJson)

  -- Mirror the XML import path: give PoB extra frames to finish PostLoad-style
  -- rebuilds (timeless jewels, cluster graphs, tree/tooltips) before any API reads.
  if _G.runCallback then
    _G.runCallback("OnFrame")
    _G.runCallback("OnFrame")
  end

  -- After SetMode, the global build pointer can still reference the previous build.
  if _G.mainObject and _G.mainObject.main and _G.mainObject.main.modes then
    local newBuild = _G.mainObject.main.modes["BUILD"]
    if newBuild and newBuild ~= _G.build then
      io.stderr:write("[load_build_json] Updating _G.build to new build object\n")
      _G.build = newBuild
    end
  end

  return { ok = true, build_id = 1 }
end

handlers.get_jewel_sockets = function(params)
  local sockets, err = BuildOps.get_jewel_sockets()
  if not sockets then return { ok = false, error = err } end
  return { ok = true, sockets = sockets }
end

handlers.set_jewel = function(params)
  local res, err = BuildOps.set_jewel(params or {})
  if not res then return { ok = false, error = err or 'failed to set jewel' } end
  return { ok = true, jewel = res }
end

handlers.remove_jewel = function(params)
  local res, err = BuildOps.remove_jewel(params or {})
  if not res then return { ok = false, error = err or 'failed to remove jewel' } end
  return { ok = true, result = res }
end

handlers.get_nodes_in_radius = function(params)
  local res, err = BuildOps.get_nodes_in_radius(params or {})
  if not res then return { ok = false, error = err or 'failed to get nodes in radius' } end
  return { ok = true, result = res }
end

handlers.get_tree_node_debug = function(params)
  local res, err = BuildOps.get_tree_node_debug(params or {})
  if not res then return { ok = false, error = err or 'failed to get tree node debug' } end
  return { ok = true, debug = res }
end

handlers.get_mastery_alternatives = function(params)
  local build = _G.build
  if not build or not build.spec then
    return { ok = false, error = 'no build loaded' }
  end

  local result = {}
  for nodeId, node in pairs(build.spec.allocNodes) do
    if node.type == "Mastery" and node.masteryEffects then
      local currentEffectId = build.spec.masterySelections and build.spec.masterySelections[nodeId] or nil
      local entry = {
        nodeId = nodeId,
        name = node.name or ("Mastery " .. nodeId),
        currentEffectId = currentEffectId,
        currentStats = {},
        alternatives = {},
      }
      -- Get current effect stats
      if currentEffectId and build.spec.tree and build.spec.tree.masteryEffects then
        local currentEffect = build.spec.tree.masteryEffects[currentEffectId]
        if currentEffect and currentEffect.sd then
          entry.currentStats = currentEffect.sd
        end
      end
      -- Get all alternative effects
      for _, effect in ipairs(node.masteryEffects) do
        if effect.effect ~= currentEffectId then
          local resolved = build.spec.tree and build.spec.tree.masteryEffects and build.spec.tree.masteryEffects[effect.effect]
          table.insert(entry.alternatives, {
            effectId = effect.effect,
            stats = resolved and resolved.sd or effect.stats or {},
          })
        end
      end
      if #entry.alternatives > 0 then
        result[tostring(nodeId)] = entry
      end
    end
  end
  return { ok = true, result = result }
end

handlers.get_flask_uptime_data = function(params)
  local data, err = BuildOps.get_flask_uptime_data()
  if not data then return { ok = false, error = err } end
  return { ok = true, flasks = data }
end

handlers.gc_collect = function(params)
  collectgarbage("collect")
  collectgarbage("collect")
  local memoryKB = collectgarbage("count")
  return { ok = true, memoryKB = memoryKB }
end

return {
  handlers = handlers,
  version_meta = version_meta,
}
