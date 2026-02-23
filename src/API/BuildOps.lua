-- API/BuildOps.lua
-- Thin wrappers around PoB headless objects for programmatic operations

local M = {}

local t_insert = table.insert

-- Constants
local MIN_PLAYER_LEVEL = 1
local MAX_PLAYER_LEVEL = 100
local NUM_FLASK_SLOTS = 5
local MAX_ITEM_TEXT_LENGTH = 10240  -- 10KB

-- Ensure outputs are (re)built and return the main output table safely
function M.get_main_output()
  if not build or not build.calcsTab then
    return nil, "build not initialized"
  end
  if build.calcsTab.BuildOutput then
    build.calcsTab:BuildOutput()
  end
  local output = build.calcsTab and build.calcsTab.mainOutput or nil
  if not output then
    return nil, "no output available"
  end
  return output
end

-- Export a subset of useful stats from main output
-- If fields is provided, only export those keys (when present)
function M.export_stats(fields)
  local output, err = M.get_main_output()
  if not output then
    return nil, err
  end
  local wanted = fields or {
    "Life", "EnergyShield", "Armour", "Evasion",
    "FireResist", "ColdResist", "LightningResist", "ChaosResist",
    "BlockChance", "SpellBlockChance",
    "LifeRegen", "Mana", "ManaRegen",
    "Ward", "DodgeChance", "SpellDodgeChance",
  }
  local result = {}
  for _, k in ipairs(wanted) do
    if type(output[k]) ~= 'nil' then
      result[k] = output[k]
    end
  end
  -- include some metadata if available
  result._meta = result._meta or {}
  if build and build.targetVersion then
    result._meta.treeVersion = tostring(build.targetVersion)
  end
  if build and build.characterLevel then
    result._meta.level = tonumber(build.characterLevel)
  end
  if build and build.buildName then
    result._meta.buildName = tostring(build.buildName)
  end
  return result
end

-- Helper function to safely copy a table, stripping functions/userdata/metatables
-- and handling table keys (which JSON cannot serialize)
local function deepCopySafe(tbl, seen)
  if type(tbl) ~= 'table' then
    return tbl
  end
  seen = seen or {}
  if seen[tbl] then
    return nil  -- Avoid reference cycles
  end
  seen[tbl] = true

  local out = {}
  for k, v in pairs(tbl) do
    -- Skip keys that are not JSON-serializable (strings, numbers, booleans)
    local ktype = type(k)
    if ktype ~= 'string' and ktype ~= 'number' and ktype ~= 'boolean' then
      -- Skip table/function/userdata keys
      goto continue
    end

    local vtype = type(v)
    if vtype == 'table' then
      local copied = deepCopySafe(v, seen)
      if copied ~= nil then
        out[k] = copied
      end
    elseif vtype ~= 'function' and vtype ~= 'userdata' and vtype ~= 'thread' then
      out[k] = v
    end

    ::continue::
  end
  return out
end

-- Export full calculation snapshot (all PoB calculation outputs)
-- This provides access to all internal PoB calculations including EHP, per-skill DPS, etc.
function M.get_full_calcs()
  if not build or not build.calcsTab then
    return nil, 'build not initialized'
  end

  -- Ensure calculations are up to date
  if build.calcsTab.BuildOutput then
    build.calcsTab:BuildOutput()
  end

  local calcsTab = build.calcsTab
  if not calcsTab then
    return nil, 'calcsTab not available'
  end

  -- Extract all calculation outputs
  local mainOutput = calcsTab.mainOutput or {}
  local output = calcsTab.output or {}

  -- Inject CurseList/BuffList into mainOutput (normally only built in CALCS mode)
  -- env.curseSlots and env.debuffs ARE populated in MAIN mode by CalcPerform.lua
  local mainEnv = calcsTab.mainEnv
  if mainEnv and not mainOutput.CurseList then
    -- CurseList: debuffs + curse slots
    local curseNames = {}
    if mainEnv.debuffs then
      for name, _ in pairs(mainEnv.debuffs) do
        t_insert(curseNames, name)
      end
    end
    if mainEnv.curseSlots then
      for _, slot in ipairs(mainEnv.curseSlots) do
        if slot.name then
          t_insert(curseNames, slot.name)
        end
      end
    end
    table.sort(curseNames)
    mainOutput.CurseList = table.concat(curseNames, ", ")
  end

  if mainEnv and mainEnv.buffs and not mainOutput.BuffList then
    local buffNames = {}
    for name, _ in pairs(mainEnv.buffs) do
      t_insert(buffNames, name)
    end
    table.sort(buffNames)
    mainOutput.BuffList = table.concat(buffNames, ", ")
  end

  local skillOutput = calcsTab.skillOutput or {}
  local mainOutputCopy = deepCopySafe(mainOutput)
  local breakdown = calcsTab.breakdown or {}

  -- Extract config and skills context
  local configTab = build.configTab
  local skillsTab = build.skillsTab

  local configInput = configTab and configTab.input or {}
  local socketGroups = skillsTab and skillsTab.socketGroupList or {}

  -- Identify active skill
  local activeSkillName = nil
  if build.activeSkill and build.activeSkill.activeEffect and build.activeSkill.activeEffect.grantedEffect then
    activeSkillName = build.activeSkill.activeEffect.grantedEffect.name
  end

  -- Deep copy all outputs to JSON-serializable format
  local result = {
    mainOutput = deepCopySafe(mainOutput),
    output = deepCopySafe(output),
    skillOutput = deepCopySafe(skillOutput),
    breakdown = deepCopySafe(breakdown),
    config = deepCopySafe(configInput),
    skills = M.get_skills(),
    activeSkill = activeSkillName,
  }

  return result
end

-- Read current tree allocation and metadata
function M.get_tree()
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  local spec = build.spec
  local out = {
    treeVersion = spec.treeVersion,
    classId = tonumber(spec.curClassId) or 0,
    ascendClassId = tonumber(spec.curAscendClassId) or 0,
    secondaryAscendClassId = tonumber(spec.curSecondaryAscendClassId or 0) or 0,
    nodes = {},
    masteryEffects = {},
  }
  for id, _ in pairs(spec.allocNodes or {}) do
    table.insert(out.nodes, id)
  end
  for mastery, effect in pairs(spec.masterySelections or {}) do
    out.masteryEffects[mastery] = effect
  end
  table.sort(out.nodes)

  -- Point budget data: use PoB's built-in CountAllocNodes for accurate counts
  if spec.CountAllocNodes then
    local used, ascUsed, secondaryAscUsed, sockets = spec:CountAllocNodes()
    out.passivePointsUsed = used
    out.ascendancyPointsUsed = ascUsed
    out.secondaryAscendancyPointsUsed = secondaryAscUsed
  else
    -- Fallback: manually count by iterating allocNodes
    local used, ascUsed = 0, 0
    for _, node in pairs(spec.allocNodes or {}) do
      if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
        if node.ascendancyName then
          ascUsed = ascUsed + 1
        else
          used = used + 1
        end
      end
    end
    out.passivePointsUsed = used
    out.ascendancyPointsUsed = ascUsed
  end

  -- Total available passive points from PoB's own calculation
  -- ExtraPoints includes bandit bonus (+1 for killing all bandits) and item grants
  local extra = 0
  if build.calcsTab and build.calcsTab.mainOutput then
    extra = build.calcsTab.mainOutput.ExtraPoints or 0
  end
  -- Quest points from the acts table (23 at endgame)
  -- PoB's formula: usedMax = 99 + 23 + extra (for level 100)
  -- For current level: (level - 1) + questPointsForAct + extraIfPastAct2
  local charLevel = build.characterLevel or 1
  -- Use the acts table to find quest points for current progress
  local acts = {
    { level = 1, questPoints = 0 },
    { level = 12, questPoints = 2 },
    { level = 22, questPoints = 4 },
    { level = 32, questPoints = 6 },
    { level = 40, questPoints = 7 },
    { level = 44, questPoints = 9 },
    { level = 50, questPoints = 12 },
    { level = 54, questPoints = 15 },
    { level = 60, questPoints = 18 },
    { level = 64, questPoints = 20 },
    { level = 67, questPoints = 23 },
  }
  local questPoints = 0
  local pastAct2 = false
  for i = #acts, 1, -1 do
    if charLevel >= acts[i].level then
      questPoints = acts[i].questPoints
      pastAct2 = i > 2
      break
    end
  end
  local actExtra = pastAct2 and extra or 0
  out.totalPassivePoints = (charLevel - 1) + questPoints + actExtra

  return out
end

-- Get all cluster jewel nodes with their positions
-- Cluster nodes have IDs >= 0x10000 (65536)
-- Each node includes socketNodeId for frontend grouping
function M.get_cluster_nodes()
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end

  local spec = build.spec

  -- Debug: Check what jewels are equipped in sockets
  local jewelCount = 0
  local clusterJewelCount = 0
  if spec.jewels then
    for nodeId, itemId in pairs(spec.jewels) do
      jewelCount = jewelCount + 1
      local item = build.itemsTab.items[itemId]
      if item and item.clusterJewel then
        clusterJewelCount = clusterJewelCount + 1
        io.stderr:write(string.format("[get_cluster_nodes] Cluster jewel at socket %d: %s (size=%s)\n",
          nodeId, item.name or "?", item.clusterJewel.size or "?"))
      end
    end
  end

  -- Debug: Also check itemsTab for any cluster jewels (regardless of socket assignment)
  local itemsClusterCount = 0
  if build.itemsTab and build.itemsTab.items then
    for id, item in pairs(build.itemsTab.items) do
      if item.clusterJewel then
        itemsClusterCount = itemsClusterCount + 1
        io.stderr:write(string.format("[get_cluster_nodes] ItemsTab cluster jewel id=%d: %s\n", id, item.name or "?"))
      end
    end
  end

  -- Count subGraphs (it's a table, not array, so use pairs)
  local subGraphCount = 0
  if spec.subGraphs then
    for _ in pairs(spec.subGraphs) do subGraphCount = subGraphCount + 1 end
  end
  io.stderr:write(string.format("[get_cluster_nodes] spec.jewels=%d, clusters=%d, itemsTab.clusters=%d, subGraphs=%d\n",
    jewelCount, clusterJewelCount, itemsClusterCount, subGraphCount))

  -- Ensure cluster jewel graphs are built (they may not be if build was just loaded)
  if spec.BuildClusterJewelGraphs then
    spec:BuildClusterJewelGraphs()
    subGraphCount = 0
    if spec.subGraphs then
      for _ in pairs(spec.subGraphs) do subGraphCount = subGraphCount + 1 end
    end
    io.stderr:write(string.format("[get_cluster_nodes] After BuildClusterJewelGraphs: subGraphs=%d\n", subGraphCount))
  end

  local clusterNodes = {}

  -- Build lookup: node ID -> socket node ID (from subGraphs)
  -- subGraphs is keyed by the socket node ID that the cluster is attached to
  local nodeToSocket = {}
  if spec.subGraphs then
    for socketNodeId, subGraph in pairs(spec.subGraphs) do
      if subGraph.nodes then
        for _, node in ipairs(subGraph.nodes) do
          nodeToSocket[node.id] = socketNodeId
        end
      end
    end
  end

  -- Collect allocated cluster nodes
  for nodeId, node in pairs(spec.allocNodes) do
    if nodeId >= 0x10000 then
      -- This is a cluster node
      table.insert(clusterNodes, {
        id = nodeId,
        name = node.dn or "Unknown",
        type = node.type or "Normal",  -- Normal, Notable, Socket, Keystone, Mastery
        stats = node.sd or {},
        icon = node.icon,
        x = node.x,  -- Position calculated by tree:ProcessNode()
        y = node.y,
        orbit = node.o,
        orbitIndex = node.oidx,
        isAllocated = true,
        socketNodeId = nodeToSocket[nodeId],  -- Which tree socket this cluster is attached to
      })
    end
  end

  -- Also get unallocated cluster nodes from subgraphs (for complete visualization)
  if spec.subGraphs then
    for socketNodeId, subGraph in pairs(spec.subGraphs) do
      if subGraph.nodes then
        for _, node in ipairs(subGraph.nodes) do
          -- Only add if not already in allocated nodes
          if not spec.allocNodes[node.id] then
            table.insert(clusterNodes, {
              id = node.id,
              name = node.dn or "Unknown",
              type = node.type or "Normal",
              stats = node.sd or {},
              icon = node.icon,
              x = node.x,
              y = node.y,
              orbit = node.o,
              orbitIndex = node.oidx,
              isAllocated = false,
              socketNodeId = socketNodeId,  -- Use the subGraph key directly
            })
          end
        end
      end
    end
  end

  return clusterNodes
end

-- Set tree allocation from parameters
-- params: { classId, ascendClassId, secondaryAscendClassId?, nodes:[int], masteryEffects?:{[id]=effect}, treeVersion? }
-- NOTE: If classId/ascendClassId not provided, preserves current class (doesn't reset to Scion)
function M.set_tree(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end
  -- Preserve current class if not explicitly provided (don't reset to Scion/0)
  local spec = build.spec
  local classId = params.classId ~= nil and tonumber(params.classId) or spec.curClassId or 0
  local ascendId = params.ascendClassId ~= nil and tonumber(params.ascendClassId) or spec.curAscendClassId or 0
  local secondaryId = params.secondaryAscendClassId ~= nil and tonumber(params.secondaryAscendClassId) or spec.curSecondaryAscendClassId or 0
  local nodes = {}
  if type(params.nodes) == 'table' then
    for _, v in ipairs(params.nodes) do
      table.insert(nodes, tonumber(v))
    end
  end
  local mastery = params.masteryEffects or {}
  local treeVersion = params.treeVersion
  -- Import (resets nodes internally and rebuilds)
  build.spec:ImportFromNodeList(classId, ascendId, secondaryId, nodes, {}, mastery, treeVersion)
  -- Rebuild calcs to reflect changes
  M.get_main_output()
  return true
end

-- Export full build XML
function M.export_build_xml()
  if not build or not build.SaveDB then
    return nil, 'build not initialized'
  end
  local xml = build:SaveDB('api-export')
  if not xml then return nil, 'failed to compose xml' end
  return xml
end

-- Set player level and rebuild
function M.set_level(level)
  if not build or not build.configTab then
    return nil, 'build/config not initialized'
  end
  local lvl = tonumber(level)
  if not lvl or lvl < MIN_PLAYER_LEVEL or lvl > MAX_PLAYER_LEVEL then
    return nil, string.format('invalid level (must be %d-%d)', MIN_PLAYER_LEVEL, MAX_PLAYER_LEVEL)
  end
  build.characterLevel = lvl
  build.characterLevelAutoMode = false
  if build.configTab and build.configTab.BuildModList then
    build.configTab:BuildModList()
  end
  M.get_main_output()
  return true
end

-- Basic build info
function M.get_build_info()
  if not build then return nil, 'build not initialized' end
  local info = {
    name = build.buildName,
    level = build.characterLevel,
    -- Get class names from spec (where they're actually stored after build load)
    className = build.spec and build.spec.curClassName or nil,
    ascendClassName = build.spec and build.spec.curAscendClassName or nil,
    classId = build.spec and build.spec.curClassId or nil,
    ascendClassId = build.spec and build.spec.curAscendClassId or nil,
    treeVersion = build.targetVersion or (build.spec and build.spec.treeVersion) or nil,
  }
  return info
end

-- Update tree by delta lists
function M.update_tree_delta(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  local current, err = M.get_tree()
  if not current then return nil, err end
  local set = {}
  for _, id in ipairs(current.nodes) do set[id] = true end
  if params and type(params.removeNodes) == 'table' then
    for _, id in ipairs(params.removeNodes) do set[tonumber(id)] = nil end
  end
  if params and type(params.addNodes) == 'table' then
    for _, id in ipairs(params.addNodes) do set[tonumber(id)] = true end
  end
  local nodes = {}
  for id,_ in pairs(set) do table.insert(nodes, id) end
  table.sort(nodes)
  local mastery = current.masteryEffects or {}
  local classId = params.classId or current.classId or 0
  local ascendId = params.ascendClassId or current.ascendClassId or 0
  local secId = params.secondaryAscendClassId or current.secondaryAscendClassId or 0
  local tv = params.treeVersion or current.treeVersion
  build.spec:ImportFromNodeList(tonumber(classId) or 0, tonumber(ascendId) or 0, tonumber(secId) or 0, nodes, {}, mastery, tv)
  M.get_main_output()
  return true
end


-- Calculate what-if scenario without persisting changes
-- params: { addNodes?: number[], removeNodes?: number[], masteryOverrides?: { [nodeId]: effectId }, conditions?: string[], useFullDPS?: boolean }
-- Returns: { output = {...}, baseOutput = {...} } or nil, error
function M.calc_with(params)
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()
  local override = {}
  if params and type(params.addNodes) == 'table' then
    override.addNodes = {}
    for _, id in ipairs(params.addNodes) do
      local n = build.spec and build.spec.nodes and build.spec.nodes[tonumber(id)]
      if n then override.addNodes[n] = true end
    end
  end
  if params and type(params.removeNodes) == 'table' then
    override.removeNodes = {}
    for _, id in ipairs(params.removeNodes) do
      local n = build.spec and build.spec.nodes and build.spec.nodes[tonumber(id)]
      if n then override.removeNodes[n] = true end
    end
  end
  if params and type(params.masteryOverrides) == 'table' then
    override.masteryOverrides = {}
    for nodeIdStr, effectId in pairs(params.masteryOverrides) do
      local nid = tonumber(nodeIdStr)
      local eid = tonumber(effectId)
      if nid and eid then
        override.masteryOverrides[nid] = eid
      end
    end
  end
  if params and type(params.conditions) == 'table' then
    override.conditions = params.conditions
  end
  local out = calcFunc(override, params and params.useFullDPS)
  -- Use deepCopySafe to strip circular references and non-serializable values
  return {
    output = deepCopySafe(out),
    baseOutput = deepCopySafe(baseOut),
  }
end


-- Calculate what-if scenario with gem changes without persisting
-- params: {
--   addGems?: { groupIndex: number, gem: { skillId: string, level?: number, quality?: number, qualityId?: string } }[],
--   removeGems?: { groupIndex: number, gemIndex: number }[],
--   replaceGems?: { groupIndex: number, gemIndex: number, gem: { skillId: string, level?: number, quality?: number, qualityId?: string } }[],
--   conditions?: string[],
--   useFullDPS?: boolean
-- }
-- Returns: { output = {...}, baseOutput = {...} } or nil, error
function M.calc_with_gems(params)
  if not build or not build.skillsTab then return nil, 'build not initialized' end

  -- Get the active skill set's socketGroupList (not the top-level reference which may be stale)
  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end
  local socketGroupList = skillSet.socketGroupList

  -- 1. Save original gem state (only the fields we modify, preserving references)
  -- NOTE: We do NOT use deepCopySafe because it strips gemData (userdata) which is critical.
  -- Instead, we save minimal state and restore it directly.
  local originalState = {}
  for groupIdx, group in ipairs(socketGroupList) do
    if group.gemList then
      originalState[groupIdx] = { _originalLength = #group.gemList }
      for gemIdx, gem in ipairs(group.gemList) do
        originalState[groupIdx][gemIdx] = {
          nameSpec = gem.nameSpec,
          gemId = gem.gemId,
          skillId = gem.skillId,
          gemData = gem.gemData,  -- Keep reference, don't copy
          level = gem.level,
          quality = gem.quality,
          qualityId = gem.qualityId,
          enabled = gem.enabled,
          enableGlobal1 = gem.enableGlobal1,
          enableGlobal2 = gem.enableGlobal2,
          count = gem.count,
        }
      end
    end
  end

  -- 2. Apply gem modifications to LIVE state
  local modified = false

  -- Handle removeGems (do first to handle indices correctly)
  -- NOTE: Removals are NOT supported in what-if mode as they would break restoration.
  -- For now, skip removals and log a warning.
  if params and type(params.removeGems) == 'table' and #params.removeGems > 0 then
    -- Removals complicate restoration - skip for now
    -- TODO: Implement if needed
  end

  -- Helper to find gem data by name OR skillId
  -- Supports:
  --   - Display name: "Burning Damage Support"
  --   - nameSpec: "Burning Damage Support"
  --   - skillId/grantedEffect.id: "SupportBurningDamage"
  --   - gemId: unique gem identifier
  local function findGemByNameOrId(identifier)
    if not build.data or not build.data.gems then return nil end
    if not identifier then return nil end

    local searchTerm = tostring(identifier)

    for _, gemData in pairs(build.data.gems) do
      -- Try name match first (display name)
      if gemData.name == searchTerm or gemData.nameSpec == searchTerm then
        return gemData
      end
      -- Try skillId match (grantedEffect.id like "SupportBurningDamage")
      if gemData.grantedEffect and gemData.grantedEffect.id == searchTerm then
        return gemData
      end
      -- Try grantedEffectId (fallback for some gem types)
      if gemData.grantedEffectId == searchTerm then
        return gemData
      end
      -- Try gemId match
      if gemData.id == searchTerm then
        return gemData
      end
    end
    return nil
  end

  -- Handle replaceGems
  if params and type(params.replaceGems) == 'table' then
    for _, replace in ipairs(params.replaceGems) do
      local group = socketGroupList[replace.groupIndex]
      if not group then
        ConPrintf("[calc_with_gems] WARNING: groupIndex %s not found (socketGroupList has %d groups)", tostring(replace.groupIndex), #socketGroupList)
      elseif not group.gemList then
        ConPrintf("[calc_with_gems] WARNING: group %d has no gemList", replace.groupIndex)
      elseif not group.gemList[replace.gemIndex] then
        ConPrintf("[calc_with_gems] WARNING: gemIndex %s not found in group %d (gemList has %d gems)", tostring(replace.gemIndex), replace.groupIndex, #group.gemList)
      elseif not replace.gem then
        ConPrintf("[calc_with_gems] WARNING: replace entry has no gem spec")
      else
        local gemData = findGemByNameOrId(replace.gem.skillId)
        if gemData then
          local gemInstance = group.gemList[replace.gemIndex]
          gemInstance.nameSpec = gemData.name
          gemInstance.gemId = gemData.id
          gemInstance.skillId = gemData.grantedEffect and gemData.grantedEffect.id or gemData.grantedEffectId
          gemInstance.gemData = gemData
          gemInstance.level = replace.gem.level or gemData.naturalMaxLevel or 20
          gemInstance.quality = replace.gem.quality or 0
          gemInstance.qualityId = replace.gem.qualityId or "Default"
          modified = true
        else
          ConPrintf("[calc_with_gems] WARNING: gem '%s' not found in gem database", tostring(replace.gem.skillId))
        end
      end
    end
  end

  -- Handle addGems
  if params and type(params.addGems) == 'table' then
    for _, addition in ipairs(params.addGems) do
      local group = socketGroupList[addition.groupIndex]
      if group and addition.gem then
        local gemData = findGemByNameOrId(addition.gem.skillId)
        if gemData then
          if not group.gemList then group.gemList = {} end
          table.insert(group.gemList, {
            nameSpec = gemData.name,
            gemId = gemData.id,
            skillId = gemData.grantedEffect and gemData.grantedEffect.id or gemData.grantedEffectId,
            gemData = gemData,
            level = addition.gem.level or gemData.naturalMaxLevel or 20,
            quality = addition.gem.quality or 0,
            qualityId = addition.gem.qualityId or "Default",
            enabled = true,
            enableGlobal1 = true,
            enableGlobal2 = true,
            count = 1,
          })
          modified = true
        end
      end
    end
  end

  -- 3. Capture baseline output BEFORE applying modifications
  -- GetMiscCalculator creates a snapshot from current (unmodified) build state
  local baseCalcFunc, baseOut = build.calcsTab:GetMiscCalculator()
  local condOverride = {}
  if params and type(params.conditions) == 'table' then
    condOverride.conditions = params.conditions
  end
  baseOut = baseCalcFunc(condOverride, params and params.useFullDPS)

  -- 4. Reprocess socket groups if modified and get new output
  local out
  if modified then
    for _, group in ipairs(socketGroupList) do
      if build.skillsTab.ProcessSocketGroup then
        build.skillsTab:ProcessSocketGroup(group)
      end
    end
    -- Rebuild the calculator from modified gem state
    build.calcsTab:BuildOutput()
    local modCalcFunc, modBaseOut = build.calcsTab:GetMiscCalculator()
    out = modCalcFunc(condOverride, params and params.useFullDPS)  -- Must call calcFunc to get useFullDPS output
  else
    -- No modifications - both base and output are the same
    out = baseOut
  end

  -- 5. Restore original gem state
  for groupIdx, groupState in pairs(originalState) do
    local group = socketGroupList[groupIdx]
    if group and group.gemList then
      for gemIdx, gemState in pairs(groupState) do
        local gem = group.gemList[gemIdx]
        if gem then
          -- Restore all saved fields
          gem.nameSpec = gemState.nameSpec
          gem.gemId = gemState.gemId
          gem.skillId = gemState.skillId
          gem.gemData = gemState.gemData
          gem.level = gemState.level
          gem.quality = gemState.quality
          gem.qualityId = gemState.qualityId
          gem.enabled = gemState.enabled
          gem.enableGlobal1 = gemState.enableGlobal1
          gem.enableGlobal2 = gemState.enableGlobal2
          gem.count = gemState.count
        end
      end
    end
  end

  -- 5b. Remove any gems that were added (truncate to original length)
  for groupIdx, groupState in pairs(originalState) do
    local group = socketGroupList[groupIdx]
    if group and group.gemList then
      local originalLen = groupState._originalLength
      if originalLen then
        while #group.gemList > originalLen do
          table.remove(group.gemList)
        end
      end
    end
  end

  -- 6. Reprocess to restore original state
  if modified then
    for _, group in ipairs(socketGroupList) do
      if build.skillsTab.ProcessSocketGroup then
        build.skillsTab:ProcessSocketGroup(group)
      end
    end
    -- Rebuild output to fully restore pre-modification state
    build.calcsTab:BuildOutput()
  end

  return {
    output = deepCopySafe(out),
    baseOutput = deepCopySafe(baseOut),
  }
end


-- Get basic config values
function M.get_config()
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  local cfg = {
    bandit = build.configTab.input and build.configTab.input.bandit or build.bandit,
    pantheonMajorGod = build.configTab.input and build.configTab.input.pantheonMajorGod or build.pantheonMajorGod,
    pantheonMinorGod = build.configTab.input and build.configTab.input.pantheonMinorGod or build.pantheonMinorGod,
    enemyLevel = build.configTab.enemyLevel,
  }
  return cfg
end

-- Get full config values including combat conditions
function M.get_full_config()
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  local input = build.configTab.input or {}
  local cfg = {
    -- Basic config
    bandit = input.bandit or build.bandit,
    pantheonMajorGod = input.pantheonMajorGod or build.pantheonMajorGod,
    pantheonMinorGod = input.pantheonMinorGod or build.pantheonMinorGod,
    enemyLevel = build.configTab.enemyLevel,
    resistancePenalty = input.resistancePenalty,

    -- Charges
    usePowerCharges = input.usePowerCharges or false,
    useFrenzyCharges = input.useFrenzyCharges or false,
    useEnduranceCharges = input.useEnduranceCharges or false,
    overridePowerCharges = input.overridePowerCharges,
    overrideFrenzyCharges = input.overrideFrenzyCharges,
    overrideEnduranceCharges = input.overrideEnduranceCharges,

    -- Combat buffs
    buffOnslaught = input.buffOnslaught or false,
    buffFortification = input.buffFortification or false,
    overrideFortification = input.overrideFortification,
    buffTailwind = input.buffTailwind or false,
    buffAdrenaline = input.buffAdrenaline or false,
    buffUnholyMight = input.buffUnholyMight or false,
    conditionUsingFlask = input.conditionUsingFlask or false,

    -- Combat conditions
    conditionLowLife = input.conditionLowLife or false,
    conditionFullLife = input.conditionFullLife or false,
    conditionLowMana = input.conditionLowMana or false,
    conditionFullMana = input.conditionFullMana or false,

    -- Enemy conditions
    enemyIsBoss = input.enemyIsBoss or "None",
    conditionEnemyIntimidated = input.conditionEnemyIntimidated or false,
    conditionEnemyUnnerved = input.conditionEnemyUnnerved or false,
    conditionEnemyCoveredInAsh = input.conditionEnemyCoveredInAsh or false,
    conditionEnemyCoveredInFrost = input.conditionEnemyCoveredInFrost or false,
    enemyIsChilled = input.conditionEnemyChilled or false,
    enemyIsShocked = input.conditionEnemyShocked or false,
    enemyIsCrushed = input.conditionEnemyCrushed or false,
    enemyIsBlinded = input.conditionEnemyBlinded or false,

    -- Enemy stats overrides
    enemyFireResist = input.enemyFireResist,
    enemyColdResist = input.enemyColdResist,
    enemyLightningResist = input.enemyLightningResist,
    enemyChaosResist = input.enemyChaosResist,
    enemyPhysicalDamageReduction = input.enemyPhysicalDamageReduction,

    -- Custom modifiers
    customMods = input.customMods or "",
  }
  return cfg
end

-- Set selected config values and rebuild
function M.set_config(params)
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local input = build.configTab.input or {}
  build.configTab.input = input
  local changed = false

  -- Basic config
  if params.bandit ~= nil then input.bandit = tostring(params.bandit); changed = true end
  if params.pantheonMajorGod ~= nil then input.pantheonMajorGod = tostring(params.pantheonMajorGod); changed = true end
  if params.pantheonMinorGod ~= nil then input.pantheonMinorGod = tostring(params.pantheonMinorGod); changed = true end
  if params.enemyLevel ~= nil then build.configTab.enemyLevel = tonumber(params.enemyLevel) or build.configTab.enemyLevel; changed = true end
  if params.resistancePenalty ~= nil then input.resistancePenalty = tonumber(params.resistancePenalty); changed = true end

  -- Charges
  if params.usePowerCharges ~= nil then input.usePowerCharges = params.usePowerCharges; changed = true end
  if params.useFrenzyCharges ~= nil then input.useFrenzyCharges = params.useFrenzyCharges; changed = true end
  if params.useEnduranceCharges ~= nil then input.useEnduranceCharges = params.useEnduranceCharges; changed = true end
  if params.overridePowerCharges ~= nil then input.overridePowerCharges = tonumber(params.overridePowerCharges); changed = true end
  if params.overrideFrenzyCharges ~= nil then input.overrideFrenzyCharges = tonumber(params.overrideFrenzyCharges); changed = true end
  if params.overrideEnduranceCharges ~= nil then input.overrideEnduranceCharges = tonumber(params.overrideEnduranceCharges); changed = true end

  -- Combat buffs
  if params.buffOnslaught ~= nil then input.buffOnslaught = params.buffOnslaught; changed = true end
  if params.buffFortification ~= nil then input.buffFortification = params.buffFortification; changed = true end
  if params.overrideFortification ~= nil then input.overrideFortification = tonumber(params.overrideFortification); changed = true end
  if params.buffTailwind ~= nil then input.buffTailwind = params.buffTailwind; changed = true end
  if params.buffAdrenaline ~= nil then input.buffAdrenaline = params.buffAdrenaline; changed = true end
  if params.buffUnholyMight ~= nil then input.buffUnholyMight = params.buffUnholyMight; changed = true end
  if params.conditionUsingFlask ~= nil then input.conditionUsingFlask = params.conditionUsingFlask; changed = true end

  -- Combat conditions
  if params.conditionLowLife ~= nil then input.conditionLowLife = params.conditionLowLife; changed = true end
  if params.conditionFullLife ~= nil then input.conditionFullLife = params.conditionFullLife; changed = true end
  if params.conditionLowMana ~= nil then input.conditionLowMana = params.conditionLowMana; changed = true end
  if params.conditionFullMana ~= nil then input.conditionFullMana = params.conditionFullMana; changed = true end

  -- Enemy conditions
  if params.enemyIsBoss ~= nil then input.enemyIsBoss = tostring(params.enemyIsBoss); changed = true end
  if params.conditionEnemyIntimidated ~= nil then input.conditionEnemyIntimidated = params.conditionEnemyIntimidated; changed = true end
  if params.conditionEnemyUnnerved ~= nil then input.conditionEnemyUnnerved = params.conditionEnemyUnnerved; changed = true end
  if params.conditionEnemyCoveredInAsh ~= nil then input.conditionEnemyCoveredInAsh = params.conditionEnemyCoveredInAsh; changed = true end
  if params.conditionEnemyCoveredInFrost ~= nil then input.conditionEnemyCoveredInFrost = params.conditionEnemyCoveredInFrost; changed = true end
  if params.enemyIsChilled ~= nil then input.conditionEnemyChilled = params.enemyIsChilled; changed = true end
  if params.enemyIsShocked ~= nil then input.conditionEnemyShocked = params.enemyIsShocked; changed = true end
  if params.enemyIsCrushed ~= nil then input.conditionEnemyCrushed = params.enemyIsCrushed; changed = true end
  if params.enemyIsBlinded ~= nil then input.conditionEnemyBlinded = params.enemyIsBlinded; changed = true end

  -- Enemy stats overrides
  if params.enemyFireResist ~= nil then input.enemyFireResist = tonumber(params.enemyFireResist); changed = true end
  if params.enemyColdResist ~= nil then input.enemyColdResist = tonumber(params.enemyColdResist); changed = true end
  if params.enemyLightningResist ~= nil then input.enemyLightningResist = tonumber(params.enemyLightningResist); changed = true end
  if params.enemyChaosResist ~= nil then input.enemyChaosResist = tonumber(params.enemyChaosResist); changed = true end
  if params.enemyPhysicalDamageReduction ~= nil then input.enemyPhysicalDamageReduction = tonumber(params.enemyPhysicalDamageReduction); changed = true end

  -- Custom modifiers
  if params.customMods ~= nil then input.customMods = tostring(params.customMods); changed = true end

  -- Reset API-specific config (curse overrides, etc.)
  if params.resetApiConfig then
    input.disabledCurses = nil
    input.overrideCurseLimit = nil
    changed = true
  end

  -- Curse override for A/B testing
  if params.disabledCurses ~= nil then
    if type(params.disabledCurses) == 'table' then
      input.disabledCurses = params.disabledCurses
    else
      input.disabledCurses = nil
    end
    changed = true
  end
  if params.overrideCurseLimit ~= nil then
    input.overrideCurseLimit = tonumber(params.overrideCurseLimit)
    changed = true
  end

  if changed and build.configTab.BuildModList then build.configTab:BuildModList() end
  M.get_main_output()
  return true
end


-- Skills API
function M.get_skills()
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end

  -- Use the active skill set's socketGroupList, consistent with add_gem/remove_gem
  -- The top-level build.skillsTab.socketGroupList may be stale and have different indices
  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  local socketGroupList = skillSet and skillSet.socketGroupList or build.skillsTab.socketGroupList or {}

  local groups = {}
  for idx, g in ipairs(socketGroupList) do
    -- Get active skill names from displaySkillList
    local names = {}
    if g.displaySkillList then
      for _, eff in ipairs(g.displaySkillList) do
        if eff and eff.activeEffect and eff.activeEffect.grantedEffect then
          table.insert(names, eff.activeEffect.grantedEffect.name)
        end
      end
    end

    -- Get full gem list (includes both active and support gems)
    local gemList = {}
    if g.gemList then
      for gemIdx, gem in ipairs(g.gemList) do
        if gem then
          -- Support gem detection via gemData.grantedEffect.support
          -- gemData contains the gem definition from Data/Gems.lua which includes grantedEffect
          -- grantedEffect.support is true for support gems, nil/false for active gems
          local isSupportGem = false
          if gem.gemData and gem.gemData.grantedEffect and gem.gemData.grantedEffect.support then
            isSupportGem = true
          end

          -- Check for dual-nature gems like Autoexertion that have both active and support effects
          -- secondaryGrantedEffect is a separate support effect that triggers on other skills
          local hasSecondarySupport = false
          local secondarySupportName = nil
          if gem.gemData and gem.gemData.secondaryGrantedEffect then
            local secondary = gem.gemData.secondaryGrantedEffect
            if secondary.support then
              hasSecondarySupport = true
              secondarySupportName = secondary.name or gem.gemData.secondaryEffectName
            end
          end

          -- Extract skill type and tags from gemData for categorization
          -- Priority order: aura > herald > guard > warcry > movement > minion > totem > trap > mine > attack > spell
          local skillType = nil
          local gemTags = {}
          local tagString = nil
          if gem.gemData then
            local tags = gem.gemData.tags or {}
            tagString = gem.gemData.tagString
            -- Copy tags for JSON serialization
            for k, v in pairs(tags) do
              if v == true then
                gemTags[k] = true
              end
            end
            -- Determine primary skill type from tags (priority order)
            if tags.aura then
              skillType = 'aura'
            elseif tags.herald then
              skillType = 'herald'
            elseif tags.guard then
              skillType = 'guard'
            elseif tags.warcry then
              skillType = 'warcry'
            elseif tags.movement then
              skillType = 'movement'
            elseif tags.minion then
              skillType = 'minion'
            elseif tags.totem then
              skillType = 'totem'
            elseif tags.trap then
              skillType = 'trap'
            elseif tags.mine then
              skillType = 'mine'
            elseif tags.attack then
              skillType = 'attack'
            elseif tags.spell then
              skillType = 'spell'
            end
          end

          table.insert(gemList, {
            index = gemIdx,
            nameSpec = gem.nameSpec,
            level = gem.level,
            quality = gem.quality,
            qualityId = gem.qualityId,
            enabled = gem.enabled ~= false,
            isSupport = isSupportGem,
            skillType = skillType,
            tags = gemTags,
            tagString = tagString,
            -- Dual-nature gem support (e.g., Autoexertion has both active warcry and support effect)
            hasSecondarySupport = hasSecondarySupport or nil,  -- nil if false to keep JSON clean
            secondarySupportName = secondarySupportName,
          })
        end
      end
    end

    table.insert(groups, {
      index = idx,
      label = g.label,
      slot = g.slot,
      enabled = g.enabled,
      includeInFullDPS = g.includeInFullDPS,
      mainActiveSkill = g.mainActiveSkill,
      skills = names,
      gemList = gemList,  -- Full gem list with support gems
    })
  end

  local result = {
    mainSocketGroup = build.mainSocketGroup,
    calcsSkillNumber = build.calcsTab.input and build.calcsTab.input.skill_number or nil,
    groups = groups,
  }
  return result
end

function M.set_main_selection(params)
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if params.mainSocketGroup ~= nil then
    build.mainSocketGroup = tonumber(params.mainSocketGroup) or build.mainSocketGroup
  end
  local g = build.skillsTab.socketGroupList[build.mainSocketGroup]
  if not g then return nil, 'invalid mainSocketGroup' end
  if params.mainActiveSkill ~= nil then
    g.mainActiveSkill = tonumber(params.mainActiveSkill) or g.mainActiveSkill
  end
  if params.skillPart ~= nil then
    local idx = g.mainActiveSkill or 1
    local src = g.displaySkillList and g.displaySkillList[idx] and g.displaySkillList[idx].activeEffect and g.displaySkillList[idx].activeEffect.srcInstance
    if src then src.skillPart = tonumber(params.skillPart) end
  end
  -- Keep calcsTab in sync: use active group index
  build.calcsTab.input.skill_number = build.mainSocketGroup
  M.get_main_output()
  return true
end

-- Items API
function M.add_item_text(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.text) ~= 'string' then return nil, 'missing text' end

  -- Validate input to prevent potential issues
  if #params.text == 0 then return nil, 'item text cannot be empty' end
  if #params.text > MAX_ITEM_TEXT_LENGTH then
    return nil, string.format('item text too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
  end

  -- Use pcall to safely handle item creation
  local ok, item = pcall(new, 'Item', params.text)
  if not ok then return nil, 'invalid item text: ' .. tostring(item) end
  if not item or not item.baseName then return nil, 'failed to parse item' end

  item:NormaliseQuality()
  build.itemsTab:AddItem(item, params.noAutoEquip == true)
  if params.slotName then
    local slot = tostring(params.slotName)
    if build.itemsTab.slots[slot] then
      build.itemsTab.slots[slot]:SetSelItemId(item.id)
      build.itemsTab:PopulateSlots()
    end
  end
  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return { id = item.id, name = item.name, slot = params.slotName or item:GetPrimarySlot() }
end

-- Batch add multiple items at once (reduces round-trips)
-- params: { items: [{text: string, slotName?: string, noAutoEquip?: boolean}] }
-- Returns: { results: [{ok: boolean, id?: number, name?: string, slot?: string, error?: string}] }
function M.add_items_batch(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.items) ~= 'table' then return nil, 'missing items array' end

  local results = {}
  local successCount = 0

  -- Process each item without triggering rebuild after each one
  for i, itemParams in ipairs(params.items) do
    local result = { index = i }

    -- Validate item params
    if type(itemParams) ~= 'table' or type(itemParams.text) ~= 'string' then
      result.ok = false
      result.error = 'missing or invalid text'
      table.insert(results, result)
      goto continue
    end

    if #itemParams.text == 0 then
      result.ok = false
      result.error = 'item text cannot be empty'
      table.insert(results, result)
      goto continue
    end

    if #itemParams.text > MAX_ITEM_TEXT_LENGTH then
      result.ok = false
      result.error = string.format('item text too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
      table.insert(results, result)
      goto continue
    end

    -- Try to create and add the item
    local ok, item = pcall(new, 'Item', itemParams.text)
    if not ok then
      result.ok = false
      result.error = 'invalid item text: ' .. tostring(item)
      table.insert(results, result)
      goto continue
    end

    if not item or not item.baseName then
      result.ok = false
      result.error = 'failed to parse item'
      table.insert(results, result)
      goto continue
    end

    -- Successfully created item - add to build
    item:NormaliseQuality()
    build.itemsTab:AddItem(item, itemParams.noAutoEquip == true)

    -- Equip to slot if specified (defer PopulateSlots to end)
    if itemParams.slotName then
      local slot = tostring(itemParams.slotName)
      if build.itemsTab.slots[slot] then
        build.itemsTab.slots[slot]:SetSelItemId(item.id)
        -- Auto-activate flasks when equipped via API
        if slot:match('^Flask %d$') and build.itemsTab.activeItemSet
            and build.itemsTab.activeItemSet[slot] then
          build.itemsTab.activeItemSet[slot].active = true
        end
      end
    end

    result.ok = true
    result.id = item.id
    result.name = item.name
    result.slot = itemParams.slotName or item:GetPrimarySlot()
    successCount = successCount + 1
    table.insert(results, result)

    ::continue::
  end

  -- Only do the expensive operations ONCE at the end
  if successCount > 0 then
    build.itemsTab:PopulateSlots()
    build.itemsTab:AddUndoState()
    build.buildFlag = true
    M.get_main_output()
  end

  return { results = results, successCount = successCount }
end

function M.set_flask_active(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local idx = tonumber(params.index)
  local active = params.active == true
  if not idx or idx < 1 or idx > NUM_FLASK_SLOTS then
    return nil, string.format('invalid flask index (must be 1-%d)', NUM_FLASK_SLOTS)
  end
  local slotName = 'Flask ' .. tostring(idx)
  if not build.itemsTab.activeItemSet or not build.itemsTab.activeItemSet[slotName] then return nil, 'slot not found' end
  build.itemsTab.activeItemSet[slotName].active = active
  build.itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()
  return true
end


-- Helper to extract mod line data for JSON serialization
local function extractModLine(modLine)
  if not modLine then return nil end
  -- Skip mods with nil or empty text - these are corrupted
  if not modLine.line or modLine.line == "" then return nil end
  local entry = {
    line = modLine.line,
    range = modLine.range,
    modTags = modLine.modTags or {},
  }
  -- Boolean flags
  if modLine.crafted then entry.crafted = true end
  if modLine.fractured then entry.fractured = true end
  if modLine.implicit then entry.implicit = true end
  if modLine.eater then entry.eater = true end
  if modLine.exarch then entry.exarch = true end
  if modLine.scourge then entry.scourge = true end
  if modLine.crucible then entry.crucible = true end
  if modLine.enchant then entry.enchant = true end
  if modLine.synthesis then entry.synthesis = true end
  if modLine.custom then entry.custom = true end
  return entry
end

-- Get equipped items summary with full mod data
function M.get_items()
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  local itemsTab = build.itemsTab
  local result = { }
  -- Prefer orderedSlots for deterministic order
  local ordered = itemsTab.orderedSlots or {}
  local seen = {}
  local function add_slot(slotName)
    if seen[slotName] then return end
    seen[slotName] = true
    local slotCtrl = itemsTab.slots[slotName]
    if not slotCtrl then return end
    local selId = slotCtrl.selItemId or 0
    -- Only include slots with equipped items
    if selId > 0 then
      local it = itemsTab.items[selId]
      if it then
        local entry = {
          slot = slotName,
          id = selId,
          name = it.name,
          baseName = it.baseName,
          type = it.type,
          rarity = it.rarity,
          raw = it.raw,
          -- Jewel radius metadata (used for Thread of Hope / Timeless rendering)
          jewelRadiusLabel = it.jewelRadiusLabel,
          jewelRadiusIndex = it.jewelRadiusIndex,
          -- Item metadata
          itemLevel = it.itemLevel,
          quality = it.quality,
          -- Item flags
          corrupted = it.corrupted or false,
          mirrored = it.mirrored or false,
          fractured = it.fractured or false,
          synthesised = it.synthesised or false,
          split = it.split or false,
          veiled = it.veiled or false,
          -- Influence flags
          shaperItem = it.shaperItem or false,
          elderItem = it.elderItem or false,
          crusaderItem = it.crusaderItem or false,
          redeemerItem = it.redeemerItem or false,
          hunterItem = it.hunterItem or false,
          warlordItem = it.warlordItem or false,
        }

        -- Affix data (prefix/suffix mod IDs and ranges)
        entry.prefixes = {}
        if it.prefixes then
          for _, p in ipairs(it.prefixes) do
            if p.modId and p.modId ~= "None" then
              table.insert(entry.prefixes, {
                modId = p.modId,
                range = p.range
              })
            end
          end
        end
        entry.suffixes = {}
        if it.suffixes then
          for _, s in ipairs(it.suffixes) do
            if s.modId and s.modId ~= "None" then
              table.insert(entry.suffixes, {
                modId = s.modId,
                range = s.range
              })
            end
          end
        end

        -- Affix counts and limits
        entry.prefixCount = #entry.prefixes
        entry.suffixCount = #entry.suffixes
        -- Most rare items have 3 prefix/suffix slots, but some bases differ
        -- For now, use standard limits (can be enhanced later with base-specific data)
        if it.rarity == "RARE" or it.rarity == "MAGIC" then
          entry.maxPrefixes = it.rarity == "MAGIC" and 1 or 3
          entry.maxSuffixes = it.rarity == "MAGIC" and 1 or 3
        end

        -- Structured mod lines
        entry.implicitMods = {}
        if it.implicitModLines then
          for _, modLine in ipairs(it.implicitModLines) do
            local mod = extractModLine(modLine)
            if mod then
              table.insert(entry.implicitMods, mod)
            else
              -- Debug: Log skipped mods for unique items
              if it.rarity == "UNIQUE" then
                print("[BuildOps] Skipped implicit mod for " .. (it.name or "unknown") .. ": line=" .. tostring(modLine.line))
              end
            end
          end
        end

        entry.explicitMods = {}
        if it.explicitModLines then
          for _, modLine in ipairs(it.explicitModLines) do
            local mod = extractModLine(modLine)
            if mod then
              table.insert(entry.explicitMods, mod)
            else
              -- Debug: Log skipped mods for unique items
              if it.rarity == "UNIQUE" then
                print("[BuildOps] Skipped explicit mod for " .. (it.name or "unknown") .. ": line=" .. tostring(modLine.line))
              end
            end
          end
        end

        entry.enchantMods = {}
        if it.enchantModLines then
          for _, modLine in ipairs(it.enchantModLines) do
            local mod = extractModLine(modLine)
            if mod then table.insert(entry.enchantMods, mod) end
          end
        end

        entry.scourgeMods = {}
        if it.scourgeModLines then
          for _, modLine in ipairs(it.scourgeModLines) do
            local mod = extractModLine(modLine)
            if mod then table.insert(entry.scourgeMods, mod) end
          end
        end

        entry.crucibleMods = {}
        if it.crucibleModLines then
          for _, modLine in ipairs(it.crucibleModLines) do
            local mod = extractModLine(modLine)
            if mod then table.insert(entry.crucibleMods, mod) end
          end
        end

        -- Catalyst info
        if it.catalyst then
          local catalystNames = {"Abrasive", "Accelerating", "Fertile", "Imbued", "Intrinsic", "Noxious", "Prismatic", "Tempering", "Turbulent", "Unstable"}
          entry.catalyst = catalystNames[it.catalyst]
          entry.catalystQuality = it.catalystQuality or 20
        end

        -- Requirements
        if it.requirements then
          entry.requirements = {
            level = it.requirements.level,
            str = it.requirements.str > 0 and it.requirements.str or nil,
            dex = it.requirements.dex > 0 and it.requirements.dex or nil,
            int = it.requirements.int > 0 and it.requirements.int or nil,
          }
        end

        -- Sockets
        if it.sockets and #it.sockets > 0 then
          entry.sockets = {}
          for _, socket in ipairs(it.sockets) do
            table.insert(entry.sockets, {
              color = socket.color,
              group = socket.group
            })
          end
        end

        -- Defense stats (armour, evasion, energy shield, ward)
        if it.armourData then
          entry.armourData = {
            armour = it.armourData.Armour,
            evasion = it.armourData.Evasion,
            energyShield = it.armourData.EnergyShield,
            ward = it.armourData.Ward,
          }
        end

        -- Flask/Tincture activation flag stored in activeItemSet
        local set = itemsTab.activeItemSet
        if set and set[slotName] and set[slotName].active ~= nil then
          entry.active = set[slotName].active and true or false
        end
        table.insert(result, entry)
      end
    end
  end
  for _, slot in ipairs(ordered) do
    if slot and slot.slotName then add_slot(slot.slotName) end
  end
  -- Add any remaining slots not in ordered list
  for slotName, _ in pairs(itemsTab.slots or {}) do add_slot(slotName) end
  return result
end


-- Skill/Gem Creation and Modification API

-- Create a new socket group
-- params: { label?: string, slot?: string, enabled?: boolean, includeInFullDPS?: boolean }
function M.create_socket_group(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then params = {} end

  local socketGroup = {
    label = params.label or '',
    slot = params.slot,
    enabled = params.enabled ~= false,
    includeInFullDPS = params.includeInFullDPS == true,
    gemList = {},
    mainActiveSkill = 1,
    mainActiveSkillCalcs = 1,
  }

  -- Get the active skill set
  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  -- Add to socket group list
  table.insert(skillSet.socketGroupList, socketGroup)
  local index = #skillSet.socketGroupList

  -- Process the socket group
  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return { index = index, label = socketGroup.label }
end

-- Add a gem to a socket group
-- params: { groupIndex: number, gemName: string, level?: number, quality?: number, qualityId?: string, enabled?: boolean }
function M.add_gem(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemName then return nil, 'missing groupIndex or gemName' end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found at index ' .. tostring(groupIndex) end

  -- Create gem instance
  local gemInstance = {
    nameSpec = tostring(params.gemName),
    level = tonumber(params.level) or 20,
    quality = tonumber(params.quality) or 0,
    qualityId = params.qualityId or 'Default',
    enabled = params.enabled ~= false,
    enableGlobal1 = true,
    enableGlobal2 = false,
    count = tonumber(params.count) or 1,
  }

  -- Try to find gem data
  if build.data and build.data.gems then
    for _, gemData in pairs(build.data.gems) do
      if gemData.name == gemInstance.nameSpec or gemData.nameSpec == gemInstance.nameSpec then
        gemInstance.gemId = gemData.id
        if gemData.grantedEffect then
          gemInstance.skillId = gemData.grantedEffect.id
        elseif gemData.grantedEffectId then
          gemInstance.skillId = gemData.grantedEffectId
        end
        gemInstance.gemData = gemData
        break
      end
    end
  end

  table.insert(socketGroup.gemList, gemInstance)
  local gemIndex = #socketGroup.gemList

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return { gemIndex = gemIndex, name = gemInstance.nameSpec }
end

-- Set gem level
-- params: { groupIndex: number, gemIndex: number, level: number }
function M.set_gem_level(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex or not params.level then
    return nil, 'missing groupIndex, gemIndex, or level'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)
  local level = tonumber(params.level)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  if level < 1 or level > 40 then return nil, 'invalid level (must be 1-40)' end

  gemInstance.level = level

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Set gem quality
-- params: { groupIndex: number, gemIndex: number, quality: number, qualityId?: string }
function M.set_gem_quality(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex or not params.quality then
    return nil, 'missing groupIndex, gemIndex, or quality'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)
  local quality = tonumber(params.quality)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  if quality < 0 or quality > 23 then return nil, 'invalid quality (must be 0-23)' end

  gemInstance.quality = quality
  if params.qualityId then
    gemInstance.qualityId = tostring(params.qualityId)
  end

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Remove a socket group
-- params: { groupIndex: number }
function M.remove_skill(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex then return nil, 'missing groupIndex' end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  -- Don't allow removing special groups with sources
  if socketGroup.source then
    return nil, 'cannot remove special socket groups (item/node granted skills)'
  end

  table.remove(skillSet.socketGroupList, groupIndex)

  build.buildFlag = true
  M.get_main_output()

  return true
end

-- Remove a gem from a socket group
-- params: { groupIndex: number, gemIndex: number }
function M.remove_gem(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex then
    return nil, 'missing groupIndex or gemIndex'
  end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found' end

  local gemInstance = socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found' end

  table.remove(socketGroup.gemList, gemIndex)

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return true
end


-- Search for passive tree nodes by keyword
-- params: { keyword: string, nodeType?: string ('normal'|'notable'|'keystone'), maxResults?: number, includeAllocated?: boolean, allocatedOnly?: boolean }
function M.search_nodes(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' or type(params.keyword) ~= 'string' then
    return nil, 'missing or invalid keyword'
  end

  local keyword = params.keyword:lower()
  local nodeType = params.nodeType and params.nodeType:lower() or nil
  local maxResults = tonumber(params.maxResults) or 50
  local includeAllocated = params.includeAllocated ~= false
  local allocatedOnly = params.allocatedOnly == true

  local results = {}
  local count = 0

  -- Get allocated nodes set for quick lookup
  local allocatedSet = {}
  if build.spec.allocNodes then
    for id, _ in pairs(build.spec.allocNodes) do
      allocatedSet[id] = true
    end
  end

  -- Choose iteration source: allocatedOnly uses allocNodes (much smaller set, guaranteed complete)
  local nodeSource = allocatedOnly and build.spec.allocNodes or build.spec.nodes

  -- Search through selected nodes
  for id, node in pairs(nodeSource) do
    if count >= maxResults then break end

    -- Skip if already allocated and we don't want allocated nodes (only relevant when not allocatedOnly)
    if not allocatedOnly and not includeAllocated and allocatedSet[id] then
      goto continue
    end

    -- Filter by node type if specified
    if nodeType then
      local nType = 'normal'
      if node.isKeystone then nType = 'keystone'
      elseif node.isNotable then nType = 'notable'
      elseif node.isJewelSocket then nType = 'jewel'
      elseif node.isMultipleChoiceOption then nType = 'mastery'
      elseif node.ascendancyName then nType = 'ascendancy'
      end
      if nType ~= nodeType then goto continue end
    end

    -- Check if keyword matches name
    local matches = false
    if node.name and node.name:lower():find(keyword, 1, true) then
      matches = true
    end

    -- Check if keyword matches stats/modifiers
    if not matches and node.sd then
      for _, stat in ipairs(node.sd) do
        if type(stat) == 'string' and stat:lower():find(keyword, 1, true) then
          matches = true
          break
        end
      end
    end

    -- Check modifiers list
    if not matches and node.modList then
      for _, mod in ipairs(node.modList) do
        local modStr = tostring(mod)
        if modStr:lower():find(keyword, 1, true) then
          matches = true
          break
        end
      end
    end

    if matches then
      local nodeType = 'normal'
      if node.isKeystone then nodeType = 'keystone'
      elseif node.isNotable then nodeType = 'notable'
      elseif node.isJewelSocket then nodeType = 'jewel'
      elseif node.isMultipleChoiceOption then nodeType = 'mastery'
      elseif node.ascendancyName then nodeType = 'ascendancy'
      end

      local stats = {}
      if node.sd then
        for _, stat in ipairs(node.sd) do
          if type(stat) == 'string' then
            table.insert(stats, stat)
          end
        end
      end

      table.insert(results, {
        id = id,
        name = node.name or 'Unnamed',
        type = nodeType,
        stats = stats,
        allocated = allocatedSet[id] == true,
        x = node.x,
        y = node.y,
        orbit = node.orbit,
        orbitIndex = node.orbitIndex,
        ascendancyName = node.ascendancyName,
      })
      count = count + 1
    end

    ::continue::
  end

  -- Sort results: keystones first, then notables, then normal
  table.sort(results, function(a, b)
    local typeOrder = { keystone = 1, notable = 2, jewel = 3, mastery = 4, ascendancy = 5, normal = 6 }
    local aOrder = typeOrder[a.type] or 99
    local bOrder = typeOrder[b.type] or 99
    if aOrder ~= bOrder then
      return aOrder < bOrder
    end
    return (a.name or '') < (b.name or '')
  end)

  return { nodes = results, count = #results }
end


-- Find shortest path from allocated nodes to a target node
-- params: { targetNodeId: number }
-- returns: { path: [...], cost: number, targetNode: {...} }
function M.find_path(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' or not params.targetNodeId then
    return nil, 'missing targetNodeId'
  end

  local targetId = tonumber(params.targetNodeId)
  local targetNode = build.spec.nodes[targetId]
  if not targetNode then
    return nil, 'target node not found: ' .. tostring(targetId)
  end

  -- If target is already allocated, no path needed
  if targetNode.alloc then
    return {
      path = {},
      cost = 0,
      targetNode = {
        id = targetNode.id,
        name = targetNode.name or targetNode.dn,
        type = targetNode.type,
        allocated = true
      }
    }
  end

  -- Run BuildPathFromNode from all allocated nodes
  -- This populates node.pathDist and node.path for all nodes
  if build.spec.BuildPathFromNode then
    -- Build paths from all allocated nodes
    for nodeId, node in pairs(build.spec.nodes) do
      if node.alloc then
        build.spec:BuildPathFromNode(node)
      end
    end
  else
    return nil, 'pathfinding not available (BuildPathFromNode missing)'
  end

  -- Check if target is reachable
  if not targetNode.pathDist or targetNode.pathDist >= 9999 then
    return nil, 'target node is not reachable from allocated nodes'
  end

  -- Extract path from target back to root
  local pathNodes = {}
  if targetNode.path then
    -- node.path is stored in reverse (target first, then parents)
    for i = #targetNode.path, 1, -1 do
      local node = targetNode.path[i]
      if not node.alloc then  -- Only include unallocated nodes in path
        table.insert(pathNodes, {
          id = node.id,
          name = node.name or node.dn,
          type = node.type,
          stats = node.sd or {}
        })
      end
    end
  end

  return {
    path = pathNodes,
    cost = targetNode.pathDist,
    targetNode = {
      id = targetNode.id,
      name = targetNode.name or targetNode.dn,
      type = targetNode.type,
      stats = targetNode.sd or {},
      allocated = false
    }
  }
end


-- Constants for trade query generation
local MAX_FILTERS = 35
local DEFAULT_ITEM_AFFIX_QUALITY = 0.5
local MAX_STAT_INCREASE = 2  -- matches data.misc.maxStatIncrease

-- Slot to category mapping (from TradeQueryGenerator.lua)
local slotToCategoryMap = {
  ["Body Armour"] = { queryStr = "armour.chest", category = "Chest" },
  ["Helmet"] = { queryStr = "armour.helmet", category = "Helmet" },
  ["Gloves"] = { queryStr = "armour.gloves", category = "Gloves" },
  ["Boots"] = { queryStr = "armour.boots", category = "Boots" },
  ["Amulet"] = { queryStr = "accessory.amulet", category = "Amulet" },
  ["Ring 1"] = { queryStr = "accessory.ring", category = "Ring" },
  ["Ring 2"] = { queryStr = "accessory.ring", category = "Ring" },
  ["Ring 3"] = { queryStr = "accessory.ring", category = "Ring" },
  ["Belt"] = { queryStr = "accessory.belt", category = "Belt" },
}

-- Weapon type mapping (from TradeQueryGenerator.lua)
local weaponTypeMap = {
  ["Shield"] = { queryStr = "armour.shield", category = "Shield" },
  ["Quiver"] = { queryStr = "armour.quiver", category = "Quiver" },
  ["Bow"] = { queryStr = "weapon.bow", category = "Bow" },
  ["Staff"] = { queryStr = "weapon.staff", category = "Staff" },
  ["Two Handed Sword"] = { queryStr = "weapon.twosword", category = "2HSword" },
  ["Two Handed Axe"] = { queryStr = "weapon.twoaxe", category = "2HAxe" },
  ["Two Handed Mace"] = { queryStr = "weapon.twomace", category = "2HMace" },
  ["Fishing Rod"] = { queryStr = "weapon.rod", category = "FishingRod" },
  ["One Handed Sword"] = { queryStr = "weapon.onesword", category = "1HSword" },
  ["Thrusting One Handed Sword"] = { queryStr = "weapon.onesword", category = "1HSword" },
  ["One Handed Axe"] = { queryStr = "weapon.oneaxe", category = "1HAxe" },
  ["One Handed Mace"] = { queryStr = "weapon.onemace", category = "1HMace" },
  ["Sceptre"] = { queryStr = "weapon.onemace", category = "1HMace" },
  ["Wand"] = { queryStr = "weapon.wand", category = "Wand" },
  ["Dagger"] = { queryStr = "weapon.dagger", category = "Dagger" },
  ["Rune Dagger"] = { queryStr = "weapon.dagger", category = "Dagger" },
  ["Claw"] = { queryStr = "weapon.claw", category = "Claw" },
}

-- Default base types for each category when no item exists
local defaultBaseTypes = {
  ["Chest"] = "Simple Robe",
  ["Helmet"] = "Iron Hat",
  ["Gloves"] = "Iron Gauntlets",
  ["Boots"] = "Iron Greaves",
  ["Amulet"] = "Coral Amulet",
  ["Ring"] = "Coral Ring",
  ["Belt"] = "Chain Belt",
  ["Shield"] = "Splintered Tower Shield",
  ["Quiver"] = "Serrated Arrow Quiver",
  ["Bow"] = "Crude Bow",
  ["Staff"] = "Gnarled Branch",
  ["2HSword"] = "Corroded Blade",
  ["2HAxe"] = "Stone Axe",
  ["2HMace"] = "Driftwood Club",
  ["FishingRod"] = "Fishing Rod",
  ["1HSword"] = "Rusted Sword",
  ["1HAxe"] = "Rusted Hatchet",
  ["1HMace"] = "Driftwood Club",
  ["Wand"] = "Driftwood Wand",
  ["Dagger"] = "Glass Shank",
  ["Claw"] = "Nailed Fist",
  ["1HWeapon"] = "Rusted Sword",
  ["2HWeapon"] = "Corroded Blade",
  ["AbyssJewel"] = "Searching Eye Jewel",
  ["BaseJewel"] = "Cobalt Jewel",
  ["AnyJewel"] = "Cobalt Jewel",
  ["Flask"] = "Divine Life Flask",
}

-- Calculate weighted ratio outputs (ported from TradeQueryGenerator.lua lines 172-199)
local function weightedRatioOutputs(baseOutput, newOutput, statWeights)
  local meanStatDiff = 0

  local function ratioModSums(...)
    local baseModSum = 0
    local newModSum = 0
    for _, mod in ipairs({ ... }) do
      baseModSum = baseModSum + (baseOutput[mod] or 0)
      newModSum = newModSum + (newOutput[mod] or 0)
    end

    if baseModSum == math.huge then
      return 0
    else
      if newModSum == math.huge then
        return MAX_STAT_INCREASE
      else
        return math.min(newModSum / ((baseModSum ~= 0) and baseModSum or 1), MAX_STAT_INCREASE)
      end
    end
  end

  for _, statTable in ipairs(statWeights) do
    if statTable.stat == "FullDPS" and not (baseOutput["FullDPS"] and newOutput["FullDPS"]) then
      meanStatDiff = meanStatDiff + ratioModSums("TotalDPS", "TotalDotDPS", "CombinedDPS") * statTable.weightMult
    end
    meanStatDiff = meanStatDiff + ratioModSums(statTable.stat) * statTable.weightMult
  end

  return meanStatDiff
end

-- Determine item category from slot and existing item
local function getItemCategoryForSlot(slotName, existingItem)
  local itemCategoryQueryStr = nil
  local itemCategory = nil

  -- Check simple slot mappings first
  if slotToCategoryMap[slotName] then
    return slotToCategoryMap[slotName].queryStr, slotToCategoryMap[slotName].category
  end

  -- Handle weapon slots dynamically based on equipped item
  if slotName == "Weapon 1" or slotName == "Weapon 2" then
    if existingItem and existingItem.type then
      local mapping = weaponTypeMap[existingItem.type]
      if mapping then
        return mapping.queryStr, mapping.category
      end
      -- Fallback for generic weapon types
      if existingItem.type:find("Two Handed") then
        return "weapon.twomelee", "2HWeapon"
      elseif existingItem.type:find("One Handed") then
        return "weapon.one", "1HWeapon"
      end
    end
    -- Default to 1H weapon if no item exists
    return "weapon.one", "1HWeapon"
  end

  -- Handle jewel slots
  if slotName:find("Abyssal") then
    return "jewel.abyss", "AbyssJewel"
  elseif slotName:find("Jewel") then
    return "jewel.base", "BaseJewel"
  end

  -- Handle flask slots
  if slotName:find("Flask") then
    return "flask", "Flask"
  end

  return nil, nil
end

-- Generate weighted trade query for a slot
-- params: { slotName: string, statWeights?: [{stat: string, weightMult: number}], options?: {includeCorrupted?, includeImplicit?, includeEldritch?, includeScourge?, includeSynthesis?} }
function M.generate_trade_query(params)
  if not build or not build.itemsTab or not build.calcsTab then
    return nil, 'build not initialized'
  end
  if type(params) ~= 'table' or type(params.slotName) ~= 'string' then
    return nil, 'missing or invalid slotName'
  end

  local slotName = params.slotName
  local slot = build.itemsTab.slots[slotName]
  if not slot then
    return nil, 'slot not found: ' .. slotName
  end

  -- Default stat weights if not provided
  local statWeights = params.statWeights or {
    { stat = "FullDPS", weightMult = 1.0 }
  }

  -- Options for which mod types to include
  local options = params.options or {}
  local includeExplicit = options.includeExplicit ~= false  -- default true
  local includeImplicit = options.includeImplicit ~= false  -- default true
  local includeCorrupted = options.includeCorrupted == true  -- default false
  local includeEldritch = options.includeEldritch == true    -- default false
  local includeScourge = options.includeScourge == true      -- default false
  local includeSynthesis = options.includeSynthesis == true  -- default false

  -- Figure out what type of item we're searching for
  local existingItem = build.itemsTab.items[slot.selItemId]
  local itemCategoryQueryStr, itemCategory = getItemCategoryForSlot(slotName, existingItem)

  if not itemCategory then
    return nil, 'unsupported slot type: ' .. slotName
  end

  -- Determine base type for test item
  local testItemType = existingItem and existingItem.baseName or defaultBaseTypes[itemCategory] or "Coral Amulet"

  -- Create a temp item for the slot with no mods
  local itemRawStr = "Rarity: RARE\nStat Tester\n" .. testItemType
  local testItem = new("Item", itemRawStr)
  if not testItem or not testItem.baseName then
    return nil, 'failed to create test item for base: ' .. testItemType
  end

  -- Calculate base output with a blank item
  local calcFunc, baseOutput = build.calcsTab:GetMiscCalculator()
  if not calcFunc then
    return nil, 'failed to get calculator'
  end

  local baseItemOutput = calcFunc({ repSlotName = slotName, repItem = testItem })
  -- Make weights more human readable
  local baseStatValue = weightedRatioOutputs(baseOutput, baseItemOutput, statWeights) * 1000

  -- Load mod data from QueryMods.lua
  local modData = nil
  local ok, loaded = pcall(LoadModule, "Data/QueryMods.lua")
  if ok and loaded then
    modData = loaded
  else
    -- Try alternative path
    ok, loaded = pcall(dofile, "Data/QueryMods.lua")
    if ok and loaded then
      modData = loaded
    else
      return nil, 'failed to load QueryMods.lua'
    end
  end

  -- Test each mod one at a time and cache the normalized stat diff to use as weight
  local modWeights = {}
  local alreadyWeightedMods = {}

  -- Function to generate mod weights for a mod type
  local function generateModWeights(modType)
    local modsToTest = modData[modType]
    if not modsToTest then return end

    for _, entry in pairs(modsToTest) do
      -- Skip if this mod doesn't apply to this item category
      if entry[itemCategory] == nil then
        goto continue
      end

      -- Don't calculate the same thing twice (can happen with corrupted vs implicit)
      if entry.tradeMod and alreadyWeightedMods[entry.tradeMod.id] then
        goto continue
      end

      -- Skip if no tradeMod data
      if not entry.tradeMod or not entry.tradeMod.text then
        goto continue
      end

      -- Test with a value halfway between the min and max available for this mod
      local modRange = entry[itemCategory]
      local modValue = math.ceil((modRange.max - modRange.min) * DEFAULT_ITEM_AFFIX_QUALITY + modRange.min)
      local modValueStr = (entry.sign and entry.sign or "") .. tostring(modValue)

      -- Apply override text for special cases
      local modLine
      if modValue == 1 and entry.specialCaseData and entry.specialCaseData.overrideModLineSingular then
        modLine = entry.specialCaseData.overrideModLineSingular
      elseif entry.specialCaseData and entry.specialCaseData.overrideModLine then
        modLine = entry.specialCaseData.overrideModLine
      else
        modLine = entry.tradeMod.text
      end
      modLine = modLine:gsub("#", modValueStr)

      -- Apply mod to test item
      testItem.explicitModLines[1] = { line = modLine, custom = true }
      testItem:BuildAndParseRaw()

      -- Skip if parsing failed
      if (testItem.modList and #testItem.modList == 0) or
         (testItem.slotModList and #testItem.slotModList[1] == 0 and #testItem.slotModList[2] == 0) then
        goto continue
      end

      -- Calculate with this mod
      local output = calcFunc({ repSlotName = slotName, repItem = testItem })
      local meanStatDiff = weightedRatioOutputs(baseOutput, output, statWeights) * 1000 - baseStatValue

      if meanStatDiff > 0.01 then
        table.insert(modWeights, {
          tradeModId = entry.tradeMod.id,
          weight = meanStatDiff / modValue,
          meanStatDiff = meanStatDiff,
          invert = entry.sign == "-" and true or false
        })
      end
      alreadyWeightedMods[entry.tradeMod.id] = true

      ::continue::
    end
  end

  -- Generate weights for each enabled mod type (NO coroutine.yield - run synchronously)
  if includeExplicit then
    generateModWeights("Explicit")
  end
  if includeImplicit then
    generateModWeights("Implicit")
  end
  if includeCorrupted then
    generateModWeights("Corrupted")
  end
  if includeEldritch then
    generateModWeights("Eater")
    generateModWeights("Exarch")
  end
  if includeScourge then
    generateModWeights("Scourge")
  end
  if includeSynthesis then
    generateModWeights("Synthesis")
  end

  -- Calc original item stats without anoint or enchant, and use that diff as a basis for default min sum
  local currentStatDiff = 0
  if existingItem then
    testItem.explicitModLines = {}
    if existingItem.explicitModLines then
      for _, modLine in ipairs(existingItem.explicitModLines) do
        table.insert(testItem.explicitModLines, modLine)
      end
    end
    if existingItem.scourgeModLines then
      for _, modLine in ipairs(existingItem.scourgeModLines) do
        table.insert(testItem.explicitModLines, modLine)
      end
    end
    if existingItem.implicitModLines then
      for _, modLine in ipairs(existingItem.implicitModLines) do
        table.insert(testItem.explicitModLines, modLine)
      end
    end
    if existingItem.crucibleModLines then
      for _, modLine in ipairs(existingItem.crucibleModLines) do
        table.insert(testItem.explicitModLines, modLine)
      end
    end
    testItem:BuildAndParseRaw()

    local originalOutput = calcFunc({ repSlotName = slotName, repItem = testItem })
    currentStatDiff = weightedRatioOutputs(baseOutput, originalOutput, statWeights) * 1000 - baseStatValue
  end

  -- Sort by mean stat diff rather than weight to more accurately prioritize stats that can contribute more
  table.sort(modWeights, function(a, b)
    return a.meanStatDiff > b.meanStatDiff
  end)

  -- This stat diff value will generally be higher than the weighted sum of the same item,
  -- because the stats are all applied at once and can thus multiply off each other.
  -- So apply a modifier to get a reasonable min and hopefully approximate that the query will start with small upgrades.
  local minWeight = currentStatDiff * 0.5

  -- Generate trade query table
  local queryTable = {
    query = {
      filters = {
        type_filters = {
          filters = {
            category = { option = itemCategoryQueryStr },
            rarity = { option = "nonunique" }
          }
        }
      },
      status = { option = "online" },
      stats = {
        {
          type = "weight",
          value = { min = minWeight },
          filters = {}
        }
      }
    },
    sort = { ["statgroup.0"] = "desc" },
    engine = "new"
  }

  -- Add mod weights to query (limited to MAX_FILTERS)
  local filters = 0
  for _, entry in ipairs(modWeights) do
    if filters >= MAX_FILTERS then break end
    table.insert(queryTable.query.stats[1].filters, {
      id = entry.tradeModId,
      value = { weight = entry.invert and (entry.weight * -1) or entry.weight }
    })
    filters = filters + 1
  end

  -- Handle no mods found case
  if #queryTable.query.stats[1].filters == 0 then
    return nil, 'could not generate search, found no mods to search for'
  end

  return {
    query = queryTable,
    modWeights = modWeights,
    itemCategory = itemCategory,
    itemCategoryQueryStr = itemCategoryQueryStr,
    currentStatDiff = currentStatDiff,
    minWeight = minWeight
  }
end

-- Set arbitrary skill-specific config input variable by name
-- params: { varName: string, value: any }
-- This is a generic setter that allows setting ANY config variable from ConfigOptions.lua
function M.set_skill_config(params)
  if not build or not build.configTab then
    return nil, 'build/config not initialized'
  end
  if type(params) ~= 'table' then
    return nil, 'invalid params: expected table'
  end
  if type(params.varName) ~= 'string' or params.varName == '' then
    return nil, 'missing or invalid varName: expected non-empty string'
  end
  if params.value == nil then
    return nil, 'missing value parameter'
  end

  local input = build.configTab.input or {}
  build.configTab.input = input

  -- Set the config variable directly
  input[params.varName] = params.value

  -- Rebuild mod list and recalculate
  if build.configTab.BuildModList then
    build.configTab:BuildModList()
  end
  M.get_main_output()

  return { ok = true, varName = params.varName, value = params.value }
end

-- Get aggregated stats from passive tree only
-- Uses source filtering to extract tree-specific modifiers
function M.get_tree_stats()
  if not build or not build.calcsTab then
    return nil, "build not initialized"
  end
  if build.calcsTab.BuildOutput then
    build.calcsTab:BuildOutput()
  end
  local modDB = build.calcsTab.mainEnv.modDB
  local cfg = { source = "Tree" }

  local result = {
    -- EHP Contributors (most impactful)
    lifeInc = modDB:Sum("INC", cfg, "Life") or 0,
    esInc = modDB:Sum("INC", cfg, "EnergyShield") or 0,
    armourInc = modDB:Sum("INC", cfg, "Armour", "ArmourAndEvasion", "Defences") or 0,
    evasionInc = modDB:Sum("INC", cfg, "Evasion", "ArmourAndEvasion", "Defences") or 0,
    blockBase = modDB:Sum("BASE", cfg, "BlockChance") or 0,
    spellSuppressBase = modDB:Sum("BASE", cfg, "SpellSuppressionChance") or 0,
    -- Attributes (affects both offense/defense)
    strBase = modDB:Sum("BASE", cfg, "Str") or 0,
    dexBase = modDB:Sum("BASE", cfg, "Dex") or 0,
    intBase = modDB:Sum("BASE", cfg, "Int") or 0,
    -- DPS Contributors (generic + crit)
    damageInc = modDB:Sum("INC", cfg, "Damage") or 0,
    critChanceInc = modDB:Sum("INC", cfg, "CritChance") or 0,
    critMultiBase = modDB:Sum("BASE", cfg, "CritMultiplier") or 0,
    dotMultiBase = modDB:Sum("BASE", cfg, "DotMultiplier") or 0,
    -- Speed (affects DPS directly)
    attackSpeedInc = modDB:Sum("INC", cfg, "Speed", "AttackSpeed") or 0,
    castSpeedInc = modDB:Sum("INC", cfg, "Speed", "CastSpeed") or 0,
  }
  return result
end

-- Get all jewel sockets from the passive tree
-- Returns list of socket nodes with their allocation status and equipped jewel
function M.get_jewel_sockets()
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if not build.itemsTab then
    return nil, "items not initialized"
  end

  local spec = build.spec
  local itemsTab = build.itemsTab
  local result = {}

  -- Iterate through all socket controls (jewel sockets in tree)
  for nodeId, socketCtrl in pairs(itemsTab.sockets) do
    local node = spec.nodes[nodeId]
    local isAllocated = spec.allocNodes[nodeId] ~= nil
    local equippedJewelId = spec.jewels[nodeId] or 0
    local equippedJewel = nil

    if equippedJewelId > 0 then
      local item = itemsTab.items[equippedJewelId]
      if item then
        equippedJewel = {
          id = equippedJewelId,
          name = item.name,
          baseName = item.baseName,
          type = item.type,
          rarity = item.rarity,
          raw = item.raw,
        }
      end
    end

    table.insert(result, {
      nodeId = nodeId,
      slotName = socketCtrl.slotName,
      isAllocated = isAllocated,
      equippedJewelId = equippedJewelId,
      equippedJewel = equippedJewel,
      -- Include node position for reference
      x = node and node.x or nil,
      y = node and node.y or nil,
    })
  end

  -- Sort by nodeId for consistent ordering
  table.sort(result, function(a, b) return a.nodeId < b.nodeId end)

  return result
end

-- Equip a jewel to a tree socket
-- params: { nodeId: number, text: string } or { nodeId: number, itemId: number }
-- If nodeId is not allocated, it will be automatically allocated
function M.set_jewel(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if not build.itemsTab then
    return nil, "items not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end

  local nodeId = tonumber(params.nodeId)
  if not nodeId then
    return nil, "missing or invalid nodeId"
  end

  local spec = build.spec
  local itemsTab = build.itemsTab

  -- Verify this is a valid jewel socket
  local socketCtrl = itemsTab.sockets[nodeId]
  if not socketCtrl then
    return nil, "nodeId " .. tostring(nodeId) .. " is not a jewel socket"
  end

  -- If the socket node is not allocated, allocate it first
  if not spec.allocNodes[nodeId] then
    -- Use update_tree_delta to add the node
    local current = M.get_tree()
    if not current then
      return nil, "failed to get current tree"
    end

    local newNodes = {}
    for _, id in ipairs(current.nodes) do
      table.insert(newNodes, id)
    end
    table.insert(newNodes, nodeId)

    -- Import the new tree with the socket allocated
    spec:ImportFromNodeList(
      current.classId or 0,
      current.ascendClassId or 0,
      current.secondaryAscendClassId or 0,
      newNodes,
      {},
      current.masteryEffects or {}
    )

    -- Update sockets status
    itemsTab:UpdateSockets()
  end

  local itemId = nil

  -- If text is provided, create the item first
  if params.text then
    if #params.text == 0 then
      return nil, "item text cannot be empty"
    end
    if #params.text > MAX_ITEM_TEXT_LENGTH then
      return nil, string.format("item text too long (max %d bytes)", MAX_ITEM_TEXT_LENGTH)
    end

    local ok, item = pcall(new, 'Item', params.text)
    if not ok then
      return nil, "invalid item text: " .. tostring(item)
    end
    if not item or not item.baseName then
      return nil, "failed to parse item"
    end

    -- Verify it's a jewel
    if item.type ~= "Jewel" then
      return nil, "item is not a jewel (type: " .. tostring(item.type) .. ")"
    end

    item:NormaliseQuality()
    itemsTab:AddItem(item, true) -- noAutoEquip = true
    itemId = item.id

  elseif params.itemId then
    -- Use existing item by ID
    itemId = tonumber(params.itemId)
    if not itemId or not itemsTab.items[itemId] then
      return nil, "invalid itemId or item not found"
    end
  else
    return nil, "must provide either text or itemId"
  end

  -- Equip the jewel to the socket
  -- Use socketCtrl directly - it's the slot control for this socket
  -- SetSelItemId properly updates both spec.jewels[nodeId] and slot.selItemId,
  -- and triggers BuildClusterJewelGraphs for cluster jewels
  local slotName = socketCtrl.slotName
  socketCtrl:SetSelItemId(itemId)
  itemsTab:PopulateSlots()

  itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()

  local item = itemsTab.items[itemId]
  return {
    nodeId = nodeId,
    slotName = slotName,
    itemId = itemId,
    name = item and item.name or nil,
    baseName = item and item.baseName or nil,
  }
end

-- Remove a jewel from a tree socket
-- params: { nodeId: number }
function M.remove_jewel(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if not build.itemsTab then
    return nil, "items not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end

  local nodeId = tonumber(params.nodeId)
  if not nodeId then
    return nil, "missing or invalid nodeId"
  end

  local spec = build.spec
  local itemsTab = build.itemsTab

  -- Verify this is a valid jewel socket
  local socketCtrl = itemsTab.sockets[nodeId]
  if not socketCtrl then
    return nil, "nodeId " .. tostring(nodeId) .. " is not a jewel socket"
  end

  local slotName = socketCtrl.slotName
  local previousJewelId = spec.jewels[nodeId] or 0

  -- Remove the jewel using socketCtrl directly
  -- SetSelItemId(0) properly clears both spec.jewels[nodeId] and slot.selItemId
  socketCtrl:SetSelItemId(0)
  itemsTab:PopulateSlots()

  itemsTab:AddUndoState()
  build.buildFlag = true
  M.get_main_output()

  return {
    nodeId = nodeId,
    slotName = slotName,
    previousJewelId = previousJewelId,
  }
end

-- Get all passive nodes within a jewel radius from a socket
-- params: { nodeId: number, radiusIndex?: number }
-- radiusIndex: 1=Small, 2=Medium, 3=Large, 4=VeryLarge, 5=Massive
-- If radiusIndex is omitted, returns nodes for all radii
function M.get_nodes_in_radius(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end

  local nodeId = tonumber(params.nodeId)
  if not nodeId then
    return nil, "missing or invalid nodeId"
  end

  local spec = build.spec
  local tree = spec.tree or build.tree

  -- Get the socket node
  local socketNode = tree.nodes[nodeId]
  if not socketNode then
    return nil, "nodeId " .. tostring(nodeId) .. " not found in tree"
  end
  if not socketNode.isJewelSocket then
    return nil, "nodeId " .. tostring(nodeId) .. " is not a jewel socket"
  end
  if not socketNode.nodesInRadius then
    return nil, "socket has no radius data (might be a charm socket)"
  end

  local radiusLabels = { "Small", "Medium", "Large", "Very Large", "Massive" }
  local results = {}

  local targetRadiusIndex = params.radiusIndex and tonumber(params.radiusIndex) or nil

  for radiusIndex, nodesInThisRadius in ipairs(socketNode.nodesInRadius) do
    -- Skip if user specified a different radius
    if targetRadiusIndex and radiusIndex ~= targetRadiusIndex then
      goto continue
    end

    -- Only process standard radii (1-5), skip Thread of Hope ring variants (6-10)
    if radiusIndex > 5 then
      goto continue
    end

    local radiusResult = {
      radiusIndex = radiusIndex,
      radiusLabel = radiusLabels[radiusIndex] or ("Index " .. radiusIndex),
      nodes = {}
    }

    for nodeIdInRadius, node in pairs(nodesInThisRadius) do
      -- Determine node type
      local nodeType = "normal"
      if node.isKeystone then
        nodeType = "keystone"
      elseif node.isNotable then
        nodeType = "notable"
      elseif node.isJewelSocket then
        nodeType = "jewel"
      elseif node.isMastery then
        nodeType = "mastery"
      end

      -- Check if node is allocated
      local isAllocated = spec.allocNodes[nodeIdInRadius] ~= nil

      -- Get node stats
      local stats = {}
      if node.sd then
        for _, stat in ipairs(node.sd) do
          table.insert(stats, stat)
        end
      end

      table.insert(radiusResult.nodes, {
        id = nodeIdInRadius,
        name = node.dn or node.name or "Unknown",
        type = nodeType,
        isAllocated = isAllocated,
        stats = stats,
        x = node.x,
        y = node.y,
      })
    end

    -- Sort nodes by type priority (keystones first, then notables, etc.)
    local typeOrder = { keystone = 1, notable = 2, jewel = 3, mastery = 4, normal = 5 }
    table.sort(radiusResult.nodes, function(a, b)
      local orderA = typeOrder[a.type] or 99
      local orderB = typeOrder[b.type] or 99
      if orderA ~= orderB then
        return orderA < orderB
      end
      return a.name < b.name
    end)

    table.insert(results, radiusResult)

    ::continue::
  end

  return {
    socketId = nodeId,
    socketName = socketNode.dn or socketNode.name or "Jewel Socket",
    socketX = socketNode.x,
    socketY = socketNode.y,
    radii = results,
  }
end

return M
