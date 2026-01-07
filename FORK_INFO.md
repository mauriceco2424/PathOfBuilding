# PathOfBuilding Fork Information

**Fork Owner**: mauriceco2424
**Fork URL**: https://github.com/mauriceco2424/PathOfBuilding
**Upstream**: https://github.com/ianderse/PathOfBuilding (api-stdio branch)
**Original**: https://github.com/PathOfBuildingCommunity/PathOfBuilding

---

## Why We Use a Fork

**PathOfBuildingCommunity/PathOfBuilding** is a desktop GUI application with no programmatic API.

**ianderse/PathOfBuilding** adds the `api-stdio` branch with:
- Headless mode (no GUI required)
- stdio-based JSON-RPC interface
- API actions for programmatic access

**mauriceco2424/PathOfBuilding** extends ianderse's work with:
- `get_full_calcs` action (651 stat fields in single call)
- Enhanced MCP capabilities for Path of Agent

---

## Repository Structure

```
PathOfBuildingCommunity/PathOfBuilding (original desktop app)
           ↓
    ianderse/PathOfBuilding (api-stdio branch - headless mode)
           ↓
mauriceco2424/PathOfBuilding (get_full_calcs enhancement)
```

---

## Git Remote Configuration

This directory has two remotes configured:

```bash
origin   → https://github.com/mauriceco2424/PathOfBuilding.git
           (your fork - where you push changes)

upstream → https://github.com/ianderse/PathOfBuilding.git
           (ianderse's fork - where you pull updates)
```

**Check remotes:**
```bash
cd pob-api-fork
git remote -v
```

---

## Branches

### `api-stdio` (base branch)
- Maintained by ianderse
- Contains all headless mode functionality
- Regularly synced with PathOfBuildingCommunity/dev

### `009-get-full-calcs-enhancement` (our enhancement)
- Based on `api-stdio`
- Adds `get_full_calcs()` action to BuildOps.lua
- Adds `deepCopySafe()` JSON serialization helper
- Exposes 651 stat fields via single API call

---

## When to Push to Fork

You'll **rarely** need to push changes to the fork. Only when:

1. **Adding new MCP actions** (like get_full_calcs)
2. **Fixing bugs in the MCP layer**
3. **Enhancing the API interface**

**Normal development** (TypeScript wrappers, frontend, etc.) happens in the main `path of agent` repo.

---

## Pushing Changes to Fork

When you do need to push MCP enhancements:

```bash
cd pob-api-fork

# Make sure you're on the right branch
git checkout 009-get-full-calcs-enhancement

# Commit your Lua changes
git add src/API/BuildOps.lua src/API/Handlers.lua
git commit -m "feat: Add new MCP action"

# Push to your fork
git push origin 009-get-full-calcs-enhancement
```

---

## Pulling Updates from Upstream

To get updates from ianderse's api-stdio branch:

```bash
cd pob-api-fork

# Fetch latest from ianderse
git fetch upstream

# Switch to api-stdio base branch
git checkout api-stdio

# Merge upstream changes
git merge upstream/api-stdio

# Push updated base to your fork
git push origin api-stdio

# Rebase your enhancement on updated base
git checkout 009-get-full-calcs-enhancement
git rebase api-stdio

# Force push (if needed after rebase)
git push --force-with-lease origin 009-get-full-calcs-enhancement
```

**Frequency**: Check for updates monthly or when new PoE leagues launch.

---

## Docker Container Deployment

The Docker container (`poa-pob-api`) runs the enhanced Lua code from this fork.

**Current deployment:**
- Dockerfile builds from local `pob-api-fork/` directory
- Contains the `get_full_calcs` enhancement
- No need to rebuild for TypeScript wrapper changes

**To rebuild container after Lua changes:**
```bash
docker-compose build pob-api
docker-compose up -d pob-api
```

---

## Contributing Back to ianderse

If you want to contribute `get_full_calcs` back to ianderse's fork:

1. **Push your branch to your fork** (when GitHub is working):
   ```bash
   cd pob-api-fork
   git push origin 009-get-full-calcs-enhancement
   ```

2. **Create Pull Request on GitHub**:
   - Go to: https://github.com/mauriceco2424/PathOfBuilding
   - Click "Pull requests" → "New pull request"
   - Base: `ianderse/PathOfBuilding:api-stdio`
   - Compare: `mauriceco2424/PathOfBuilding:009-get-full-calcs-enhancement`
   - Title: "feat: Add get_full_calcs action for comprehensive build analysis"

3. **PR Description Template**:
   ```markdown
   ## Overview

   Adds `get_full_calcs` MCP action that returns complete PoB calculation
   snapshot with 651 stat fields in a single API call.

   ## Motivation

   The Path of Agent project needs comprehensive build analysis for item
   comparison and AI-powered recommendations. The existing `get_stat` action
   requires 23+ individual calls to gather basic stats.

   ## Changes

   - Added `get_full_calcs()` function in BuildOps.lua
   - Added `deepCopySafe()` helper for JSON-safe table serialization
   - Wired action into Handlers.lua RPC dispatcher
   - Added LibDeflate.lua for compression support

   ## Performance Impact

   - Single API call vs 23+ calls for previous approach
   - 28x more data available (651 fields vs 23)
   - Enables sophisticated item comparison and build analysis

   ## Testing

   Tested with 20+ builds across different archetypes (attack, spell, DoT, etc.)
   All stat fields verified against PoB Desktop UI.

   ## Backward Compatibility

   This is a new action - no breaking changes to existing API.
   ```

---

## Documentation References

**Main Spec**: `specs/009-pob-calculation-mastery/README.md`
- Complete overview of get_full_calcs enhancement
- 651 stat field documentation
- Main skill detection algorithm

**Implementation Details**: `specs/009-pob-calculation-mastery/IMPLEMENTATION_COMPLETE.md`
- Comprehensive implementation summary
- Usage examples
- TypeScript interfaces

**Field Discovery**: `specs/009-pob-calculation-mastery/FIELD_DISCOVERY_RESULTS.md`
- Exact field count and categorization
- EHP and DPS metric analysis

---

## Key Files in This Fork

**Lua MCP Layer:**
- `src/API/BuildOps.lua` - Core API functions including get_full_calcs()
- `src/API/Handlers.lua` - RPC action dispatcher
- `src/HeadlessWrapper.lua` - stdio mode entry point
- `src/LibDeflate.lua` - Compression library

**TypeScript Wrappers** (in main repo):
- `backend/scripts/pob-api-wrapper/types.ts` - Full type definitions
- `backend/scripts/pob-api-wrapper/server.ts` - HTTP wrapper
- `backend/scripts/pob-api-wrapper/test-full-calcs.ts` - Test script

---

## Troubleshooting

### "Can't push to fork"

**Symptom**: `fatal: unable to access ... error: 500`

**Cause**: GitHub server issues (temporary)

**Solution**: Wait and retry later. Your commits are safe locally.

### "Changes not showing in container"

**Symptom**: API doesn't reflect Lua code changes

**Cause**: Container uses old code, needs rebuild

**Solution**:
```bash
docker-compose build pob-api
docker-compose up -d pob-api
```

### "Upstream diverged"

**Symptom**: `git merge upstream/api-stdio` shows conflicts

**Cause**: ianderse updated api-stdio with conflicting changes

**Solution**: Resolve conflicts manually, prioritizing upstream changes unless your enhancement conflicts directly.

---

**Last Updated**: 2025-11-18
**Status**: Fork active, enhancement pending push to GitHub
