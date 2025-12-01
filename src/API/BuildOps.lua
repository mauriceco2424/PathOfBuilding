-- API/BuildOps.lua
-- Thin wrappers around PoB headless objects for programmatic operations

local M = {}

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
  local skillOutput = calcsTab.skillOutput or {}
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
    skills = deepCopySafe(socketGroups),
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
  return out
end

-- Set tree allocation from parameters
-- params: { classId, ascendClassId, secondaryAscendClassId?, nodes:[int], masteryEffects?:{[id]=effect}, treeVersion? }
function M.set_tree(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end
  local classId = tonumber(params.classId or 0) or 0
  local ascendId = tonumber(params.ascendClassId or 0) or 0
  local secondaryId = tonumber(params.secondaryAscendClassId or 0) or 0
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
-- params: { addNodes?: number[], removeNodes?: number[], useFullDPS?: boolean }
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
  local out = calcFunc(override, params and params.useFullDPS)
  return out, baseOut
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

  if changed and build.configTab.BuildModList then build.configTab:BuildModList() end
  M.get_main_output()
  return true
end


-- Skills API
function M.get_skills()
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end
  local groups = {}
  for idx, g in ipairs(build.skillsTab.socketGroupList or {}) do
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
          table.insert(gemList, {
            index = gemIdx,
            nameSpec = gem.nameSpec,
            level = gem.level,
            quality = gem.quality,
            qualityId = gem.qualityId,
            enabled = gem.enabled ~= false,
            -- Support gem detection: nameSpec ends with " Support" or gem has support tag
            isSupport = gem.nameSpec and gem.nameSpec:match(" Support$") ~= nil,
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
            if mod then table.insert(entry.implicitMods, mod) end
          end
        end

        entry.explicitMods = {}
        if it.explicitModLines then
          for _, modLine in ipairs(it.explicitModLines) do
            local mod = extractModLine(modLine)
            if mod then table.insert(entry.explicitMods, mod) end
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
-- params: { keyword: string, nodeType?: string ('normal'|'notable'|'keystone'), maxResults?: number, includeAllocated?: boolean }
function M.search_nodes(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' or type(params.keyword) ~= 'string' then
    return nil, 'missing or invalid keyword'
  end

  local keyword = params.keyword:lower()
  local nodeType = params.nodeType and params.nodeType:lower() or nil
  local maxResults = tonumber(params.maxResults) or 50
  local includeAllocated = params.includeAllocated ~= false

  local results = {}
  local count = 0

  -- Get allocated nodes set for quick lookup
  local allocatedSet = {}
  if build.spec.allocNodes then
    for id, _ in pairs(build.spec.allocNodes) do
      allocatedSet[id] = true
    end
  end

  -- Search through all nodes
  for id, node in pairs(build.spec.nodes) do
    if count >= maxResults then break end

    -- Skip if already allocated and we don't want allocated nodes
    if not includeAllocated and allocatedSet[id] then
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

return M
