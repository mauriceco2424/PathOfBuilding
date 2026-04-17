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
  -- ALWAYS wipe GlobalCache before BuildOutput() to ensure idempotent results.
  -- Previously only wiped when buildFlag was set, but this caused stale cache
  -- reads when multiple API calls happened in sequence (e.g. set_config calls
  -- get_main_output which populates cache, then getFullCalcs calls BuildOutput
  -- again WITHOUT wiping — reading stale entries from the first pass).
  -- Toggling a config key off then back on would produce different DPS because
  -- each BuildOutput() pass read/wrote different cache entries.
  wipeGlobalCache()
  build.buildFlag = false
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
    "FireResistOverCap", "ColdResistOverCap", "LightningResistOverCap", "ChaosResistOverCap",
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

-- Fix cluster jewel validity for items parsed from text.
-- PoB's parseMod uses concatenated enchant text as lookup key (e.g., "claw...dagger..." for
-- skills with 2 enchant lines). Individual enchant lines from item text can't match, so
-- jewelData.clusterJewelSkill stays nil. The item-level field (set by "Cluster Jewel Skill:"
-- metadata header) is correct; copy it to jewelData and recompute clusterJewelValid.
function M._fixClusterJewelValid(item)
  if not item or not item.jewelData or not item.clusterJewel then return end
  if not item.jewelData.clusterJewelSkill and item.clusterJewelSkill then
    item.jewelData.clusterJewelSkill = item.clusterJewelSkill
  end
  if not item.jewelData.clusterJewelNodeCount and item.clusterJewelNodeCount then
    item.jewelData.clusterJewelNodeCount = item.clusterJewelNodeCount
  end
  -- Recompute valid flag (mirrors Item.lua line 1660-1662)
  item.jewelData.clusterJewelValid = item.jewelData.clusterJewelKeystone
    or ((item.jewelData.clusterJewelSkill or item.jewelData.clusterJewelSmallsAreNothingness)
        and item.jewelData.clusterJewelNodeCount)
    or (item.jewelData.clusterJewelSocketCountOverride and item.jewelData.clusterJewelNothingnessCount)
end

-- Export full calculation snapshot (all PoB calculation outputs)
-- This provides access to all internal PoB calculations including EHP, per-skill DPS, etc.
function M.get_full_calcs()
  if not build or not build.calcsTab then
    return nil, 'build not initialized'
  end

  -- ALWAYS wipe GlobalCache before BuildOutput() for idempotent results.
  -- See get_main_output() comment for full rationale.
  wipeGlobalCache()
  build.buildFlag = false

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
  local breakdown = calcsTab.breakdown or {}

  -- Extract config and skills context
  local configTab = build.configTab
  local skillsTab = build.skillsTab

  local configInput = configTab and configTab.input or {}
  local socketGroups = skillsTab and skillsTab.socketGroupList or {}

  -- Identify active skill from the calculation environment (not build.activeSkill which is GUI-only)
  local activeSkillName = nil
  if mainEnv and mainEnv.player and mainEnv.player.mainSkill then
    local ms = mainEnv.player.mainSkill
    if ms.activeEffect and ms.activeEffect.grantedEffect then
      activeSkillName = ms.activeEffect.grantedEffect.name
    end
  end
  -- Fallback to build.activeSkill (GUI context)
  if not activeSkillName and build.activeSkill and build.activeSkill.activeEffect and build.activeSkill.activeEffect.grantedEffect then
    activeSkillName = build.activeSkill.activeEffect.grantedEffect.name
  end

  -- When FullDPS is 0 (no skills marked includeInFullDPS), compute it from per-skill outputs.
  -- Also build a per-skill DPS breakdown for all enabled socket groups.
  local perSkillDPS = {}
  if mainEnv and mainEnv.player and mainEnv.player.activeSkillList then
    for _, activeSkill in ipairs(mainEnv.player.activeSkillList) do
      if activeSkill.socketGroup and activeSkill.socketGroup.enabled then
        local skillName = nil
        if activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect then
          skillName = activeSkill.activeEffect.grantedEffect.name
        end
        if skillName then
          -- Check if this skill's output is cached in GlobalCache (computed during BuildOutput MAIN pass)
          local uuid = cacheSkillUUID and cacheSkillUUID(activeSkill, mainEnv) or nil
          local skillOut = nil
          if uuid and GlobalCache and GlobalCache.cachedData and GlobalCache.cachedData["MAIN"] and GlobalCache.cachedData["MAIN"][uuid] then
            local cached = GlobalCache.cachedData["MAIN"][uuid]
            skillOut = cached.Env and cached.Env.player and cached.Env.player.output
          end
          if skillOut then
            t_insert(perSkillDPS, {
              name = skillName,
              CombinedDPS = skillOut.CombinedDPS or 0,
              TotalDPS = skillOut.TotalDPS or 0,
              TotalDotDPS = skillOut.TotalDotDPS or 0,
              TotalPoisonDPS = skillOut.TotalPoisonDPS or 0,
              PoisonDPS = skillOut.PoisonDPS,
              WithPoisonDPS = skillOut.WithPoisonDPS or 0,
              BleedDPS = skillOut.BleedDPS or 0,
              IgniteDPS = skillOut.IgniteDPS or 0,
              includeInFullDPS = activeSkill.socketGroup.includeInFullDPS or false,
            })
          end
        end
      end
    end
  end

  -- If FullDPS is 0 (no includeInFullDPS flags set), find the best DPS skill and use its
  -- CombinedDPS as FullDPS. Also overlay its DPS fields onto mainOutput so the caller
  -- gets the correct damage numbers even when mainSocketGroup points to a non-DPS skill.
  if not mainOutput.FullDPS or mainOutput.FullDPS == 0 then
    local bestDPS = 0
    local bestSkillOut = nil
    local bestSkillName = nil
    -- Find highest CombinedDPS from cached per-skill outputs
    if mainEnv and mainEnv.player and mainEnv.player.activeSkillList then
      for _, activeSkill in ipairs(mainEnv.player.activeSkillList) do
        if activeSkill.socketGroup and activeSkill.socketGroup.enabled
          and activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
          and not activeSkill.activeEffect.grantedEffect.support then
          local uuid = cacheSkillUUID and cacheSkillUUID(activeSkill, mainEnv) or nil
          if uuid and GlobalCache and GlobalCache.cachedData and GlobalCache.cachedData["MAIN"] and GlobalCache.cachedData["MAIN"][uuid] then
            local cached = GlobalCache.cachedData["MAIN"][uuid]
            local so = cached.Env and cached.Env.player and cached.Env.player.output
            if so and (so.CombinedDPS or 0) > bestDPS then
              bestDPS = so.CombinedDPS
              bestSkillOut = so
              bestSkillName = activeSkill.activeEffect.grantedEffect.name
            end
          end
        end
      end
    end
    if bestSkillOut and bestDPS > (mainOutput.CombinedDPS or 0) then
      -- Overlay the best skill's DPS fields onto mainOutput so callers get correct values
      local dpsFields = {
        "CombinedDPS", "TotalDPS", "TotalDotDPS", "TotalPoisonDPS", "PoisonDPS",
        "WithPoisonDPS", "BleedDPS", "IgniteDPS", "TotalIgniteDPS", "DecayDPS",
        "ImpaleDPS", "HitDPS", "AverageDamage", "Speed", "CritChance",
        "CritMultiplier", "EffectiveCritChance", "PoisonChance", "PoisonDamage",
        "TotalDot", "MirageDPS", "CullingDPS",
        -- Skill-specific stats that build-context.ts reads from mainOutput
        "Accuracy", "HitChance", "PreEffectiveCritChance",
        "AverageHit", "AverageBurstDamage", "AverageBurstHits",
        "PhysicalHitAverage", "FireHitAverage", "ColdHitAverage",
        "LightningHitAverage", "ChaosHitAverage",
        "FirePenetration", "ColdPenetration", "LightningPenetration", "ChaosPenetration",
        -- Totem/ballista limits — per-skill in CalcOffence.lua (line 1383).
        -- Without overlay, a build where mainSocketGroup points at a non-totem
        -- utility skill (e.g. Ballistas of Skyforging selected as the damage
        -- dealer but Precision owns mainSocketGroup) loses the totem cap.
        "ActiveTotemLimit", "TotemsSummoned",
      }
      for _, field in ipairs(dpsFields) do
        if bestSkillOut[field] ~= nil then
          mainOutput[field] = bestSkillOut[field]
        end
      end
      mainOutput.FullDPS = bestDPS
      activeSkillName = bestSkillName
    elseif mainOutput.CombinedDPS and mainOutput.CombinedDPS > 0 then
      mainOutput.FullDPS = mainOutput.CombinedDPS
    end
  end

  -- Surface per-hand accuracy to top-level so build-context.ts can read it.
  -- PoB calculates accuracy per weapon pass (MainHand/OffHand) in CalcOffence.lua,
  -- storing it at mainOutput.MainHand.Accuracy / mainOutput.OffHand.Accuracy.
  -- Without this, mainOutput.Accuracy is nil for attack builds.
  if (not mainOutput.Accuracy or mainOutput.Accuracy == 0) then
    local mh = mainOutput.MainHand
    local oh = mainOutput.OffHand
    if mh and type(mh) == "table" and mh.Accuracy and mh.Accuracy > 0 then
      mainOutput.Accuracy = mh.Accuracy
    elseif oh and type(oh) == "table" and oh.Accuracy and oh.Accuracy > 0 then
      mainOutput.Accuracy = oh.Accuracy
    end
  end

  -- Surface per-hand AccuracyHitChance too (in case top-level is missing)
  if (not mainOutput.AccuracyHitChance or mainOutput.AccuracyHitChance == 0) then
    local mh = mainOutput.MainHand
    if mh and type(mh) == "table" and mh.AccuracyHitChance and mh.AccuracyHitChance > 0 then
      mainOutput.AccuracyHitChance = mh.AccuracyHitChance
    end
  end

  -- Per-skill reservation breakdown. Fixes the case where the LLM sees a
  -- total ReservedMana number but can't explain why a tree swap that lost
  -- reservation efficiency broke mana so hard. Every active skill with
  -- reservation contributes a row with its mana/life percent + flat cost.
  -- Reads the post-CalcPerform values off activeSkill.skillData (set in
  -- CalcPerform.lua lines 1881-1898). Oracle flagged this on 2026-04-16.
  local perSkillReservation = {}
  if mainEnv and mainEnv.player and mainEnv.player.activeSkillList then
    for _, activeSkill in ipairs(mainEnv.player.activeSkillList) do
      local sd = activeSkill.skillData
      if sd then
        local manaPercent = sd.ManaReservedPercent or 0
        local manaFlat = sd.ManaReservedBase or 0
        local lifePercent = sd.LifeReservedPercent or 0
        local lifeFlat = sd.LifeReservedBase or 0
        -- When ReservedPercent is set, ReservedBase also gets a computed
        -- flat equivalent (mana * percent / 100). Distinguish "real" flat
        -- reservations (percent == 0) from percent-derived ones so the
        -- output isn't misleading.
        local flatOnlyMana = manaPercent == 0 and manaFlat > 0
        local flatOnlyLife = lifePercent == 0 and lifeFlat > 0
        if manaPercent > 0 or lifePercent > 0 or flatOnlyMana or flatOnlyLife then
          local skillName = nil
          if activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect then
            skillName = activeSkill.activeEffect.grantedEffect.name
          end
          if skillName then
            t_insert(perSkillReservation, {
              name = skillName,
              manaPercent = manaPercent,
              manaFlat = flatOnlyMana and manaFlat or 0,
              lifePercent = lifePercent,
              lifeFlat = flatOnlyLife and lifeFlat or 0,
            })
          end
        end
      end
    end
  end

  -- Deep copy all outputs to JSON-serializable format
  local mainOutputCopied = deepCopySafe(mainOutput)

  local result = {
    mainOutput = mainOutputCopied,
    output = deepCopySafe(output),
    skillOutput = deepCopySafe(skillOutput),
    breakdown = deepCopySafe(breakdown),
    config = deepCopySafe(configInput),
    skills = M.get_skills(),
    activeSkill = activeSkillName,
    perSkillDPS = perSkillDPS,
    perSkillReservation = perSkillReservation,
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
    nodeOverrides = {},
  }
  for id, node in pairs(spec.allocNodes or {}) do
    table.insert(out.nodes, id)
    if node then
      local name = node.dn or node.name
      local stats = {}
      if type(node.sd) == "table" then
        for _, stat in ipairs(node.sd) do
          if type(stat) == "string" then
            table.insert(stats, stat)
          end
        end
      end
      if name then
        out.nodeOverrides[tostring(id)] = {
          name = name,
          stats = stats,
          icon = node.icon,
          activeEffectImage = node.activeEffectImage,
          reminderText = node.reminderText,
        }
      end
    end
  end
  for mastery, effect in pairs(spec.masterySelections or {}) do
    out.masteryEffects[mastery] = effect
  end
  table.sort(out.nodes)
  if not next(out.nodeOverrides) then
    out.nodeOverrides = nil
  end

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
  -- Collect valid tree-viz links for a cluster subgraph node.
  --
  -- PoB's `node.linked` can include stale cross-tree references to
  -- unrelated main-tree jewel sockets (observed 2026-04-16: cluster notable
  -- 65618 linked to Watcher's Eye socket 12161 ~800 units away). Rendering
  -- those produces long spurious "active" lines across the canvas.
  --
  -- A cluster node only legitimately links to: another cluster-id node
  -- (id >= 0x10000, same subgraph or nested cluster's entrance) or its own
  -- parent socket. Everything else is dropped.
  local function collectLinks(node, parentSocketId)
    local links = {}
    local seen = {}
    if node and node.linked then
      for _, linkedNode in ipairs(node.linked) do
        if linkedNode and linkedNode.id and not seen[linkedNode.id] then
          if linkedNode.id >= 0x10000 or linkedNode.id == parentSocketId then
            seen[linkedNode.id] = true
            table.insert(links, linkedNode.id)
          end
        end
      end
    end
    table.sort(links)
    return links
  end

  local function deriveClusterSize(subGraph)
    if subGraph and subGraph.clusterSize then
      return subGraph.clusterSize
    end

    if subGraph and subGraph.nodes then
      for _, node in ipairs(subGraph.nodes) do
        if node and node.type ~= "Mastery" and node.o ~= nil then
          if node.o >= 3 then
            return "Large"
          elseif node.o >= 2 then
            return "Medium"
          else
            return "Small"
          end
        end
      end
    end

    return "Small"
  end

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

  -- Build lookup: node ID -> real cluster metadata (parent socket, group center, links).
  -- spec.subGraphs is keyed by a synthetic subgraph/entrance identifier, not the parent socket.
  local nodeMetadata = {}
  if spec.subGraphs then
    for subGraphId, subGraph in pairs(spec.subGraphs) do
      local parentSocketId = subGraph.parentSocket and subGraph.parentSocket.id or nil
      local groupX = subGraph.group and subGraph.group.x or nil
      local groupY = subGraph.group and subGraph.group.y or nil
      local clusterSize = deriveClusterSize(subGraph)
      if subGraph.nodes then
        for _, node in ipairs(subGraph.nodes) do
          nodeMetadata[node.id] = {
            socketNodeId = parentSocketId,
            groupX = groupX,
            groupY = groupY,
            clusterSize = clusterSize,
            subgraphId = subGraphId,
            links = collectLinks(node, parentSocketId),
          }
        end
      end
    end
  end

  -- Collect allocated cluster nodes
  for nodeId, node in pairs(spec.allocNodes) do
    if nodeId >= 0x10000 then
      -- This is a cluster node
      local metadata = nodeMetadata[nodeId] or {}
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
        socketNodeId = metadata.socketNodeId,  -- The parent socket this cluster is attached to
        clusterSize = metadata.clusterSize,
        groupX = metadata.groupX,
        groupY = metadata.groupY,
        links = metadata.links or {},
        subgraphId = metadata.subgraphId,
      })
    end
  end

  -- Also get unallocated cluster nodes from subgraphs (for complete visualization)
  if spec.subGraphs then
    for _, subGraph in pairs(spec.subGraphs) do
      if subGraph.nodes then
        for _, node in ipairs(subGraph.nodes) do
          -- Only add if not already in allocated nodes
          if not spec.allocNodes[node.id] then
            local metadata = nodeMetadata[node.id] or {}
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
              socketNodeId = metadata.socketNodeId,
              clusterSize = metadata.clusterSize,
              groupX = metadata.groupX,
              groupY = metadata.groupY,
              links = metadata.links or {},
              subgraphId = metadata.subgraphId,
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
-- Returns: { output = {...}, baseOutput = {...}, diagnostics = {...} } or nil, error
function M.calc_with(params)
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  local calcFunc, baseOut = build.calcsTab:GetMiscCalculator()

  -- Fix: When the cached calculator has 0 DPS (mainSocketGroup points to a
  -- non-DPS skill like an aura), create a fresh calculator with the correct
  -- main socket group. This mirrors the "best skill overlay" in get_main_output
  -- but applies it at the calculator level so both base and override use the
  -- correct DPS skill.
  -- NOTE: bestGroupIdx is declared here (outside the if block) because the
  -- calcFunc closure captures `build` by reference — when calcFunc(override)
  -- is called later, it reads build.mainSocketGroup again via initEnv().
  -- We must temporarily set build.mainSocketGroup = bestGroupIdx around that
  -- call too, not just around getMiscCalculator().
  local bestGroupIdx = nil
  local baseCombined = baseOut and baseOut.CombinedDPS or 0
  local baseFullDPSCheck = baseOut and baseOut.FullDPS or 0
  local baseTotalDPSCheck = baseOut and baseOut.TotalDPS or 0
  if baseCombined == 0 and baseFullDPSCheck == 0 and baseTotalDPSCheck == 0 then
    -- Find the best DPS socket group from GlobalCache MAIN mode data
    local bestDPS = 0
    local socketGroupList = build.skillsTab and build.skillsTab.socketGroupList
    local mainEnv = build.calcsTab and build.calcsTab.mainEnv
    if socketGroupList and mainEnv and mainEnv.player and mainEnv.player.activeSkillList
      and GlobalCache and GlobalCache.cachedData and GlobalCache.cachedData["MAIN"] then
      for idx, group in ipairs(socketGroupList) do
        if group.enabled then
          for _, activeSkill in ipairs(mainEnv.player.activeSkillList) do
            if activeSkill.socketGroup == group
              and activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
              and not activeSkill.activeEffect.grantedEffect.support then
              local uuid = cacheSkillUUID and cacheSkillUUID(activeSkill, mainEnv) or nil
              if uuid and GlobalCache.cachedData["MAIN"][uuid] then
                local cached = GlobalCache.cachedData["MAIN"][uuid]
                local so = cached.Env and cached.Env.player and cached.Env.player.output
                if so and (so.CombinedDPS or 0) > bestDPS then
                  bestDPS = so.CombinedDPS
                  bestGroupIdx = idx
                end
              end
            end
          end
        end
      end
    end
    if bestGroupIdx and bestGroupIdx ~= build.mainSocketGroup then
      io.stderr:write(string.format(
        "[calc_with] DPS fix: mainSocketGroup %d has 0 DPS, switching to group %d (CombinedDPS=%d)\n",
        build.mainSocketGroup or 0, bestGroupIdx, bestDPS
      ))
      local savedMainSocketGroup = build.mainSocketGroup
      build.mainSocketGroup = bestGroupIdx
      local freshCalcResults = nil
      local ok, errMsg = pcall(function()
        local calcsModule = build.calcsTab.calcs
        local f, b = calcsModule.getMiscCalculator(build)
        freshCalcResults = { calcFunc = f, baseOut = b }
      end)
      build.mainSocketGroup = savedMainSocketGroup
      if ok and freshCalcResults then
        calcFunc = freshCalcResults.calcFunc
        baseOut = freshCalcResults.baseOut
      else
        io.stderr:write(string.format("[calc_with] DPS fix: failed to create fresh calculator: %s\n", tostring(errMsg)))
      end
    end
  end

  local override = {}

  -- Diagnostics: track resolution failures so TypeScript can surface them
  local diagnostics = {
    addRequested = 0,
    addResolved = 0,
    addUnresolved = {},
    removeRequested = 0,
    removeResolved = 0,
    removeUnresolved = {},
  }

  if params and type(params.addNodes) == 'table' then
    local addNodes = {}
    local hasAddNodes = false
    diagnostics.addRequested = #params.addNodes
    for _, id in ipairs(params.addNodes) do
      local nid = tonumber(id)
      local n = nid and build.spec and build.spec.nodes and build.spec.nodes[nid]
      if n then
        addNodes[n] = true
        hasAddNodes = true
        diagnostics.addResolved = diagnostics.addResolved + 1
      else
        -- Fallback: check allocNodes directly (cluster/subgraph nodes may have
        -- different object refs after jewel subgraph rebuilds)
        local allocNode = nid and build.spec and build.spec.allocNodes and build.spec.allocNodes[nid]
        if allocNode then
          addNodes[allocNode] = true
          hasAddNodes = true
          diagnostics.addResolved = diagnostics.addResolved + 1
          io.stderr:write(string.format("[calc_with] addNode %s resolved via allocNodes fallback\n", tostring(id)))
        else
          table.insert(diagnostics.addUnresolved, id)
          io.stderr:write(string.format("[calc_with] WARN: addNode %s not found in spec.nodes or allocNodes\n", tostring(id)))
        end
      end
    end
    if hasAddNodes then override.addNodes = addNodes end
  end
  if params and type(params.removeNodes) == 'table' then
    local removeNodes = {}
    local hasRemoveNodes = false
    diagnostics.removeRequested = #params.removeNodes
    for _, id in ipairs(params.removeNodes) do
      local nid = tonumber(id)
      local n = nid and build.spec and build.spec.nodes and build.spec.nodes[nid]
      if n then
        -- Verify this node is actually allocated (removing unallocated node is a no-op)
        local isAllocated = build.spec.allocNodes and build.spec.allocNodes[nid]
        if isAllocated then
          removeNodes[n] = true
          hasRemoveNodes = true
          diagnostics.removeResolved = diagnostics.removeResolved + 1
        else
          -- Node exists in spec but isn't allocated — try allocNodes lookup
          -- (in case allocNodes has a different object ref for this ID)
          local allocNode = build.spec.allocNodes and build.spec.allocNodes[nid]
          if allocNode then
            removeNodes[allocNode] = true
            hasRemoveNodes = true
            diagnostics.removeResolved = diagnostics.removeResolved + 1
            io.stderr:write(string.format("[calc_with] removeNode %s: spec.nodes ref != allocNodes ref, using allocNodes\n", tostring(id)))
          else
            table.insert(diagnostics.removeUnresolved, id)
            io.stderr:write(string.format("[calc_with] WARN: removeNode %s found in spec.nodes but NOT allocated — removal is a no-op\n", tostring(id)))
          end
        end
      else
        -- Not in spec.nodes at all — try allocNodes directly
        local allocNode = nid and build.spec and build.spec.allocNodes and build.spec.allocNodes[nid]
        if allocNode then
          removeNodes[allocNode] = true
          hasRemoveNodes = true
          diagnostics.removeResolved = diagnostics.removeResolved + 1
          io.stderr:write(string.format("[calc_with] removeNode %s resolved via allocNodes fallback (not in spec.nodes)\n", tostring(id)))
        else
          table.insert(diagnostics.removeUnresolved, id)
          io.stderr:write(string.format("[calc_with] WARN: removeNode %s not found in spec.nodes or allocNodes\n", tostring(id)))
        end
      end
    end
    if hasRemoveNodes then override.removeNodes = removeNodes end
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

  -- Log override state for debugging 0% results
  local hasOverride = override.addNodes or override.removeNodes or override.masteryOverrides or override.conditions
  if not hasOverride then
    io.stderr:write(string.format(
      "[calc_with] WARNING: Override is EMPTY after resolution (add: %d/%d, remove: %d/%d) — will return identical before/after\n",
      diagnostics.addResolved, diagnostics.addRequested,
      diagnostics.removeResolved, diagnostics.removeRequested
    ))
  end

  -- If the DPS fix found a better group, temporarily switch mainSocketGroup
  -- so the calcFunc closure (which reads build.mainSocketGroup via initEnv)
  -- uses the correct DPS skill for the override calculation too.
  local savedMainSocketGroupForCalc = nil
  if bestGroupIdx and bestGroupIdx ~= build.mainSocketGroup then
    savedMainSocketGroupForCalc = build.mainSocketGroup
    build.mainSocketGroup = bestGroupIdx
  end
  local out = calcFunc(override, params and params.useFullDPS)
  if savedMainSocketGroupForCalc then
    build.mainSocketGroup = savedMainSocketGroupForCalc
  end

  -- Log key stats for debugging
  local baseFullDPS = baseOut and baseOut.FullDPS or 0
  local afterFullDPS = out and out.FullDPS or 0
  local baseTotalDPS = baseOut and baseOut.TotalDPS or 0
  local afterTotalDPS = out and out.TotalDPS or 0
  if diagnostics.addRequested > 0 or diagnostics.removeRequested > 0 then
    io.stderr:write(string.format(
      "[calc_with] Stats: FullDPS %d->%d, TotalDPS %d->%d, Life %d->%d, EHP %d->%d\n",
      baseFullDPS, afterFullDPS,
      baseTotalDPS, afterTotalDPS,
      (baseOut and baseOut.Life or 0), (out and out.Life or 0),
      (baseOut and baseOut.TotalEHP or 0), (out and out.TotalEHP or 0)
    ))
  end

  -- Use deepCopySafe to strip circular references and non-serializable values
  return {
    output = deepCopySafe(out),
    baseOutput = deepCopySafe(baseOut),
    diagnostics = diagnostics,
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

  -- 2. Capture baseline output BEFORE applying any modifications.
  -- GetMiscCalculator creates a calculator from current (unmodified) build state.
  -- Must happen here — before gem mutations — so baseOut reflects the original build.
  local baseCalcFunc, baseOut = build.calcsTab:GetMiscCalculator()
  local condOverride = {}
  if params and type(params.conditions) == 'table' then
    condOverride.conditions = params.conditions
  end
  baseOut = baseCalcFunc(condOverride, params and params.useFullDPS)

  -- 3. Apply gem modifications to LIVE state
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

    -- Build alternate search terms: with/without " Support" suffix
    -- PoB gem database uses names WITHOUT "Support" (e.g., "Deadly Ailments")
    -- but RepOE/gems.json uses WITH "Support" (e.g., "Deadly Ailments Support")
    local altSearchTerm = nil
    if searchTerm:sub(-8) == " Support" then
      altSearchTerm = searchTerm:sub(1, -9)  -- strip " Support"
    else
      altSearchTerm = searchTerm .. " Support"  -- add " Support"
    end

    for _, gemData in pairs(build.data.gems) do
      -- Try name match first (display name), including alternate suffix form
      if gemData.name == searchTerm or gemData.nameSpec == searchTerm
         or gemData.name == altSearchTerm or gemData.nameSpec == altSearchTerm then
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


-- Calculate what-if scenario with a jewel equipped in a tree socket, without persisting changes.
-- params: {
--   socketNodeId: number,          -- jewel socket node ID
--   jewelText: string,             -- PoB item text for the jewel
--   allocateNodes?: number[],      -- explicit node IDs to allocate (for cluster notables)
--   autoAllocateSocketPath?: bool, -- auto-path to the host socket if not allocated
--   autoAllocateNotables?: boolean,-- auto-find and allocate cluster notables
--   useFullDPS?: boolean           -- use full DPS calculation
-- }
-- Returns: { beforeOutput, afterOutput, allocatedNotables? } or nil, error
function M.calc_with_jewel(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if not build.itemsTab then return nil, 'items not initialized' end
  if not build.calcsTab then return nil, 'calcs not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end

  local nodeId = tonumber(params.socketNodeId)
  if not nodeId then return nil, 'missing or invalid socketNodeId' end

  local jewelText = params.jewelText
  if type(jewelText) ~= 'string' or #jewelText == 0 then
    return nil, 'missing or empty jewelText'
  end
  if #jewelText > MAX_ITEM_TEXT_LENGTH then
    return nil, string.format('jewelText too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
  end

  local spec = build.spec
  local itemsTab = build.itemsTab

  -- Verify this is a valid jewel socket
  local socketCtrl = itemsTab.sockets[nodeId]
  if not socketCtrl then
    return nil, 'nodeId ' .. tostring(nodeId) .. ' is not a jewel socket'
  end

  -- 1. Capture beforeOutput
  build.calcsTab:BuildOutput()
  local beforeOutput = deepCopySafe(build.calcsTab.mainOutput)

  -- 2. Snapshot all mutable state for restoration
  local savedJewels = {}
  for k, v in pairs(spec.jewels) do savedJewels[k] = v end

  local savedAllocNodeKeys = {}
  for k, _ in pairs(spec.allocNodes) do savedAllocNodeKeys[k] = true end

  local savedAllocExtended = {}
  for i, v in ipairs(spec.allocExtendedNodes) do savedAllocExtended[i] = v end

  local savedAllocSubgraph = {}
  for i, v in ipairs(spec.allocSubgraphNodes) do savedAllocSubgraph[i] = v end

  local savedNodeKeys = {}
  for k, _ in pairs(spec.nodes) do savedNodeKeys[k] = true end

  local savedSocketSelId = socketCtrl.selItemId

  -- Track items we create so we can clean them up
  local createdItemId = nil

  -- 3. Define the restore function (MUST run regardless of success/failure)
  local function restoreState()
    -- a. Unequip jewel from socket
    pcall(function()
      socketCtrl:SetSelItemId(savedSocketSelId or 0)
      itemsTab:PopulateSlots()
    end)

    -- b. Restore allocNodes: remove added keys, re-add removed keys
    for k, _ in pairs(spec.allocNodes) do
      if not savedAllocNodeKeys[k] then
        spec.allocNodes[k] = nil
      end
    end
    for k, _ in pairs(savedAllocNodeKeys) do
      if not spec.allocNodes[k] then
        local node = spec.nodes[k]
        if node then
          spec.allocNodes[k] = node
        end
      end
    end

    -- c. Restore allocExtendedNodes (array)
    wipeTable(spec.allocExtendedNodes)
    for i, v in ipairs(savedAllocExtended) do spec.allocExtendedNodes[i] = v end

    -- d. Restore allocSubgraphNodes.
    -- NOTE: allocSubgraphNodes is a TEMPORARY buffer consumed by BuildClusterJewelGraphs.
    -- It's typically empty after a build load. Instead of restoring the (likely empty) saved
    -- version, we reconstruct it from savedAllocNodeKeys: any saved allocated node with
    -- id >= 0x10000 (cluster subgraph) must be re-allocated after BuildClusterJewelGraphs.
    wipeTable(spec.allocSubgraphNodes)
    for k, _ in pairs(savedAllocNodeKeys) do
      if k >= 0x10000 then
        t_insert(spec.allocSubgraphNodes, k)
      end
    end

    -- e. Restore jewels map
    wipeTable(spec.jewels)
    for k, v in pairs(savedJewels) do spec.jewels[k] = v end

    -- f. Delete test item from items list AND itemOrderList
    --    (matches DeleteItem pattern in ItemsTab.lua:1554-1558)
    --    Without the itemOrderList cleanup, exportBuildXml() crashes on
    --    Classes/ItemsTab.lua:1121 when iterating orphaned nil entries.
    if createdItemId and itemsTab.items[createdItemId] then
      for idx, id in pairs(itemsTab.itemOrderList) do
        if id == createdItemId then
          table.remove(itemsTab.itemOrderList, idx)
          break
        end
      end
      itemsTab.items[createdItemId] = nil
    end

    -- g. Fix clusterJewelValid on ALL existing cluster jewels before rebuilding.
    -- BuildClusterJewelGraphs() during the test may have called BuildModList on
    -- existing items, resetting their jewelData. Re-fix before rebuilding subgraphs.
    -- Then rebuild with BuildClusterJewelGraphs (NOT just BuildAllDependsAndPaths)
    -- to properly destroy test subgraphs and recreate original ones.
    pcall(function()
      for nid, itemId in pairs(spec.jewels) do
        if itemId and itemId ~= 0 then
          local item = itemsTab.items[itemId]
          if item and item.clusterJewel then
            M._fixClusterJewelValid(item)
          end
        end
      end
      spec:BuildClusterJewelGraphs()
      itemsTab:UpdateSockets()
      itemsTab:PopulateSlots()
      build.buildFlag = true
      M.get_main_output()
    end)
  end

  -- Tracks every node allocated by this test (outer-socket travel + cluster
  -- subgraph BFS path + notables + the socket itself when newly allocated).
  -- Surfaced as `allocatedPathNodes` so the frontend visualization can show
  -- the full impact of the cluster, not just notable IDs. Without it, the
  -- "X added" diff badge undercounts (e.g. shows 3 notables when the real
  -- cost is 4 travel + 2 smalls + 3 notables = 9 nodes).
  local socketPathIds = {}

  -- 4. Execute the test in a pcall-protected block
  local ok, result = pcall(function()
    -- 4a. Allocate the host socket if not already allocated.
    -- When autoAllocateSocketPath is set, path to the socket first so ordinary
    -- jewels are tested in a connected live tree instead of a disconnected node.
    if not spec.allocNodes[nodeId] then
      local current = M.get_tree()
      if not current then error('failed to get current tree') end
      local newNodeSet = {}
      for _, id in ipairs(current.nodes) do
        newNodeSet[tonumber(id)] = true
      end

      if params.autoAllocateSocketPath then
        local pathResult, pathErr = M.find_path({ targetNodeId = nodeId })
        if not pathResult then
          error('failed to path to socket ' .. tostring(nodeId) .. ': ' .. tostring(pathErr))
        end
        for _, pathNode in ipairs(pathResult.path or {}) do
          if pathNode and pathNode.id then
            local pid = tonumber(pathNode.id)
            newNodeSet[pid] = true
            -- Only count nodes that weren't already allocated as "added" cost
            if not savedAllocNodeKeys[pid] then
              t_insert(socketPathIds, pid)
            end
          end
        end
      end

      newNodeSet[nodeId] = true
      -- The outer socket itself is also a new allocation if it wasn't already
      if not savedAllocNodeKeys[nodeId] then
        t_insert(socketPathIds, nodeId)
      end

      local newNodes = {}
      for id, _ in pairs(newNodeSet) do t_insert(newNodes, id) end
      table.sort(newNodes)
      spec:ImportFromNodeList(
        current.classId or 0,
        current.ascendClassId or 0,
        current.secondaryAscendClassId or 0,
        newNodes,
        {},
        current.masteryEffects or {}
      )
      itemsTab:UpdateSockets()
    end

    -- 4b. Create jewel item
    local parseOk, item = pcall(new, 'Item', jewelText)
    if not parseOk then error('invalid item text: ' .. tostring(item)) end
    if not item or not item.baseName then error('failed to parse item') end
    if item.type ~= 'Jewel' then error('item is not a jewel (type: ' .. tostring(item.type) .. ')') end

    item:NormaliseQuality()
    itemsTab:AddItem(item, true) -- noAutoEquip = true
    createdItemId = item.id

    -- Fix clusterJewelValid for multi-enchant bases (Claw+Dagger, etc.)
    -- parseMod can't resolve clusterJewelSkill from concatenated keys, but the
    -- "Cluster Jewel Skill:" metadata header (injected by TypeScript) sets
    -- item.clusterJewelSkill. Copy it to jewelData so BuildClusterJewelGraphs works.
    M._fixClusterJewelValid(item)

    -- 4c. Equip jewel to socket
    socketCtrl:SetSelItemId(createdItemId)
    itemsTab:PopulateSlots()

    -- 4d. Trigger build. For cluster jewels, we MUST call BuildClusterJewelGraphs
    -- explicitly — get_main_output() only does wipeGlobalCache + BuildOutput, which
    -- does NOT create/rebuild cluster subgraphs.
    if item.clusterJewel then
      spec:BuildClusterJewelGraphs()
    end
    build.buildFlag = true
    M.get_main_output()

    -- 4e. Auto-allocate cluster notables if requested.
    -- Tracks every node allocated by this test — used to surface the full
    -- "what gets speced into the tree" list to the frontend visualization
    -- (otherwise only notable IDs are returned and the cluster preview shows
    -- 3 nodes instead of the real ~9 = travel + smalls + notables).
    local allocatedNotableIds = nil
    local allocatedPathNodeIds = {}
    local pathSeen = {}
    local function recordPathNode(id)
      if id and not pathSeen[id] then
        pathSeen[id] = true
        t_insert(allocatedPathNodeIds, id)
      end
    end
    -- Seed with outer-socket travel path captured during step 4a.
    for _, pid in ipairs(socketPathIds) do recordPathNode(pid) end

    if params.autoAllocateNotables then
      -- Find newly created nodes (cluster subgraph nodes added by the jewel)
      local newNodes = {}
      for k, node in pairs(spec.nodes) do
        if not savedNodeKeys[k] then
          t_insert(newNodes, node)
        end
      end

      -- Find notables among new nodes
      local notables = {}
      for _, node in ipairs(newNodes) do
        if node.type == "Notable" then
          t_insert(notables, node)
        end
      end

      -- Allocate notables and any small passives on the path
      -- BFS from socket through cluster subgraph to each notable
      if #notables > 0 then
        allocatedNotableIds = {}
        for _, notable in ipairs(notables) do
          -- Simple BFS from socket node through linked cluster nodes to find path
          local visited = {}
          local queue = {}
          local parent = {}
          -- Start from the socket node in spec.nodes
          local socketNode = spec.nodes[nodeId]
          if socketNode then
            t_insert(queue, socketNode)
            visited[socketNode.id] = true
            local found = false
            while #queue > 0 and not found do
              local current = table.remove(queue, 1)
              if current.id == notable.id then
                found = true
                break
              end
              if current.linked then
                for _, linked in ipairs(current.linked) do
                  if not visited[linked.id] then
                    -- Only traverse through new cluster nodes or the socket itself
                    if not savedNodeKeys[linked.id] or linked.id == nodeId then
                      visited[linked.id] = true
                      parent[linked.id] = current.id
                      t_insert(queue, linked)
                    end
                  end
                end
              end
            end

            if found then
              -- Trace path from notable back to socket and allocate all nodes.
              -- Record EVERY node on this path (smalls + notable + intermediate
              -- subgraph nodes) so the visualization can show the full cluster
              -- spec, not just the notable endpoints.
              local pathId = notable.id
              while pathId and pathId ~= nodeId do
                local pathNode = spec.nodes[pathId]
                if pathNode and not spec.allocNodes[pathId] then
                  pathNode.alloc = true
                  spec.allocNodes[pathId] = pathNode
                end
                recordPathNode(pathId)
                pathId = parent[pathId]
              end
              t_insert(allocatedNotableIds, notable.id)
            end
          end
        end
      end

    elseif params.allocateNodes and type(params.allocateNodes) == 'table' then
      -- Explicit node allocation
      allocatedNotableIds = {}
      for _, nid in ipairs(params.allocateNodes) do
        local nid_num = tonumber(nid)
        if nid_num then
          local node = spec.nodes[nid_num]
          if node and not spec.allocNodes[nid_num] then
            node.alloc = true
            spec.allocNodes[nid_num] = node
            t_insert(allocatedNotableIds, nid_num)
            recordPathNode(nid_num)
          end
        end
      end
    end

    -- 4f. Rebuild if any nodes were allocated in step 4e
    if allocatedNotableIds and #allocatedNotableIds > 0 then
      build.buildFlag = true
      M.get_main_output()
    end

    -- 4g. Capture afterOutput
    local afterOutput = deepCopySafe(build.calcsTab.mainOutput)

    -- Diagnostic: log before/after CombinedDPS to verify jewel impact
    local bDPS = beforeOutput and beforeOutput.CombinedDPS or 0
    local aDPS = afterOutput and afterOutput.CombinedDPS or 0
    io.stderr:write(string.format("[calc_with_jewel] before CombinedDPS=%.1f  after CombinedDPS=%.1f  delta=%.1f\n", bDPS, aDPS, aDPS - bDPS))

    -- 4h. Snapshot the cluster subgraph so the frontend can render the full
    -- "wheel" for suggested cluster jewels (not yet equipped in the persisted
    -- build). Without this, the tree viz only highlights the allocated IDs —
    -- the unallocated small passives, mastery center, and internal ring
    -- connections are invisible because vizData.tree.clusterNodes only lists
    -- clusters actually equipped in the stored build.
    --
    -- Returns the same shape as M.get_cluster_nodes() so the frontend can
    -- merge both arrays and reuse the existing cluster render path.
    local clusterSubgraph = nil
    if item.clusterJewel and spec.subGraphs then
      local function collectSubgraphLinks(node, parentSocketId)
        local links = {}
        local seen = {}
        if node and node.linked then
          for _, linkedNode in ipairs(node.linked) do
            if linkedNode and linkedNode.id and not seen[linkedNode.id] then
              if linkedNode.id >= 0x10000 or linkedNode.id == parentSocketId then
                seen[linkedNode.id] = true
                t_insert(links, linkedNode.id)
              end
            end
          end
        end
        table.sort(links)
        return links
      end

      for _, subGraph in pairs(spec.subGraphs) do
        if subGraph.parentSocket and subGraph.parentSocket.id == nodeId and subGraph.nodes then
          clusterSubgraph = {}
          local groupX = subGraph.group and subGraph.group.x or nil
          local groupY = subGraph.group and subGraph.group.y or nil
          local clusterSize = "Small"
          for _, n in ipairs(subGraph.nodes) do
            if n and n.type ~= "Mastery" and n.o ~= nil then
              if n.o >= 3 then clusterSize = "Large"
              elseif n.o >= 2 then clusterSize = "Medium"
              else clusterSize = "Small" end
              break
            end
          end
          for _, n in ipairs(subGraph.nodes) do
            t_insert(clusterSubgraph, {
              id = n.id,
              name = n.dn or "Unknown",
              type = n.type or "Normal",
              stats = n.sd or {},
              icon = n.icon,
              x = n.x,
              y = n.y,
              orbit = n.o,
              orbitIndex = n.oidx,
              isAllocated = spec.allocNodes[n.id] ~= nil,
              socketNodeId = nodeId,
              clusterSize = clusterSize,
              groupX = groupX,
              groupY = groupY,
              links = collectSubgraphLinks(n, nodeId),
            })
          end
          break
        end
      end
    end

    return {
      beforeOutput = beforeOutput,
      afterOutput = afterOutput,
      allocatedNotables = allocatedNotableIds,
      allocatedPathNodes = allocatedPathNodeIds,
      pointCost = #allocatedPathNodeIds,
      clusterSubgraph = clusterSubgraph,
    }
  end)

  -- 5. ALWAYS restore state, regardless of success or failure
  restoreState()

  -- 6. Return result or error
  if not ok then
    return nil, tostring(result)
  end
  return result
end


-- Atomically test a cluster jewel chain (Large + nested Medium clusters) in a single operation.
-- Supports: Large only, Medium only, Large + 1-2 Mediums.
-- Returns { beforeOutput, afterOutput, allocatedNotables, totalPointCost }
function M.calc_with_cluster_chain(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if not build.itemsTab then return nil, 'items not initialized' end
  if not build.calcsTab then return nil, 'calcs not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end

  local outerNodeId = tonumber(params.outerSocketNodeId)
  if not outerNodeId then return nil, 'missing or invalid outerSocketNodeId' end

  local largeText = params.largeJewelText
  local mediumTexts = params.mediumJewelTexts or {}
  local useFullDPS = params.useFullDPS

  -- Validate: need at least one jewel
  local hasLarge = type(largeText) == 'string' and #largeText > 0
  local hasMedium = type(mediumTexts) == 'table' and #mediumTexts > 0
  if not hasLarge and not hasMedium then
    return nil, 'need at least one of largeJewelText or mediumJewelTexts'
  end

  -- Length checks
  if hasLarge and #largeText > MAX_ITEM_TEXT_LENGTH then
    return nil, string.format('largeJewelText too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
  end
  if hasMedium then
    for i, mt in ipairs(mediumTexts) do
      if type(mt) ~= 'string' or #mt == 0 then
        return nil, 'mediumJewelTexts[' .. tostring(i) .. '] is empty or not a string'
      end
      if #mt > MAX_ITEM_TEXT_LENGTH then
        return nil, string.format('mediumJewelTexts[%d] too long (max %d bytes)', i, MAX_ITEM_TEXT_LENGTH)
      end
    end
  end

  local spec = build.spec
  local itemsTab = build.itemsTab

  -- Verify outer socket
  local outerSocketCtrl = itemsTab.sockets[outerNodeId]
  if not outerSocketCtrl then
    return nil, 'outerSocketNodeId ' .. tostring(outerNodeId) .. ' is not a jewel socket'
  end

  -- 1. Capture beforeOutput
  build.calcsTab:BuildOutput()
  local beforeOutput = deepCopySafe(build.calcsTab.mainOutput)

  -- 2. Snapshot ALL mutable state
  local savedJewels = {}
  for k, v in pairs(spec.jewels) do savedJewels[k] = v end

  local savedAllocNodeKeys = {}
  for k, _ in pairs(spec.allocNodes) do savedAllocNodeKeys[k] = true end

  local savedAllocExtended = {}
  for i, v in ipairs(spec.allocExtendedNodes) do savedAllocExtended[i] = v end

  local savedAllocSubgraph = {}
  for i, v in ipairs(spec.allocSubgraphNodes) do savedAllocSubgraph[i] = v end

  local savedNodeKeys = {}
  for k, _ in pairs(spec.nodes) do savedNodeKeys[k] = true end

  local savedOuterSelId = outerSocketCtrl.selItemId

  -- Snapshot ALL socket selItemIds so we can restore nested ones too
  local savedSocketSelIds = {}
  for nid, ctrl in pairs(itemsTab.sockets) do
    savedSocketSelIds[nid] = ctrl.selItemId
  end

  -- Track ALL created item IDs for cleanup
  local createdItemIds = {}

  -- 3. Define restore function (MUST run regardless of success/failure)
  local function restoreState()
    -- a. Restore outer socket selection
    pcall(function()
      outerSocketCtrl:SetSelItemId(savedOuterSelId or 0)
      itemsTab:PopulateSlots()
    end)

    -- b. Restore any nested socket selections that were changed
    pcall(function()
      for nid, ctrl in pairs(itemsTab.sockets) do
        local savedId = savedSocketSelIds[nid]
        if savedId and ctrl.selItemId ~= savedId then
          ctrl:SetSelItemId(savedId)
        end
      end
      itemsTab:PopulateSlots()
    end)

    -- c. Rebuild to destroy cluster subgraphs
    pcall(function()
      build.buildFlag = true
      M.get_main_output()
    end)

    -- d. Restore allocNodes
    for k, _ in pairs(spec.allocNodes) do
      if not savedAllocNodeKeys[k] then
        spec.allocNodes[k] = nil
      end
    end
    for k, _ in pairs(savedAllocNodeKeys) do
      if not spec.allocNodes[k] then
        local node = spec.nodes[k]
        if node then spec.allocNodes[k] = node end
      end
    end

    -- e. Restore allocExtendedNodes
    wipeTable(spec.allocExtendedNodes)
    for i, v in ipairs(savedAllocExtended) do spec.allocExtendedNodes[i] = v end

    -- f. Restore allocSubgraphNodes.
    -- NOTE: allocSubgraphNodes is a TEMPORARY buffer consumed by BuildClusterJewelGraphs.
    -- It's typically empty after a build load. Instead of restoring the (likely empty) saved
    -- version, we reconstruct it from savedAllocNodeKeys: any saved allocated node with
    -- id >= 0x10000 (cluster subgraph) must be re-allocated after BuildClusterJewelGraphs.
    wipeTable(spec.allocSubgraphNodes)
    for k, _ in pairs(savedAllocNodeKeys) do
      if k >= 0x10000 then
        t_insert(spec.allocSubgraphNodes, k)
      end
    end

    -- g. Restore jewels
    wipeTable(spec.jewels)
    for k, v in pairs(savedJewels) do spec.jewels[k] = v end

    -- h. Delete ALL test items from items list AND itemOrderList (Section 15A)
    for _, cid in ipairs(createdItemIds) do
      if cid and itemsTab.items[cid] then
        for idx, id in pairs(itemsTab.itemOrderList) do
          if id == cid then
            table.remove(itemsTab.itemOrderList, idx)
            break
          end
        end
        itemsTab.items[cid] = nil
      end
    end

    -- i. Fix clusterJewelValid on ALL cluster jewels (not just test items).
    -- BuildClusterJewelGraphs() + BuildOutput() during the test may have called
    -- BuildModList on existing items, resetting their jewelData. We must re-fix
    -- all cluster jewels before rebuilding subgraphs.
    pcall(function()
      for nid, itemId in pairs(spec.jewels) do
        if itemId and itemId ~= 0 then
          local item = itemsTab.items[itemId]
          if item and item.clusterJewel then
            M._fixClusterJewelValid(item)
          end
        end
      end
      spec:BuildClusterJewelGraphs()
      itemsTab:UpdateSockets()
      itemsTab:PopulateSlots()
      build.buildFlag = true
      M.get_main_output()
    end)
  end

  -- 4. Execute in pcall-protected block
  -- Tracks every node allocated by this test (outer-socket travel + cluster
  -- BFS path + notables). Surfaced as `allocatedPathNodes` so the visualization
  -- can render the full cluster spec, not just notable endpoints.
  local socketPathIds = {}

  local ok, result = pcall(function()
    -- 4a. Path to outer socket if needed
    if not spec.allocNodes[outerNodeId] then
      local current = M.get_tree()
      if not current then error('failed to get current tree') end
      local newNodeSet = {}
      for _, id in ipairs(current.nodes) do
        newNodeSet[tonumber(id)] = true
      end

      if params.autoAllocateSocketPath then
        local pathResult, pathErr = M.find_path({ targetNodeId = outerNodeId })
        if not pathResult then
          error('failed to path to socket ' .. tostring(outerNodeId) .. ': ' .. tostring(pathErr))
        end
        for _, pathNode in ipairs(pathResult.path or {}) do
          if pathNode and pathNode.id then
            local pid = tonumber(pathNode.id)
            newNodeSet[pid] = true
            if not savedAllocNodeKeys[pid] then
              t_insert(socketPathIds, pid)
            end
          end
        end
      end

      newNodeSet[outerNodeId] = true
      if not savedAllocNodeKeys[outerNodeId] then
        t_insert(socketPathIds, outerNodeId)
      end

      local newNodes = {}
      for id, _ in pairs(newNodeSet) do t_insert(newNodes, id) end
      table.sort(newNodes)
      spec:ImportFromNodeList(
        current.classId or 0,
        current.ascendClassId or 0,
        current.secondaryAscendClassId or 0,
        newNodes,
        {},
        current.masteryEffects or {}
      )
      itemsTab:UpdateSockets()
    end

    -- 4b. Determine primary jewel (Large if present, else first Medium)
    local primaryText = nil
    local remainingMediums = {}
    if hasLarge then
      primaryText = largeText
      for i, mt in ipairs(mediumTexts) do
        t_insert(remainingMediums, mt)
      end
    else
      -- Medium-only: equip first medium in outer socket
      primaryText = mediumTexts[1]
      for i = 2, #mediumTexts do
        t_insert(remainingMediums, mediumTexts[i])
      end
    end

    -- 4c. Create and equip primary jewel
    local parseOk, primaryItem = pcall(new, 'Item', primaryText)
    if not parseOk then error('invalid primary jewel text: ' .. tostring(primaryItem)) end
    if not primaryItem or not primaryItem.baseName then error('failed to parse primary jewel') end
    if primaryItem.type ~= 'Jewel' then error('primary item is not a jewel (type: ' .. tostring(primaryItem.type) .. ')') end

    primaryItem:NormaliseQuality()
    itemsTab:AddItem(primaryItem, true) -- noAutoEquip
    t_insert(createdItemIds, primaryItem.id)

    -- 4d. Equip primary jewel and rebuild cluster subgraphs.
    -- BYPASS: Set spec.jewels directly instead of using SetSelItemId. SetSelItemId
    -- triggers BuildClusterJewelGraphs internally, which calls BuildModList on items,
    -- recreating jewelData from scratch. For multi-enchant cluster skills (e.g.,
    -- "Claw + Dagger"), PoB's parseMod can't match individual enchant lines to the
    -- concatenated key in clusterJewelSkills, so jewelData.clusterJewelSkill stays nil
    -- after every BuildModList call. By using the spec.jewels bypass and calling
    -- BuildClusterJewelGraphs ourselves, we can apply the fix right before the rebuild.
    --
    -- CRITICAL: _fixClusterJewelValid MUST run AFTER AddItem (which calls BuildModList,
    -- recreating jewelData = {}) and BEFORE BuildClusterJewelGraphs (which reads
    -- jewelData.clusterJewelValid to decide whether to create the subgraph).
    spec.jewels[outerNodeId] = primaryItem.id
    outerSocketCtrl.selItemId = primaryItem.id
    M._fixClusterJewelValid(primaryItem)
    spec:BuildClusterJewelGraphs()
    itemsTab:UpdateSockets()
    itemsTab:PopulateSlots()
    build.buildFlag = true
    M.get_main_output()

    -- 4e. Equip medium jewels in nested sockets (if we equipped a Large and have mediums)
    local equippedMediums = 0
    if hasLarge and #remainingMediums > 0 then
      -- After equipping a Large cluster, BuildClusterJewelGraphs creates subgraph nodes
      -- including nested jewel sockets. These sockets are in spec.nodes but NOT in
      -- itemsTab.sockets (they're unallocated). We can't use the socket controller
      -- (SetSelItemId) because UpdateSockets only registers ALLOCATED sockets.
      --
      -- BYPASS: Set spec.jewels[nestedSocketId] = mediumItemId directly. This is PoB's
      -- internal jewel-to-socket mapping. Then call BuildClusterJewelGraphs() which
      -- destroys and recreates ALL subgraphs from spec.jewels. During rebuild, it finds
      -- the Medium jewels in nested sockets and recursively creates their subgraphs.

      -- Find nested Socket nodes from the outer socket's subgraph structure directly.
      -- NOTE: We do NOT use savedNodeKeys comparison because BuildClusterJewelGraphs
      -- destroys and recreates ALL subgraphs. On replacement (socket already had a
      -- cluster), the recreated nodes reuse the same proxy IDs, making them invisible
      -- to a savedNodeKeys diff. Instead, we traverse spec.subGraphs to find the
      -- subgraph whose parentSocket matches our outer socket, then extract its Socket nodes.
      local nestedSocketIds = {}
      for _, subGraph in pairs(spec.subGraphs) do
        if subGraph.parentSocket and subGraph.parentSocket.id == outerNodeId then
          for _, node in ipairs(subGraph.nodes) do
            if node.type == "Socket" and node.expansionJewel then
              t_insert(nestedSocketIds, node.id)
            end
          end
          break
        end
      end
      table.sort(nestedSocketIds)

      io.stderr:write(string.format("[calc_with_cluster_chain] Found %d nested socket nodes in Large subgraph\n", #nestedSocketIds))

      -- Create and equip each medium directly via spec.jewels
      for i, mt in ipairs(remainingMediums) do
        if i > #nestedSocketIds then
          io.stderr:write(string.format("[calc_with_cluster_chain] No nested socket for medium #%d (only %d available), skipping\n", i, #nestedSocketIds))
          break
        end

        local mParseOk, mediumItem = pcall(new, 'Item', mt)
        if not mParseOk then
          io.stderr:write(string.format("[calc_with_cluster_chain] Failed to parse medium #%d: %s\n", i, tostring(mediumItem)))
        else
          if mediumItem and mediumItem.baseName and mediumItem.type == 'Jewel' then
            mediumItem:NormaliseQuality()
            itemsTab:AddItem(mediumItem, true) -- noAutoEquip
            M._fixClusterJewelValid(mediumItem) -- MUST be after AddItem (which calls BuildModList)
            t_insert(createdItemIds, mediumItem.id)

            -- Direct jewel mapping bypass — spec.jewels is what BuildClusterJewelGraphs reads
            local nestedSocketId = nestedSocketIds[i]
            spec.jewels[nestedSocketId] = mediumItem.id
            equippedMediums = equippedMediums + 1
            io.stderr:write(string.format("[calc_with_cluster_chain] Equipped medium #%d (item %d) in nested socket %d via spec.jewels\n", i, mediumItem.id, nestedSocketId))
          else
            io.stderr:write(string.format("[calc_with_cluster_chain] Medium #%d is not a valid jewel\n", i))
          end
        end
      end

      -- Rebuild cluster subgraphs to create medium subgraphs from the spec.jewels mapping.
      -- CRITICAL: Must call BuildClusterJewelGraphs(), NOT just BuildAllDependsAndPaths().
      -- BuildAllDependsAndPaths only rebuilds depends/paths but does NOT create cluster
      -- subgraphs. BuildClusterJewelGraphs destroys and recreates ALL subgraphs, then
      -- internally calls BuildAllDependsAndPaths. During recreation, it finds the Medium
      -- jewels in spec.jewels[nestedSocketId] and recursively creates Medium subgraphs.
      if equippedMediums > 0 then
        spec:BuildClusterJewelGraphs()
        itemsTab:UpdateSockets()
        build.buildFlag = true
        M.get_main_output()
        io.stderr:write(string.format("[calc_with_cluster_chain] Rebuilt cluster graphs after equipping %d mediums\n", equippedMediums))
      end
    end

    -- 4f. Auto-allocate ALL notables across entire cluster chain
    local allocatedNotableIds = {}
    local totalPointCost = 0
    local allocatedPathNodeIds = {}
    local pathSeen = {}
    local function recordPathNode(id)
      if id and not pathSeen[id] then
        pathSeen[id] = true
        t_insert(allocatedPathNodeIds, id)
      end
    end
    -- Seed with outer-socket travel path captured during step 4a.
    for _, pid in ipairs(socketPathIds) do recordPathNode(pid) end

    if params.autoAllocateNotables then
      -- Find ALL cluster subgraph nodes (both new and rebuilt from replacement).
      -- Cluster subgraph nodes have id >= 0x10000 (65536). We collect all of them
      -- rather than just "new" ones because replacement tests reuse existing IDs.
      local clusterNodes = {}
      for k, node in pairs(spec.nodes) do
        if k >= 0x10000 then
          t_insert(clusterNodes, node)
        end
      end

      -- Find all notables among cluster nodes
      -- Check both node.type == "Notable" and node.isNotable flag (PoB uses both)
      local notables = {}
      for _, node in ipairs(clusterNodes) do
        if node.type == "Notable" or node.isNotable then
          -- Only include notables that are NOT already allocated (avoid re-allocating
          -- notables from other cluster jewels that we're not testing)
          if not spec.allocNodes[node.id] then
            t_insert(notables, node)
          end
        end
      end

      if #notables > 0 then
        io.stderr:write(string.format("[calc_with_cluster_chain] Found %d unallocated notables among %d cluster nodes\n", #notables, #clusterNodes))
      end

      -- BFS from outer socket through ALL cluster nodes (traverses nested sockets too)
      if #notables > 0 then
        for _, notable in ipairs(notables) do
          local visited = {}
          local queue = {}
          local parent = {}
          local socketNode = spec.nodes[outerNodeId]
          if socketNode then
            t_insert(queue, socketNode)
            visited[socketNode.id] = true
            local found = false
            local bfsSteps = 0
            while #queue > 0 and not found do
              local current = table.remove(queue, 1)
              bfsSteps = bfsSteps + 1
              if current.id == notable.id then
                found = true
                break
              end
              if current.linked then
                for _, linked in ipairs(current.linked) do
                  if not visited[linked.id] then
                    -- Traverse through ANY cluster subgraph node or the outer socket.
                    -- We can't filter by savedNodeKeys because replacement tests reuse
                    -- existing subgraph node IDs. Cluster subgraph nodes have id >= 0x10000.
                    local isClusterNode = linked.id >= 0x10000
                    local isNew = not savedNodeKeys[linked.id]
                    local isSelf = linked.id == outerNodeId
                    if isClusterNode or isNew or isSelf then
                      visited[linked.id] = true
                      parent[linked.id] = current.id
                      t_insert(queue, linked)
                    end
                  end
                end
              end
            end

            if found then
              local pathId = notable.id
              while pathId and pathId ~= outerNodeId do
                local pathNode = spec.nodes[pathId]
                if pathNode and not spec.allocNodes[pathId] then
                  pathNode.alloc = true
                  spec.allocNodes[pathId] = pathNode
                  totalPointCost = totalPointCost + 1
                end
                recordPathNode(pathId)
                pathId = parent[pathId]
              end
              t_insert(allocatedNotableIds, notable.id)
            end
          end
        end
      end
    end

    -- 4g. Final rebuild if any nodes were allocated
    if #allocatedNotableIds > 0 then
      build.buildFlag = true
      M.get_main_output()
    end

    -- 4h. Capture afterOutput
    local afterOutput = deepCopySafe(build.calcsTab.mainOutput)

    -- Diagnostic log
    local bDPS = beforeOutput and beforeOutput.CombinedDPS or 0
    local aDPS = afterOutput and afterOutput.CombinedDPS or 0
    io.stderr:write(string.format(
      "[calc_with_cluster_chain] before CombinedDPS=%.1f  after CombinedDPS=%.1f  delta=%.1f  notables=%d  pointCost=%d\n",
      bDPS, aDPS, aDPS - bDPS, #allocatedNotableIds, totalPointCost
    ))

    return {
      beforeOutput = beforeOutput,
      afterOutput = afterOutput,
      allocatedNotables = allocatedNotableIds,
      allocatedPathNodes = allocatedPathNodeIds,
      totalPointCost = totalPointCost + #socketPathIds,
      nestedSocketsUsed = equippedMediums,
    }
  end)

  -- 5. ALWAYS restore state
  restoreState()

  -- 6. Return result or error
  if not ok then
    return nil, tostring(result)
  end
  return result
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
  local conditionEnemyChilled = input.conditionEnemyChilled or false
  local conditionEnemyShocked = input.conditionEnemyShocked or false
  local conditionEnemyCrushed = input.conditionEnemyCrushed or false
  local conditionEnemyBlinded = input.conditionEnemyBlinded or false
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
    buffPhasing = input.buffPhasing or false,
    buffElusive = input.buffElusive or false,
    buffArcaneSurge = input.buffArcaneSurge or false,
    buffFanaticism = input.buffFanaticism or false,
    buffDivinity = input.buffDivinity or false,
    buffConvergence = input.buffConvergence or false,
    conditionUsingFlask = input.conditionUsingFlask or false,

    -- Combat conditions
    conditionLowLife = input.conditionLowLife or false,
    conditionFullLife = input.conditionFullLife or false,
    conditionLowMana = input.conditionLowMana or false,
    conditionFullMana = input.conditionFullMana or false,
    conditionLeeching = input.conditionLeeching or false,
    conditionOnConsecratedGround = input.conditionOnConsecratedGround or false,
    conditionKilledRecently = input.conditionKilledRecently or false,
    conditionHitRecently = input.conditionHitRecently or false,
    conditionCritRecently = input.conditionCritRecently or false,
    conditionBeenHitRecently = input.conditionBeenHitRecently or false,

    -- Enemy conditions
    enemyIsBoss = input.enemyIsBoss or "Pinnacle",
    conditionEnemyIntimidated = input.conditionEnemyIntimidated or false,
    conditionEnemyUnnerved = input.conditionEnemyUnnerved or false,
    conditionEnemyCoveredInAsh = input.conditionEnemyCoveredInAsh or false,
    conditionEnemyCoveredInFrost = input.conditionEnemyCoveredInFrost or false,
    conditionEnemyMaimed = input.conditionEnemyMaimed or false,
    conditionEnemyBleeding = input.conditionEnemyBleeding or false,
    conditionEnemyPoisoned = input.conditionEnemyPoisoned or false,
    conditionEnemyIgnited = input.conditionEnemyIgnited or false,
    conditionEnemyBurning = input.conditionEnemyBurning or false,
    conditionEnemyHindered = input.conditionEnemyHindered or false,
    conditionEnemyTaunted = input.conditionEnemyTaunted or false,
    conditionEnemyDebilitated = input.conditionEnemyDebilitated or false,
    conditionEnemyFireExposure = input.conditionEnemyFireExposure or false,
    conditionEnemyColdExposure = input.conditionEnemyColdExposure or false,
    conditionEnemyLightningExposure = input.conditionEnemyLightningExposure or false,
    conditionEnemyScorched = input.conditionEnemyScorched or false,
    conditionEnemyBrittle = input.conditionEnemyBrittle or false,
    conditionEnemySapped = input.conditionEnemySapped or false,
    conditionEnemyChilled = conditionEnemyChilled,
    conditionEnemyShocked = conditionEnemyShocked,
    conditionEnemyCrushed = conditionEnemyCrushed,
    conditionEnemyBlinded = conditionEnemyBlinded,
    -- Legacy aliases used by older TypeScript surfaces
    enemyIsChilled = conditionEnemyChilled,
    enemyIsShocked = conditionEnemyShocked,
    enemyIsCrushed = conditionEnemyCrushed,
    enemyIsBlinded = conditionEnemyBlinded,

    -- Enemy stats overrides
    enemyFireResist = input.enemyFireResist,
    enemyColdResist = input.enemyColdResist,
    enemyLightningResist = input.enemyLightningResist,
    enemyChaosResist = input.enemyChaosResist,
    enemyPhysicalDamageReduction = input.enemyPhysicalDamageReduction,

    -- Skill-specific numeric vars (set via set_skill_config / set_batch_skill_config)
    multiplierWitheredStackCount = input.multiplierWitheredStackCount or 0,
    conditionShockEffect = input.conditionShockEffect or 0,
    conditionEnemyChilledEffect = input.conditionEnemyChilledEffect or 0,
    conditionScorchedEffect = input.conditionScorchedEffect or 0,
    conditionBrittleEffect = input.conditionBrittleEffect or 0,
    conditionSapEffect = input.conditionSapEffect or 0,
    multiplierPoisonOnEnemy = input.multiplierPoisonOnEnemy or 0,
    multiplierRage = input.multiplierRage or 0,
    multiplierImpalesOnEnemy = input.multiplierImpalesOnEnemy or 0,
    multiplierRuptureStacks = input.multiplierRuptureStacks or 0,
    multiplierCorrosionStackCount = input.multiplierCorrosionStackCount or 0,
    multiplierManaBurnStacks = input.multiplierManaBurnStacks or 0,

    -- Custom modifiers
    customMods = input.customMods or "",
    disabledCurses = input.disabledCurses,
    overrideCurseLimit = input.overrideCurseLimit,
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
  if params.buffPhasing ~= nil then input.buffPhasing = params.buffPhasing; changed = true end
  if params.buffFortification ~= nil then input.buffFortification = params.buffFortification; changed = true end
  if params.overrideFortification ~= nil then input.overrideFortification = tonumber(params.overrideFortification); changed = true end
  if params.buffTailwind ~= nil then input.buffTailwind = params.buffTailwind; changed = true end
  if params.buffAdrenaline ~= nil then input.buffAdrenaline = params.buffAdrenaline; changed = true end
  if params.buffElusive ~= nil then input.buffElusive = params.buffElusive; changed = true end
  if params.buffUnholyMight ~= nil then input.buffUnholyMight = params.buffUnholyMight; changed = true end
  if params.buffPhasing ~= nil then input.buffPhasing = params.buffPhasing; changed = true end
  if params.buffArcaneSurge ~= nil then input.buffArcaneSurge = params.buffArcaneSurge; changed = true end
  if params.buffFanaticism ~= nil then input.buffFanaticism = params.buffFanaticism; changed = true end
  if params.buffDivinity ~= nil then input.buffDivinity = params.buffDivinity; changed = true end
  if params.buffConvergence ~= nil then input.buffConvergence = params.buffConvergence; changed = true end
  if params.conditionUsingFlask ~= nil then input.conditionUsingFlask = params.conditionUsingFlask; changed = true end

  -- Combat conditions
  if params.conditionLowLife ~= nil then input.conditionLowLife = params.conditionLowLife; changed = true end
  if params.conditionFullLife ~= nil then input.conditionFullLife = params.conditionFullLife; changed = true end
  if params.conditionLowMana ~= nil then input.conditionLowMana = params.conditionLowMana; changed = true end
  if params.conditionFullMana ~= nil then input.conditionFullMana = params.conditionFullMana; changed = true end
  if params.conditionLeeching ~= nil then input.conditionLeeching = params.conditionLeeching; changed = true end
  if params.conditionOnConsecratedGround ~= nil then input.conditionOnConsecratedGround = params.conditionOnConsecratedGround; changed = true end
  if params.conditionKilledRecently ~= nil then input.conditionKilledRecently = params.conditionKilledRecently; changed = true end
  if params.conditionHitRecently ~= nil then input.conditionHitRecently = params.conditionHitRecently; changed = true end
  if params.conditionCritRecently ~= nil then input.conditionCritRecently = params.conditionCritRecently; changed = true end
  if params.conditionBeenHitRecently ~= nil then input.conditionBeenHitRecently = params.conditionBeenHitRecently; changed = true end

  -- Enemy conditions
  if params.enemyIsBoss ~= nil then input.enemyIsBoss = tostring(params.enemyIsBoss); changed = true end
  if params.conditionEnemyIntimidated ~= nil then input.conditionEnemyIntimidated = params.conditionEnemyIntimidated; changed = true end
  if params.conditionEnemyUnnerved ~= nil then input.conditionEnemyUnnerved = params.conditionEnemyUnnerved; changed = true end
  if params.conditionEnemyCoveredInAsh ~= nil then input.conditionEnemyCoveredInAsh = params.conditionEnemyCoveredInAsh; changed = true end
  if params.conditionEnemyCoveredInFrost ~= nil then input.conditionEnemyCoveredInFrost = params.conditionEnemyCoveredInFrost; changed = true end
  if params.conditionEnemyMaimed ~= nil then input.conditionEnemyMaimed = params.conditionEnemyMaimed; changed = true end
  if params.conditionEnemyBleeding ~= nil then input.conditionEnemyBleeding = params.conditionEnemyBleeding; changed = true end
  if params.conditionEnemyPoisoned ~= nil then input.conditionEnemyPoisoned = params.conditionEnemyPoisoned; changed = true end
  if params.conditionEnemyIgnited ~= nil then input.conditionEnemyIgnited = params.conditionEnemyIgnited; changed = true end
  if params.conditionEnemyBurning ~= nil then input.conditionEnemyBurning = params.conditionEnemyBurning; changed = true end
  if params.conditionEnemyHindered ~= nil then input.conditionEnemyHindered = params.conditionEnemyHindered; changed = true end
  if params.conditionEnemyTaunted ~= nil then input.conditionEnemyTaunted = params.conditionEnemyTaunted; changed = true end
  if params.conditionEnemyDebilitated ~= nil then input.conditionEnemyDebilitated = params.conditionEnemyDebilitated; changed = true end
  if params.conditionEnemyFireExposure ~= nil then input.conditionEnemyFireExposure = params.conditionEnemyFireExposure; changed = true end
  if params.conditionEnemyColdExposure ~= nil then input.conditionEnemyColdExposure = params.conditionEnemyColdExposure; changed = true end
  if params.conditionEnemyLightningExposure ~= nil then input.conditionEnemyLightningExposure = params.conditionEnemyLightningExposure; changed = true end
  if params.conditionEnemyScorched ~= nil then input.conditionEnemyScorched = params.conditionEnemyScorched; changed = true end
  if params.conditionEnemyBrittle ~= nil then input.conditionEnemyBrittle = params.conditionEnemyBrittle; changed = true end
  if params.conditionEnemySapped ~= nil then input.conditionEnemySapped = params.conditionEnemySapped; changed = true end
  if params.conditionEnemyChilled ~= nil then input.conditionEnemyChilled = params.conditionEnemyChilled; changed = true end
  if params.conditionEnemyShocked ~= nil then input.conditionEnemyShocked = params.conditionEnemyShocked; changed = true end
  if params.conditionEnemyCrushed ~= nil then input.conditionEnemyCrushed = params.conditionEnemyCrushed; changed = true end
  if params.conditionEnemyBlinded ~= nil then input.conditionEnemyBlinded = params.conditionEnemyBlinded; changed = true end
  -- Backward-compat aliases
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

  -- Skill-specific numeric vars
  -- When setting a numeric var to 0, also clear its placeholder so BuildModList
  -- doesn't fall back to the auto-calculated placeholder value.
  local placeholder = build.configTab.configSets
    and build.configTab.configSets[build.configTab.activeConfigSetId]
    and build.configTab.configSets[build.configTab.activeConfigSetId].placeholder
  local function setNumericVar(varName, rawValue)
    local val = tonumber(rawValue)
    input[varName] = val
    if val == 0 and placeholder then placeholder[varName] = nil end
    changed = true
  end
  if params.multiplierWitheredStackCount ~= nil then setNumericVar('multiplierWitheredStackCount', params.multiplierWitheredStackCount) end
  if params.conditionShockEffect ~= nil then setNumericVar('conditionShockEffect', params.conditionShockEffect) end
  if params.conditionEnemyChilledEffect ~= nil then setNumericVar('conditionEnemyChilledEffect', params.conditionEnemyChilledEffect) end
  if params.conditionScorchedEffect ~= nil then setNumericVar('conditionScorchedEffect', params.conditionScorchedEffect) end
  if params.conditionBrittleEffect ~= nil then setNumericVar('conditionBrittleEffect', params.conditionBrittleEffect) end
  if params.conditionSapEffect ~= nil then setNumericVar('conditionSapEffect', params.conditionSapEffect) end
  if params.multiplierPoisonOnEnemy ~= nil then setNumericVar('multiplierPoisonOnEnemy', params.multiplierPoisonOnEnemy) end
  if params.multiplierRage ~= nil then setNumericVar('multiplierRage', params.multiplierRage) end
  if params.multiplierImpalesOnEnemy ~= nil then setNumericVar('multiplierImpalesOnEnemy', params.multiplierImpalesOnEnemy) end
  if params.multiplierRuptureStacks ~= nil then setNumericVar('multiplierRuptureStacks', params.multiplierRuptureStacks) end
  if params.multiplierCorrosionStackCount ~= nil then setNumericVar('multiplierCorrosionStackCount', params.multiplierCorrosionStackCount) end
  if params.multiplierManaBurnStacks ~= nil then setNumericVar('multiplierManaBurnStacks', params.multiplierManaBurnStacks) end

  -- Support gem configs (gems that need config to show real DPS)
  if params.configResonanceCount ~= nil then setNumericVar('configResonanceCount', params.configResonanceCount) end
  if params.configUnholyResonanceCount ~= nil then setNumericVar('configUnholyResonanceCount', params.configUnholyResonanceCount) end
  if params.infusedChannellingInfusion ~= nil then input.infusedChannellingInfusion = params.infusedChannellingInfusion; changed = true end
  if params.intensifyIntensity ~= nil then setNumericVar('intensifyIntensity', params.intensifyIntensity) end
  if params.sigilOfPowerStages ~= nil then setNumericVar('sigilOfPowerStages', params.sigilOfPowerStages) end

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

  -- Preserve ALL input vars across BuildModList().
  -- BuildModList() rebuilds the modifier list from ConfigOptions, which can
  -- reset vars that were set via the API but not explicitly passed in this
  -- set_config call. Snapshot the entire input table before rebuild, then
  -- restore any values that were wiped. Only restore keys that were NOT
  -- explicitly set by THIS call (tracked via the params table).
  local savedInput = {}
  for k, v in pairs(input) do
    savedInput[k] = v
  end

  if changed and build.configTab.BuildModList then build.configTab:BuildModList() end

  -- Restore any input vars that were wiped by BuildModList but were NOT
  -- explicitly changed by this set_config call
  for k, v in pairs(savedInput) do
    if input[k] ~= v and params[k] == nil then
      input[k] = v
    end
  end
  -- Wipe GlobalCache so BuildOutput() recalculates with updated config
  -- (e.g. customMods changing resistances must invalidate cached EHP)
  build.buildFlag = true
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
            -- Attribute requirements (use reqOverride when available, matching CalcSetup behavior)
            reqStr = (gem.reqOverride or gem.reqStr) and (gem.reqOverride or gem.reqStr) > 0 and (gem.reqOverride or gem.reqStr) or nil,
            reqDex = (gem.reqOverride or gem.reqDex) and (gem.reqOverride or gem.reqDex) > 0 and (gem.reqOverride or gem.reqDex) or nil,
            reqInt = (gem.reqOverride or gem.reqInt) and (gem.reqOverride or gem.reqInt) > 0 and (gem.reqOverride or gem.reqInt) or nil,
          })
        end
      end
    end

    table.insert(groups, {
      index = idx,
      label = g.label,
      slot = g.slot,
      source = g.source,
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
      -- Auto-activate flasks when equipped via API (matches add_items_batch behavior)
      if slot:match('^Flask %d$') and build.itemsTab.activeItemSet
          and build.itemsTab.activeItemSet[slot] then
        build.itemsTab.activeItemSet[slot].active = true
        build.itemsTab.slots[slot].active = true
        if build.itemsTab.slots[slot].controls and build.itemsTab.slots[slot].controls.activate then
          build.itemsTab.slots[slot].controls.activate.state = true
        end
      end
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
          -- Also update the slot control — calc engine reads slot.active
          if build.itemsTab.slots[slot] then
            build.itemsTab.slots[slot].active = true
            if build.itemsTab.slots[slot].controls and build.itemsTab.slots[slot].controls.activate then
              build.itemsTab.slots[slot].controls.activate.state = true
            end
          end
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
  -- Also update the slot control — the calc engine reads slot.active, not activeItemSet
  if build.itemsTab.slots[slotName] then
    build.itemsTab.slots[slotName].active = active
    if build.itemsTab.slots[slotName].controls and build.itemsTab.slots[slotName].controls.activate then
      build.itemsTab.slots[slotName].controls.activate.state = active
    end
  end
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
  local addedItemIds = {}
  local function append_item(slotName, itemId, activeSlotName)
    if not itemId or itemId <= 0 or addedItemIds[itemId] then return nil end
    local it = itemsTab.items[itemId]
    if not it then return nil end

    local entry = {
      slot = slotName,
      id = itemId,
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
          if it.rarity == "UNIQUE" or it.rarity == "RELIC" then
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
          if it.rarity == "UNIQUE" or it.rarity == "RELIC" then
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

    -- Requirements (use modified values that account for requirement-reducing mods,
    -- matching what CalcSetup uses for env.requirementsTableItems)
    if it.requirements then
      local strReq = it.requirements.strMod or it.requirements.str or 0
      local dexReq = it.requirements.dexMod or it.requirements.dex or 0
      local intReq = it.requirements.intMod or it.requirements.int or 0
      entry.requirements = {
        level = it.requirements.level,
        str = strReq > 0 and strReq or nil,
        dex = dexReq > 0 and dexReq or nil,
        int = intReq > 0 and intReq or nil,
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

    -- Weapon stats (physical/elemental/chaos damage, crit, APS, DPS)
    if it.weaponData then
      -- Determine slotNum from slot name: "Weapon 2"/"Weapon 2 Swap" → 2, else 1
      local slotNum = (slotName and slotName:match("Weapon 2")) and 2 or 1
      local wd = it.weaponData[slotNum]
      if wd then
        entry.weaponData = {
          physicalMin = wd.PhysicalMin,
          physicalMax = wd.PhysicalMax,
          physicalDPS = wd.PhysicalDPS,
          elementalDPS = wd.ElementalDPS,
          chaosDPS = wd.ChaosDPS,
          totalDPS = wd.TotalDPS,
          critChance = wd.CritChance,
          attackRate = wd.AttackRate,
          range = wd.range,
          -- Elemental breakdown
          fireMin = wd.FireMin, fireMax = wd.FireMax,
          coldMin = wd.ColdMin, coldMax = wd.ColdMax,
          lightningMin = wd.LightningMin, lightningMax = wd.LightningMax,
          chaosMin = wd.ChaosMin, chaosMax = wd.ChaosMax,
        }
      end
    end

    -- Flask recovery stats (life, mana, duration, charges)
    if it.flaskData then
      entry.flaskData = {
        lifeTotal = it.flaskData.lifeTotal,
        lifeGradual = it.flaskData.lifeGradual,
        lifeInstant = it.flaskData.lifeInstant,
        manaTotal = it.flaskData.manaTotal,
        manaGradual = it.flaskData.manaGradual,
        manaInstant = it.flaskData.manaInstant,
        duration = it.flaskData.duration,
        chargesMax = it.flaskData.chargesMax,
        chargesUsed = it.flaskData.chargesUsed,
        instantPerc = it.flaskData.instantPerc,
      }
    end

    -- Flask/Tincture activation flag stored in activeItemSet
    local set = itemsTab.activeItemSet
    if activeSlotName and set and set[activeSlotName] and set[activeSlotName].active ~= nil then
      entry.active = set[activeSlotName].active and true or false
    end

    table.insert(result, entry)
    addedItemIds[itemId] = true
    return entry
  end
  local function add_slot(slotName)
    if seen[slotName] then return end
    seen[slotName] = true
    local slotCtrl = itemsTab.slots[slotName]
    if not slotCtrl then return end
    local selId = slotCtrl.selItemId or 0
    -- Only include slots with equipped items
    if selId > 0 then
      append_item(slotName, selId, slotName)
    end
  end
  -- DEBUG: Log orderedSlots flask entries
  for i, slot in ipairs(ordered) do
    if slot and slot.slotName and slot.slotName:find("Flask") then
      local slotCtrl = itemsTab.slots[slot.slotName]
      local selId = slotCtrl and slotCtrl.selItemId or 0
      io.stderr:write(string.format("[get_items] orderedSlot[%d] slotName=%s selItemId=%d\n", i, slot.slotName, selId))
    end
  end
  for _, slot in ipairs(ordered) do
    if slot and slot.slotName then add_slot(slot.slotName) end
  end
  -- Add any remaining slots not in ordered list
  for slotName, _ in pairs(itemsTab.slots or {}) do add_slot(slotName) end
  local spec = build.spec or {}
  if spec.jewels then
    for nodeId, itemId in pairs(spec.jewels) do
      local entry = append_item("Jewel " .. tostring(nodeId), itemId, nil)
      if entry then
        entry.socketNodeId = tonumber(nodeId) or nodeId
      end
    end
  end
  return result
end

-- Extract attribute requirement sources from PoB's authoritative requirementsTable.
-- Must be called AFTER get_full_calcs() which triggers BuildOutput() and populates mainEnv.
-- Returns per-attribute sources matching what PoB internally uses for ReqStr/ReqDex/ReqInt.
function M.get_attribute_requirements()
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  local mainEnv = build.calcsTab.mainEnv
  if not mainEnv then
    return nil, 'calculations not available (call get_full_calcs first)'
  end

  local mainOutput = build.calcsTab.mainOutput or {}

  -- Build per-attribute source lists from the authoritative requirementsTable
  local reqTable = {}
  -- Merge items and gems tables (same structure CalcPerform uses)
  if mainEnv.requirementsTableItems then
    for _, entry in ipairs(mainEnv.requirementsTableItems) do
      t_insert(reqTable, entry)
    end
  end
  if mainEnv.requirementsTableGems then
    for _, entry in ipairs(mainEnv.requirementsTableGems) do
      t_insert(reqTable, entry)
    end
  end
  -- Also check the merged table if it exists
  if #reqTable == 0 and mainEnv.requirementsTable then
    reqTable = mainEnv.requirementsTable
  end

  local sources = { str = {}, dex = {}, int = {} }

  for _, reqSource in ipairs(reqTable) do
    for _, attr in ipairs({"Str", "Dex", "Int"}) do
      local val = reqSource[attr]
      if val and val > 0 then
        local entry = { requirement = val }
        if reqSource.source == "Item" then
          entry.type = "item"
          if reqSource.sourceItem then
            entry.name = reqSource.sourceItem.name or "Unknown Item"
          else
            entry.name = "Unknown Item"
          end
          entry.slot = reqSource.sourceSlot or "Unknown"
        elseif reqSource.source == "Gem" then
          entry.type = "gem"
          if reqSource.sourceGem then
            entry.name = reqSource.sourceGem.nameSpec or "Unknown Gem"
          else
            entry.name = "Unknown Gem"
          end
          -- Try to find the slot from the gem's socket group
          entry.slot = "Gem"
        else
          entry.type = "unknown"
          entry.name = "Unknown"
          entry.slot = "Unknown"
        end
        t_insert(sources[attr:lower()], entry)
      end
    end
  end

  -- Check for special flags that affect requirement interpretation
  local modDB = mainEnv.modDB
  local ignoreAttrReq = modDB and modDB:Flag(nil, "IgnoreAttributeRequirements") or false
  local omniRequirements = modDB and modDB:Flag(nil, "OmniscienceRequirements") or false

  return {
    str = {
      current = mainOutput.Str or 0,
      required = mainOutput.ReqStr or 0,
      sources = sources.str,
    },
    dex = {
      current = mainOutput.Dex or 0,
      required = mainOutput.ReqDex or 0,
      sources = sources.dex,
    },
    int = {
      current = mainOutput.Int or 0,
      required = mainOutput.ReqInt or 0,
      sources = sources.int,
    },
    -- Flags that affect requirement interpretation
    ignoreAttrReq = ignoreAttrReq or nil,  -- Supreme Ostentation: all requirements ignored
    omniRequirements = omniRequirements or nil,  -- Crystallised Omniscience: requirements converted to Omni
  }
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
    enableGlobal2 = true,
    count = tonumber(params.count) or 1,
  }

  -- Try to find gem data (handle with/without " Support" suffix mismatch)
  local altNameSpec = nil
  if gemInstance.nameSpec:sub(-8) == " Support" then
    altNameSpec = gemInstance.nameSpec:sub(1, -9)
  else
    altNameSpec = gemInstance.nameSpec .. " Support"
  end
  if build.data and build.data.gems then
    for _, gemData in pairs(build.data.gems) do
      if gemData.name == gemInstance.nameSpec or gemData.nameSpec == gemInstance.nameSpec
         or gemData.name == altNameSpec or gemData.nameSpec == altNameSpec then
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

-- Set whether a gem is enabled (destructive — persists until reload)
-- params: { groupIndex: number, gemIndex: number, enabled: boolean }
function M.set_gem_enabled(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  if not params.groupIndex or not params.gemIndex then
    return nil, 'missing groupIndex or gemIndex'
  end
  if params.enabled == nil then return nil, 'missing enabled' end

  local skillSetId = build.skillsTab.activeSkillSetId or 1
  local skillSet = build.skillsTab.skillSets[skillSetId]
  if not skillSet then return nil, 'active skill set not found' end

  local groupIndex = tonumber(params.groupIndex)
  local gemIndex = tonumber(params.gemIndex)

  local socketGroup = skillSet.socketGroupList[groupIndex]
  if not socketGroup then return nil, 'socket group not found at index ' .. tostring(groupIndex) end

  local gemInstance = socketGroup.gemList and socketGroup.gemList[gemIndex]
  if not gemInstance then return nil, 'gem not found at index ' .. tostring(gemIndex) end

  gemInstance.enabled = params.enabled == true

  if build.skillsTab.ProcessSocketGroup then
    build.skillsTab:ProcessSocketGroup(socketGroup)
  end

  build.buildFlag = true
  M.get_main_output()

  return {
    groupIndex = groupIndex,
    gemIndex = gemIndex,
    gemName = gemInstance.nameSpec,
    enabled = gemInstance.enabled,
  }
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
      if node.ascendancyName then nType = 'ascendancy'
      elseif node.isKeystone then nType = 'keystone'
      elseif node.isNotable then nType = 'notable'
      elseif node.isJewelSocket then nType = 'jewel'
      elseif node.isMultipleChoiceOption then nType = 'mastery'
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
      if node.ascendancyName then nodeType = 'ascendancy'
      elseif node.isKeystone then nodeType = 'keystone'
      elseif node.isNotable then nodeType = 'notable'
      elseif node.isJewelSocket then nodeType = 'jewel'
      elseif node.isMultipleChoiceOption then nodeType = 'mastery'
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

  -- Set the config variable directly.
  -- When value is 0 for "count" type configs, also clear the placeholder.
  -- BuildModList skips input[var] when it's 0 (for non-countAllowZero types)
  -- and falls through to placeholder[var], which may have a non-zero auto-calculated
  -- value. Clearing the placeholder ensures value=0 truly disables the config.
  input[params.varName] = params.value
  if params.value == 0 then
    local placeholder = build.configTab.configSets
      and build.configTab.configSets[build.configTab.activeConfigSetId]
      and build.configTab.configSets[build.configTab.activeConfigSetId].placeholder
    if placeholder then
      placeholder[params.varName] = nil
    end
  end

  -- Rebuild mod list and recalculate
  if build.configTab.BuildModList then
    build.configTab:BuildModList()
  end
  -- Wipe GlobalCache so BuildOutput() recalculates with updated config
  build.buildFlag = true
  M.get_main_output()

  return { ok = true, varName = params.varName, value = params.value }
end

-- Batch set multiple skill-specific config variables in one call, rebuild once
-- params: { configs: { { varName: string, value: any }, ... } }
function M.set_batch_skill_config(params)
  if not build or not build.configTab then
    return nil, 'build/config not initialized'
  end
  if type(params) ~= 'table' or type(params.configs) ~= 'table' then
    return nil, 'invalid params: expected { configs: [...] }'
  end

  local input = build.configTab.input or {}
  build.configTab.input = input
  local applied = {}

  local placeholder = build.configTab.configSets
    and build.configTab.configSets[build.configTab.activeConfigSetId]
    and build.configTab.configSets[build.configTab.activeConfigSetId].placeholder

  for _, entry in ipairs(params.configs) do
    if type(entry.varName) == 'string' and entry.varName ~= '' and entry.value ~= nil then
      input[entry.varName] = entry.value
      -- Clear placeholder when value=0 so BuildModList doesn't fall back to it
      if entry.value == 0 and placeholder then
        placeholder[entry.varName] = nil
      end
      applied[#applied + 1] = { varName = entry.varName, value = entry.value }
    end
  end

  -- Rebuild once after all vars are set
  if #applied > 0 then
    if build.configTab.BuildModList then
      build.configTab:BuildModList()
    end
    -- Wipe GlobalCache so BuildOutput() recalculates with updated config
    build.buildFlag = true
    M.get_main_output()
  end

  return { ok = true, applied = applied, count = #applied }
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

  -- Iterate through live socket controls (jewel sockets in the current tree).
  -- itemsTab.sockets can retain stale controls from destroyed cluster subgraphs;
  -- those node IDs are not present in spec.nodes and must be ignored.
  for nodeId, socketCtrl in pairs(itemsTab.sockets) do
    local node = spec.nodes[nodeId]
    if node then
      local isAllocated = spec.allocNodes[nodeId] ~= nil
      local equippedJewelId = spec.jewels[nodeId] or 0
      local equippedJewel = nil
      local clusterSocketSize = node.expansionJewel and tonumber(node.expansionJewel.size) or nil

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
        acceptsClusterJewel = clusterSocketSize ~= nil,
        clusterSocketSize = clusterSocketSize,
        isSubgraphSocket = nodeId >= 0x10000,
        -- Include node position for reference
        x = node.x,
        y = node.y,
      })
    end
  end

  -- Sort by nodeId for consistent ordering
  table.sort(result, function(a, b) return a.nodeId < b.nodeId end)

  return result
end

-- Debug helper: inspect the live passive node state PoB is using for a specific node.
-- params: { nodeId: number }
function M.get_tree_node_debug(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= "table" then
    return nil, "invalid params"
  end

  local nodeId = tonumber(params.nodeId)
  if not nodeId then
    return nil, "missing or invalid nodeId"
  end

  local spec = build.spec
  local function summarizeNode(node)
    if not node then
      return nil
    end

    local stats = {}
    if type(node.sd) == "table" then
      for _, stat in ipairs(node.sd) do
        if type(stat) == "string" then
          table.insert(stats, stat)
        end
      end
    end

    local conqueredBy = nil
    if type(node.conqueredBy) == "table" then
      conqueredBy = {
        id = node.conqueredBy.id,
        conqueror = node.conqueredBy.conqueror and {
          type = node.conqueredBy.conqueror.type,
          id = node.conqueredBy.conqueror.id,
        } or nil,
      }
    end

    return {
      id = node.id,
      dn = node.dn,
      name = node.name,
      icon = node.icon,
      activeEffectImage = node.activeEffectImage,
      type = node.type,
      alloc = node.alloc == true,
      isKeystone = node.isKeystone == true,
      isNotable = node.isNotable == true,
      stats = stats,
      reminderText = node.reminderText,
      conqueredBy = conqueredBy,
    }
  end

  local influencingJewels = {}
  for socketNodeId, itemId in pairs(spec.jewels or {}) do
    local item = build.itemsTab and build.itemsTab.items and build.itemsTab.items[itemId] or nil
    local socketNode = spec.nodes[socketNodeId]
    local radiusIndex = item and item.jewelRadiusIndex or nil
    local inRadius = false

    if socketNode and socketNode.nodesInRadius and radiusIndex and socketNode.nodesInRadius[radiusIndex] then
      inRadius = socketNode.nodesInRadius[radiusIndex][nodeId] ~= nil
    end

    if inRadius or socketNodeId == nodeId then
      table.insert(influencingJewels, {
        socketNodeId = socketNodeId,
        itemId = itemId,
        name = item and item.name or nil,
        baseName = item and item.baseName or nil,
        radiusIndex = radiusIndex,
        jewelData = item and item.jewelData and {
          conqueredBy = item.jewelData.conqueredBy,
          timelessJewel = item.jewelData.conqueredBy ~= nil,
          impossibleEscapeKeystone = item.jewelData.impossibleEscapeKeystone,
          intuitiveLeapLike = item.jewelData.intuitiveLeapLike == true,
        } or nil,
      })
    end
  end

  return {
    nodeId = nodeId,
    specNode = summarizeNode(spec.nodes and spec.nodes[nodeId] or nil),
    allocNode = summarizeNode(spec.allocNodes and spec.allocNodes[nodeId] or nil),
    treeNode = summarizeNode(spec.tree and spec.tree.nodes and spec.tree.nodes[nodeId] or nil),
    influencingJewels = influencingJewels,
  }
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

  -- If the socket node is not allocated, allocate it first.
  -- When autoAllocateSocketPath is set, path from the class start to the socket
  -- (mirrors calc_with_jewel's behavior) so the socket is reachable from the
  -- live tree instead of appearing as a disconnected node.
  if not spec.allocNodes[nodeId] then
    local current = M.get_tree()
    if not current then
      return nil, "failed to get current tree"
    end

    local newNodeSet = {}
    for _, id in ipairs(current.nodes) do
      newNodeSet[tonumber(id)] = true
    end

    if params.autoAllocateSocketPath then
      local pathResult, pathErr = M.find_path({ targetNodeId = nodeId })
      if not pathResult then
        return nil, "failed to path to socket " .. tostring(nodeId) .. ": " .. tostring(pathErr)
      end
      for _, pathNode in ipairs(pathResult.path or {}) do
        if pathNode and pathNode.id then
          newNodeSet[tonumber(pathNode.id)] = true
        end
      end
    end

    newNodeSet[nodeId] = true
    local newNodes = {}
    for id, _ in pairs(newNodeSet) do table.insert(newNodes, id) end
    table.sort(newNodes)

    spec:ImportFromNodeList(
      current.classId or 0,
      current.ascendClassId or 0,
      current.secondaryAscendClassId or 0,
      newNodes,
      {},
      current.masteryEffects or {}
    )

    itemsTab:UpdateSockets()
  end

  -- Snapshot existing node keys BEFORE equipping the jewel so the BFS below can
  -- distinguish the new cluster subgraph nodes from the base tree. Only needed
  -- when autoAllocateNotables is set for a cluster jewel.
  local savedNodeKeys = nil
  if params.autoAllocateNotables then
    savedNodeKeys = {}
    for k, _ in pairs(spec.nodes) do savedNodeKeys[k] = true end
  end

  local itemId = nil
  local item = nil

  -- If text is provided, create the item first
  if params.text then
    if #params.text == 0 then
      return nil, "item text cannot be empty"
    end
    if #params.text > MAX_ITEM_TEXT_LENGTH then
      return nil, string.format("item text too long (max %d bytes)", MAX_ITEM_TEXT_LENGTH)
    end

    local ok, parsedItem = pcall(new, 'Item', params.text)
    if not ok then
      return nil, "invalid item text: " .. tostring(parsedItem)
    end
    if not parsedItem or not parsedItem.baseName then
      return nil, "failed to parse item"
    end

    -- Verify it's a jewel
    if parsedItem.type ~= "Jewel" then
      return nil, "item is not a jewel (type: " .. tostring(parsedItem.type) .. ")"
    end

    parsedItem:NormaliseQuality()
    itemsTab:AddItem(parsedItem, true) -- noAutoEquip = true
    itemId = parsedItem.id
    item = parsedItem

    -- Fix clusterJewelValid for multi-enchant bases (Claw+Dagger, Bow, etc.).
    -- parseMod can't resolve clusterJewelSkill from concatenated keys for those
    -- bases; the "Cluster Jewel Skill:" metadata header (injected by the
    -- TypeScript layer) sets item.clusterJewelSkill. Copy it into jewelData
    -- so BuildClusterJewelGraphs will create the subgraph. MUST run after
    -- AddItem (which calls BuildModList, recreating jewelData) and BEFORE
    -- BuildClusterJewelGraphs.
    M._fixClusterJewelValid(item)

  elseif params.itemId then
    -- Use existing item by ID
    itemId = tonumber(params.itemId)
    if not itemId or not itemsTab.items[itemId] then
      return nil, "invalid itemId or item not found"
    end
    item = itemsTab.items[itemId]
  else
    return nil, "must provide either text or itemId"
  end

  -- Equip the jewel to the socket.
  local slotName = socketCtrl.slotName
  socketCtrl:SetSelItemId(itemId)
  itemsTab:PopulateSlots()

  -- For cluster jewels, explicitly call BuildClusterJewelGraphs().
  -- SetSelItemId + get_main_output() do NOT create cluster subgraphs on their
  -- own (get_main_output runs wipeGlobalCache + BuildOutput, which rebuilds
  -- calcs but never touches spec.subGraphs). Without this call the cluster
  -- equips but its notables and small-passive grants are not added to the
  -- tree — the silent-zero-delta bug from the 2026-04-15 combined-package
  -- session (CP11 = GS2 + TR8 + GR11 numbers identical to GS2 + GR11).
  if item and item.clusterJewel then
    spec:BuildClusterJewelGraphs()
  end

  build.buildFlag = true
  M.get_main_output()

  -- Auto-allocate cluster notables when requested. Mirrors the BFS in
  -- calc_with_jewel (step 4e): discover newly-created subgraph notables and
  -- allocate a path from the outer socket to each one.
  local allocatedNotableIds = nil
  if params.autoAllocateNotables and item and item.clusterJewel and savedNodeKeys then
    local newNodes = {}
    for k, node in pairs(spec.nodes) do
      if not savedNodeKeys[k] then
        table.insert(newNodes, node)
      end
    end

    local notables = {}
    for _, node in ipairs(newNodes) do
      if node.type == "Notable" or node.isNotable then
        table.insert(notables, node)
      end
    end

    if #notables > 0 then
      allocatedNotableIds = {}
      for _, notable in ipairs(notables) do
        local visited = {}
        local queue = {}
        local parent = {}
        local socketNode = spec.nodes[nodeId]
        if socketNode then
          table.insert(queue, socketNode)
          visited[socketNode.id] = true
          local found = false
          while #queue > 0 and not found do
            local current = table.remove(queue, 1)
            if current.id == notable.id then
              found = true
              break
            end
            if current.linked then
              for _, linked in ipairs(current.linked) do
                if not visited[linked.id] then
                  if not savedNodeKeys[linked.id] or linked.id == nodeId then
                    visited[linked.id] = true
                    parent[linked.id] = current.id
                    table.insert(queue, linked)
                  end
                end
              end
            end
          end

          if found then
            local pathId = notable.id
            while pathId and pathId ~= nodeId do
              local pathNode = spec.nodes[pathId]
              if pathNode and not spec.allocNodes[pathId] then
                pathNode.alloc = true
                spec.allocNodes[pathId] = pathNode
              end
              pathId = parent[pathId]
            end
            table.insert(allocatedNotableIds, notable.id)
          end
        end
      end

      if #allocatedNotableIds > 0 then
        build.buildFlag = true
        M.get_main_output()
      end
    end
  end

  itemsTab:AddUndoState()

  return {
    nodeId = nodeId,
    slotName = slotName,
    itemId = itemId,
    name = item and item.name or nil,
    baseName = item and item.baseName or nil,
    allocatedNotables = allocatedNotableIds,
  }
end

-- Persistent variant of calc_with_cluster_chain: equips a Large cluster (+
-- optional nested Mediums) in an outer socket and leaves the state mutated.
-- Used by combined-package testing in test-combined-changes.ts, where tree
-- and gear mutations already run persistently on the same container.
function M.set_cluster_chain(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end

  local outerNodeId = tonumber(params.outerSocketNodeId)
  if not outerNodeId then return nil, 'missing or invalid outerSocketNodeId' end

  local largeText = params.largeJewelText
  local mediumTexts = params.mediumJewelTexts or {}

  local hasLarge = type(largeText) == 'string' and #largeText > 0
  local hasMedium = type(mediumTexts) == 'table' and #mediumTexts > 0
  if not hasLarge and not hasMedium then
    return nil, 'need at least one of largeJewelText or mediumJewelTexts'
  end

  if hasLarge and #largeText > MAX_ITEM_TEXT_LENGTH then
    return nil, string.format('largeJewelText too long (max %d bytes)', MAX_ITEM_TEXT_LENGTH)
  end
  if hasMedium then
    for i, mt in ipairs(mediumTexts) do
      if type(mt) ~= 'string' or #mt == 0 then
        return nil, 'mediumJewelTexts[' .. tostring(i) .. '] is empty or not a string'
      end
      if #mt > MAX_ITEM_TEXT_LENGTH then
        return nil, string.format('mediumJewelTexts[%d] too long (max %d bytes)', i, MAX_ITEM_TEXT_LENGTH)
      end
    end
  end

  local spec = build.spec
  local itemsTab = build.itemsTab

  local outerSocketCtrl = itemsTab.sockets[outerNodeId]
  if not outerSocketCtrl then
    return nil, 'outerSocketNodeId ' .. tostring(outerNodeId) .. ' is not a jewel socket'
  end

  -- Path to outer socket if unallocated
  if not spec.allocNodes[outerNodeId] then
    local current = M.get_tree()
    if not current then return nil, 'failed to get current tree' end
    local newNodeSet = {}
    for _, id in ipairs(current.nodes) do
      newNodeSet[tonumber(id)] = true
    end

    if params.autoAllocateSocketPath then
      local pathResult, pathErr = M.find_path({ targetNodeId = outerNodeId })
      if not pathResult then
        return nil, 'failed to path to socket ' .. tostring(outerNodeId) .. ': ' .. tostring(pathErr)
      end
      for _, pathNode in ipairs(pathResult.path or {}) do
        if pathNode and pathNode.id then
          newNodeSet[tonumber(pathNode.id)] = true
        end
      end
    end

    newNodeSet[outerNodeId] = true
    local newNodes = {}
    for id, _ in pairs(newNodeSet) do table.insert(newNodes, id) end
    table.sort(newNodes)
    spec:ImportFromNodeList(
      current.classId or 0,
      current.ascendClassId or 0,
      current.secondaryAscendClassId or 0,
      newNodes,
      {},
      current.masteryEffects or {}
    )
    itemsTab:UpdateSockets()
  end

  -- Snapshot node keys BEFORE any cluster subgraph creation. Needed so the BFS
  -- below can see which nodes were created by this chain versus pre-existing
  -- subgraph nodes from OTHER cluster jewels already on the build.
  local savedNodeKeys = {}
  for k, _ in pairs(spec.nodes) do savedNodeKeys[k] = true end

  -- Choose primary: Large if present, else first Medium (Medium-only mode)
  local primaryText = nil
  local remainingMediums = {}
  if hasLarge then
    primaryText = largeText
    for i, mt in ipairs(mediumTexts) do
      table.insert(remainingMediums, mt)
    end
  else
    primaryText = mediumTexts[1]
    for i = 2, #mediumTexts do
      table.insert(remainingMediums, mediumTexts[i])
    end
  end

  -- Create primary
  local parseOk, primaryItem = pcall(new, 'Item', primaryText)
  if not parseOk then return nil, 'invalid primary jewel text: ' .. tostring(primaryItem) end
  if not primaryItem or not primaryItem.baseName then return nil, 'failed to parse primary jewel' end
  if primaryItem.type ~= 'Jewel' then return nil, 'primary item is not a jewel (type: ' .. tostring(primaryItem.type) .. ')' end

  primaryItem:NormaliseQuality()
  itemsTab:AddItem(primaryItem, true)

  -- Equip primary via spec.jewels bypass (same pattern as calc_with_cluster_chain).
  -- SetSelItemId would call BuildClusterJewelGraphs internally, which calls
  -- BuildModList on items and wipes jewelData. _fixClusterJewelValid must run
  -- AFTER AddItem and BEFORE BuildClusterJewelGraphs.
  spec.jewels[outerNodeId] = primaryItem.id
  outerSocketCtrl.selItemId = primaryItem.id
  M._fixClusterJewelValid(primaryItem)
  spec:BuildClusterJewelGraphs()
  itemsTab:UpdateSockets()
  itemsTab:PopulateSlots()
  build.buildFlag = true
  M.get_main_output()

  -- Equip mediums in nested sockets (only when primary is Large)
  local equippedMediums = 0
  if hasLarge and #remainingMediums > 0 then
    -- Discover nested sockets via subGraph traversal (not savedNodeKeys diff —
    -- BuildClusterJewelGraphs destroys/recreates subgraphs so replacement
    -- clusters reuse proxy IDs).
    local nestedSocketIds = {}
    for _, subGraph in pairs(spec.subGraphs) do
      if subGraph.parentSocket and subGraph.parentSocket.id == outerNodeId then
        for _, node in ipairs(subGraph.nodes) do
          if node.type == "Socket" and node.expansionJewel then
            table.insert(nestedSocketIds, node.id)
          end
        end
        break
      end
    end
    table.sort(nestedSocketIds)

    for i, mt in ipairs(remainingMediums) do
      if i > #nestedSocketIds then break end
      local mOk, mediumItem = pcall(new, 'Item', mt)
      if mOk and mediumItem and mediumItem.baseName and mediumItem.type == 'Jewel' then
        mediumItem:NormaliseQuality()
        itemsTab:AddItem(mediumItem, true)
        M._fixClusterJewelValid(mediumItem)
        spec.jewels[nestedSocketIds[i]] = mediumItem.id
        equippedMediums = equippedMediums + 1
      end
    end

    if equippedMediums > 0 then
      spec:BuildClusterJewelGraphs()
      itemsTab:UpdateSockets()
      build.buildFlag = true
      M.get_main_output()
    end
  end

  -- Auto-allocate notables across the entire chain via BFS from outer socket.
  local allocatedNotableIds = {}
  local totalPointCost = 0

  if params.autoAllocateNotables then
    -- Gather all cluster subgraph nodes (id >= 0x10000).
    local clusterNodes = {}
    for k, node in pairs(spec.nodes) do
      if k >= 0x10000 then
        table.insert(clusterNodes, node)
      end
    end

    local notables = {}
    for _, node in ipairs(clusterNodes) do
      if (node.type == "Notable" or node.isNotable) and not spec.allocNodes[node.id] then
        table.insert(notables, node)
      end
    end

    for _, notable in ipairs(notables) do
      local visited = {}
      local queue = {}
      local parent = {}
      local socketNode = spec.nodes[outerNodeId]
      if socketNode then
        table.insert(queue, socketNode)
        visited[socketNode.id] = true
        local found = false
        while #queue > 0 and not found do
          local current = table.remove(queue, 1)
          if current.id == notable.id then
            found = true
            break
          end
          if current.linked then
            for _, linked in ipairs(current.linked) do
              if not visited[linked.id] then
                local isClusterNode = linked.id >= 0x10000
                local isNew = not savedNodeKeys[linked.id]
                local isSelf = linked.id == outerNodeId
                if isClusterNode or isNew or isSelf then
                  visited[linked.id] = true
                  parent[linked.id] = current.id
                  table.insert(queue, linked)
                end
              end
            end
          end
        end

        if found then
          local pathId = notable.id
          while pathId and pathId ~= outerNodeId do
            local pathNode = spec.nodes[pathId]
            if pathNode and not spec.allocNodes[pathId] then
              pathNode.alloc = true
              spec.allocNodes[pathId] = pathNode
              totalPointCost = totalPointCost + 1
            end
            pathId = parent[pathId]
          end
          table.insert(allocatedNotableIds, notable.id)
        end
      end
    end

    if #allocatedNotableIds > 0 then
      build.buildFlag = true
      M.get_main_output()
    end
  end

  itemsTab:AddUndoState()

  return {
    outerNodeId = outerNodeId,
    primaryItemId = primaryItem.id,
    allocatedNotables = allocatedNotableIds,
    totalPointCost = totalPointCost,
    nestedSocketsUsed = equippedMediums,
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
      local liveNode = (spec.nodes and spec.nodes[nodeIdInRadius]) or (spec.allocNodes and spec.allocNodes[nodeIdInRadius]) or node

      -- Determine node type
      local nodeType = "normal"
      if liveNode.isKeystone then
        nodeType = "keystone"
      elseif liveNode.isNotable then
        nodeType = "notable"
      elseif liveNode.isJewelSocket then
        nodeType = "jewel"
      elseif liveNode.isMastery then
        nodeType = "mastery"
      end

      -- Check if node is allocated
      local isAllocated = spec.allocNodes[nodeIdInRadius] ~= nil

      -- Get node stats
      local stats = {}
      if liveNode.sd then
        for _, stat in ipairs(liveNode.sd) do
          table.insert(stats, stat)
        end
      end

      table.insert(radiusResult.nodes, {
        id = nodeIdInRadius,
        name = liveNode.dn or liveNode.name or "Unknown",
        type = nodeType,
        isAllocated = isAllocated,
        stats = stats,
        icon = liveNode.icon,
        activeEffectImage = liveNode.activeEffectImage,
        reminderText = liveNode.reminderText,
        x = liveNode.x,
        y = liveNode.y,
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

-- Get flask uptime data for all equipped flasks
-- Mirrors the uptime calculation from ItemsTab.lua tooltip (lines ~3754-3938)
function M.get_flask_uptime_data()
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if not build.calcsTab or not build.calcsTab.mainEnv then return nil, 'calcs not initialized' end

  local itemsTab = build.itemsTab
  local modDB = build.calcsTab.mainEnv.modDB
  local calcOutput = build.calcsTab.mainOutput
  if not modDB or not calcOutput then return nil, 'modDB or output not available' end

  local m_min = math.min
  local m_floor = math.floor
  local result = {}

  for idx = 1, NUM_FLASK_SLOTS do
    local slotName = 'Flask ' .. tostring(idx)
    local slotCtrl = itemsTab.slots[slotName]
    if slotCtrl and slotCtrl.selItemId and slotCtrl.selItemId > 0 then
      local item = itemsTab.items[slotCtrl.selItemId]
      if item and item.base and item.base.flask and item.flaskData then
        local ok2, entry = pcall(function()
          local flaskData = item.flaskData
          local durInc = modDB:Sum("INC", nil, "FlaskDuration")
          local effectInc = modDB:Sum("INC", { actor = "player" }, "FlaskEffect")

          if item.rarity == "MAGIC" and not item.base.flask.life and not item.base.flask.mana then
            effectInc = effectInc + modDB:Sum("INC", { actor = "player" }, "MagicUtilityFlaskEffect")
          end

          -- Effective charges used
          local usedInc = modDB:Sum("INC", nil, "FlaskChargesUsed")
          local flaskChargesUsed = flaskData.chargesUsed * (1 + usedInc / 100)
          local maxUses = flaskChargesUsed > 0 and m_floor(flaskData.chargesMax / flaskChargesUsed) or 0

          -- Charge gain modifier
          local gainMod = flaskData.gainMod * (1 + modDB:Sum("INC", nil, "FlaskChargesGained") / 100)

          -- Charge generation per second
          local chargesGenerated = modDB:Sum("BASE", nil, "FlaskChargesGenerated")
          if item.base.flask.life then
            chargesGenerated = chargesGenerated + modDB:Sum("BASE", nil, "LifeFlaskChargesGenerated")
          end
          if item.base.flask.mana then
            chargesGenerated = chargesGenerated + modDB:Sum("BASE", nil, "ManaFlaskChargesGenerated")
          end
          if not item.base.flask.mana and not item.base.flask.life then
            chargesGenerated = chargesGenerated + modDB:Sum("BASE", nil, "UtilityFlaskChargesGenerated")
          end

          -- Per-empty-flask charge generation
          local chargesGeneratedPerFlask = modDB:Sum("BASE", nil, "FlaskChargesGeneratedPerEmptyFlask")
          local emptyFlaskSlots = 0
          for sName, slot in pairs(itemsTab.slots) do
            if sName:find("^Flask") ~= nil and slot.selItemId == 0 then
              emptyFlaskSlots = emptyFlaskSlots + 1
            end
          end
          chargesGeneratedPerFlask = chargesGeneratedPerFlask * emptyFlaskSlots
          chargesGenerated = chargesGenerated * gainMod
          chargesGeneratedPerFlask = chargesGeneratedPerFlask * gainMod
          local totalChargesGenerated = chargesGenerated + chargesGeneratedPerFlask

          -- Chance to not consume charges
          local chanceToNotConsumeCharges = m_min(modDB:Sum("BASE", nil, "FlaskChanceNotConsumeCharges"), 100)

          -- Flask uptime calculation (mirrors ItemsTab.lua logic)
          local hasUptime = not item.base.flask.life and not item.base.flask.mana
          local flaskDuration = flaskData.duration * (1 + durInc / 100)

          -- Life/mana flask duration needs rateInc adjustment
          local rateInc = 0
          if item.base.flask.life or item.base.flask.mana then
            rateInc = modDB:Sum("INC", nil, "FlaskRecoveryRate")
          end

          local lifeDur = 0
          local manaDur = 0
          if item.base.flask.life then
            local lifeRateInc = modDB:Sum("INC", nil, "FlaskLifeRecoveryRate")
            lifeDur = flaskData.duration * (1 + durInc / 100) / (1 + rateInc / 100) / (1 + lifeRateInc / 100)
            if flaskData.lifeEffectNotRemoved or modDB:Flag(nil, "LifeFlaskEffectNotRemoved") then
              hasUptime = true
              flaskDuration = lifeDur
            end
          elseif item.base.flask.mana then
            local manaRateInc = modDB:Sum("INC", nil, "FlaskManaRecoveryRate")
            manaDur = flaskData.duration * (1 + durInc / 100) / (1 + rateInc / 100) / (1 + manaRateInc / 100)
            if flaskData.manaEffectNotRemoved or modDB:Flag(nil, "ManaFlaskEffectNotRemoved") then
              hasUptime = true
              flaskDuration = manaDur
            end
          end

          local percentageMin = nil
          local percentageAvg = nil

          if hasUptime and flaskChargesUsed > 0 and flaskDuration > 0 then
            local per3Duration = flaskDuration - (flaskDuration % 3)
            local per5Duration = flaskDuration - (flaskDuration % 5)
            local minimumChargesGenerated = per3Duration * chargesGenerated + per5Duration * chargesGeneratedPerFlask
            percentageMin = m_min(minimumChargesGenerated / flaskChargesUsed * 100, 100)

            if percentageMin < 100 and chanceToNotConsumeCharges < 100 then
              local averageChargesGenerated = (chargesGenerated + chargesGeneratedPerFlask) * flaskDuration
              local averageChargesUsed = flaskChargesUsed * (100 - chanceToNotConsumeCharges) / 100
              percentageAvg = m_min(averageChargesGenerated / averageChargesUsed * 100, 100)
            else
              percentageMin = 100
              percentageAvg = 100
            end
          end

          local effectMod = 1 + (flaskData.effectInc + effectInc) / 100

          return {
            slot = idx,
            name = item.name or "Unknown",
            baseName = item.baseName or item.name or "Unknown",
            isLifeFlask = item.base.flask.life and true or false,
            isManaFlask = item.base.flask.mana and true or false,
            isUtility = (not item.base.flask.life and not item.base.flask.mana) and true or false,
            duration = flaskDuration,
            chargesMax = flaskData.chargesMax,
            chargesUsed = m_floor(flaskChargesUsed),
            maxUses = maxUses,
            chargesGeneratedPerSec = totalChargesGenerated,
            chanceToNotConsume = chanceToNotConsumeCharges,
            effectModifier = effectMod,
            gainModifier = gainMod,
            hasUptime = hasUptime,
            uptimeMin = percentageMin,
            uptimeAvg = percentageAvg,
          }
        end)

        if ok2 and entry then
          t_insert(result, entry)
        else
          t_insert(result, {
            slot = idx,
            name = item.name or "Unknown",
            error = not ok2 and tostring(entry) or "failed to compute uptime",
          })
        end
      end
    end
  end

  return result
end

return M
