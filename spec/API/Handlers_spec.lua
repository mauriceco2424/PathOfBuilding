local json_ok, json = pcall(require, 'dkjson')
if not json_ok then
  local ok2, mod = pcall(dofile, '../runtime/lua/dkjson.lua')
  if ok2 then json = mod else error('dkjson not found for tests') end
end

local function j(tbl)
  return assert(json.encode(tbl))
end

local function run_stdio_session(lines)
  local tmp_in = os.tmpname()
  local f = assert(io.open(tmp_in, 'w'))
  for _, ln in ipairs(lines) do
    if type(ln) == 'table' then ln = j(ln) end
    f:write(ln, "\n")
  end
  f:close()

  local cmd = string.format("env POB_API_STDIO=1 luajit HeadlessWrapper.lua < %q", tmp_in)
  local p = assert(io.popen(cmd, 'r'))
  local out = p:read('*a') or ''
  p:close()
  os.remove(tmp_in)

  local objs = {}
  for line in out:gmatch("[^\r\n]+") do
    local ok, obj = pcall(json.decode, line)
    if ok and type(obj) == 'table' then
      table.insert(objs, obj)
    end
  end
  return out, objs
end

local function read_fixture_xml()
  -- Use a small, committed build fixture
  local candidates = {
    '../spec/TestBuilds/3.13/OccVortex.xml',
    '../spec/TestBuilds/3.13/Dual Savior.xml',
    '../spec/TestBuilds/3.13/Dual Wield Cospris CoC.xml',
  }
  for _, path in ipairs(candidates) do
    local fh = io.open(path, 'r')
    if fh then
      local txt = fh:read('*a')
      fh:close()
      if txt and #txt > 0 then return txt, path end
    end
  end
  error('no build fixture xml found')
end

describe('Handlers API via stdio', function()
  it('loads a build and exposes core endpoints', function()
    local xml = read_fixture_xml()
    local _, objs = run_stdio_session({
      { action = 'ping' },
      { action = 'version' },
      { action = 'load_build_xml', params = { xml = xml, name = 'Spec Build' } },
      { action = 'get_build_info' },
      { action = 'get_stats' },
      { action = 'get_skills' },
      { action = 'get_tree' },
      { action = 'get_config' },
      { action = 'export_build_xml' },
      { action = 'quit' },
    })
    local saw = {}
    for _, o in ipairs(objs) do
      if o.pong then saw.ping = true end
      if o.version then saw.version = o.version end
      if o.build_id then saw.loaded = true end
      if o.info then saw.info = o.info end
      if o.stats then saw.stats = o.stats end
      if o.skills then saw.skills = o.skills end
      if o.tree then saw.tree = o.tree end
      if o.config then saw.config = o.config end
      if o.xml then saw.xml = o.xml end
    end
    assert.is_true(saw.ping)
    assert.is_table(saw.version)
    assert.is_true(saw.loaded)
    assert.is_table(saw.info)
    assert.is_table(saw.stats)
    assert.is_table(saw.skills)
    assert.is_table(saw.tree)
    assert.is_table(saw.config)
    assert.is_string(saw.xml)
    assert.is_true(saw.xml:find('<PathOfBuilding') ~= nil)
    -- Some basic fields
    assert.is_number(saw.info.level)
    assert.is_string(saw.info.className or '')
    assert.is_table(saw.stats._meta or {})
  end)

  it('updates level and config', function()
    local xml = read_fixture_xml()
    local _, objs = run_stdio_session({
      { action = 'load_build_xml', params = { xml = xml, name = 'Spec Build' } },
      { action = 'get_build_info' },
      { action = 'set_level', params = { level = 20 } },
      { action = 'get_build_info' },
      { action = 'get_config' },
      { action = 'set_config', params = { enemyLevel = 83, bandit = 'None' } },
      { action = 'get_config' },
      { action = 'quit' },
    })
    local levels = {}
    local cfgs = {}
    for _, o in ipairs(objs) do
      if o.info and o.info.level then table.insert(levels, o.info.level) end
      if o.config then table.insert(cfgs, o.config) end
    end
    assert.is_true(#levels >= 2)
    assert.are_not.equal(levels[1], levels[#levels])
    assert.are.equal(20, levels[#levels])
    assert.is_true(#cfgs >= 2)
    assert.are.equal(83, cfgs[#cfgs].enemyLevel)
  end)

  it('computes with tree deltas and toggles flasks', function()
    local xml = read_fixture_xml()
    local _, objs = run_stdio_session({
      { action = 'load_build_xml', params = { xml = xml, name = 'Spec Build' } },
      { action = 'get_tree' },
      { action = 'calc_with', params = { removeNodes = {} } },
      { action = 'set_flask_active', params = { index = 1, active = false } },
      { action = 'get_items' },
      { action = 'quit' },
    })
    local tree, calc_ok, items
    for _, o in ipairs(objs) do
      if o.tree then tree = o.tree end
      if o.output then calc_ok = true end
      if o.items then items = o.items end
    end
    assert.is_table(tree)
    assert.is_true(calc_ok)
    assert.is_table(items)
    -- Expect at least one flask entry present
    local foundFlask = false
    for _, it in ipairs(items) do
      if type(it.slot) == 'string' and it.slot:match('Flask') then
        foundFlask = true; break
      end
    end
    assert.is_true(foundFlask)
  end)

  it('validates required params', function()
    local _, objs = run_stdio_session({
      { action = 'load_build_xml', params = {} },
      { action = 'set_level' },
      { action = 'quit' },
    })
    local sawErrors = 0
    for _, o in ipairs(objs) do if o.ok == false and o.error then sawErrors = sawErrors + 1 end end
    assert.is_true(sawErrors >= 2)
  end)

  it('sets main selection based on current skills', function()
    local xml = read_fixture_xml()
    local _, objs = run_stdio_session({
      { action = 'load_build_xml', params = { xml = xml, name = 'Spec Build' } },
      { action = 'get_skills' },
      -- Will set same selection to validate endpoint wiring
      { action = 'set_main_selection', params = { mainSocketGroup = 1, mainActiveSkill = 1, skillPart = 1 } },
      { action = 'quit' },
    })
    local sawSkills, sawSet
    for _, o in ipairs(objs) do
      if o.skills then sawSkills = o.skills end
      if o.skills and o.ok then sawSet = o.skills end
    end
    assert.is_table(sawSkills)
    assert.is_table(sawSet)
  end)
end)
