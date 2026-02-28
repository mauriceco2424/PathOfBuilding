# PathOfBuilding Fork Information

**Fork Owner**: mauriceco2424
**Fork URL**: https://github.com/mauriceco2424/PathOfBuilding
**Direct Upstream**: https://github.com/PathOfBuildingCommunity/PathOfBuilding (official)
**Current Version**: v2.60.0

---

## Quick Update Command

Use the `/update-pob` slash command to check for and apply updates:

```
/update-pob         # Check and update
/update-pob --check # Check only, don't update
```

Or manually:
```bash
npm run pob:check-version  # Check current vs latest version
```

---

## Architecture Overview

```
PathOfBuildingCommunity/PathOfBuilding (official PoB - releases like v2.60.0)
           ↓ (direct merge via community remote)
mauriceco2424/PathOfBuilding (our fork with headless API layer)
           ↓
    pob-api-fork/ (local working copy)
```

### What We Add (30+ Custom Functions)

Our fork adds a complete headless API layer that doesn't exist in the official PoB:

**Custom Files (not in upstream):**
- `src/HeadlessWrapper.lua` - Headless mode entry point
- `src/API/BuildOps.lua` - 30 API functions (1,860 lines)
- `src/API/Handlers.lua` - 33 JSON-RPC handlers
- `src/API/Server.lua` - stdio JSON-RPC server

**API Function Categories:**
| Category | Functions |
|----------|-----------|
| Calculations | `get_main_output()`, `get_full_calcs()`, `export_stats()` |
| Tree Ops | `get_tree()`, `set_tree()`, `update_tree_delta()`, `search_nodes()`, `find_path()`, `get_tree_stats()` |
| Skills/Gems | `get_skills()`, `set_main_selection()`, `create_socket_group()`, `add_gem()`, `set_gem_level()`, `set_gem_quality()`, `remove_skill()`, `remove_gem()`, `calc_with_gems()` |
| Config | `get_config()`, `get_full_config()`, `set_config()`, `set_skill_config()` |
| Items | `get_items()`, `add_item_text()`, `set_flask_active()` |
| Trade | `generate_trade_query()` |
| What-if | `calc_with()`, `calc_with_gems()` |
| Build Info | `get_build_info()`, `export_build_xml()`, `set_level()` |

### Why Merges Are Usually Clean

Most of our custom work lives in files that don't exist in the official PoB repository (`src/API/*`, `src/HeadlessWrapper.lua`), so upstream merges are usually straightforward. We do patch a small number of core files (`src/Modules/CalcPerform.lua`, `src/Modules/CalcSetup.lua`, `src/Modules/Main.lua`), so merge review should still inspect those closely.

---

## Git Remote Configuration

This directory has two active remotes:

```bash
origin    -> https://github.com/mauriceco2424/PathOfBuilding.git
            (our fork - where we push our changes)

community -> https://github.com/PathOfBuildingCommunity/PathOfBuilding.git
            (official PoB - where we pull updates from)
```

There is no active git remote to `ianderse/PathOfBuilding` in this repo.

**Check remotes:**
```bash
cd pob-api-fork
git remote -v
```

---

## Updating to Latest PoB Version

### Option 1: Use the Slash Command (Recommended)

```
/update-pob
```

This will:
1. Check current version vs PathOfBuildingCommunity latest
2. Show what's changed
3. Ask for confirmation
4. Merge, rebuild Docker, and verify

### Option 2: Manual Update

```bash
cd pob-api-fork

# Fetch latest from official PoB
git fetch community --tags

# See what's new
git log HEAD..community/dev --oneline
git diff HEAD..community/dev --stat

# Merge
git merge community/dev -m "Merge official PoB dev into fork"

# Rebuild Docker
cd ..
docker compose build pob-api-1 pob-api-2 pob-api-3
docker compose up -d --force-recreate pob-api-1 pob-api-2 pob-api-3

# Verify
docker logs poa-pob-api-1 --tail 20
```

### Option 3: Version Check Script

```bash
# Check if update available
npm run pob:check-version

# Get JSON output (for scripts)
npm run pob:check-version:json
```

---

## Viewing Upstream Changes Before Merging

You can review exactly what PathOfBuildingCommunity changed:

```bash
cd pob-api-fork
git fetch community --tags

# Commit log
git log HEAD..community/dev --oneline

# Files changed summary
git diff HEAD..community/dev --stat

# Actual code changes
git diff HEAD..community/dev -- src/

# Specific important files
git diff HEAD..community/dev -- manifest.xml
git diff HEAD..community/dev -- src/GameVersions.lua
git diff HEAD..community/dev -- CHANGELOG.md
```

---

## When to Update

- **New PoE league launch** - PoB Community releases major updates with new tree, skills, items
- **Bug fixes** - Calculation fixes, crash fixes
- **New features** - New unique support, new mechanics

Check the official releases: https://github.com/PathOfBuildingCommunity/PathOfBuilding/releases

---

## Docker Container

The Docker pool (`poa-pob-api-1`, `poa-pob-api-2`, `poa-pob-api-3`) runs the Lua code from this fork.

**Rebuild after fork updates:**
```bash
docker compose build pob-api-1 pob-api-2 pob-api-3
docker compose up -d --force-recreate pob-api-1 pob-api-2 pob-api-3
```

**Check container health:**
```bash
docker compose ps
docker logs poa-pob-api-1
```

---

## Branches

### `dev` (main working branch)
- Contains all our API enhancements
- Synced directly with PathOfBuildingCommunity/dev
- This is what Docker builds from

### `009-get-full-calcs-enhancement` (legacy)
- Original enhancement branch
- Kept for history

---

## Pushing Changes to Our Fork

When adding new API functionality:

```bash
cd pob-api-fork

# Make changes to src/API/*.lua
git add src/API/BuildOps.lua src/API/Handlers.lua
git commit -m "feat: Add new API action"

# Push to our fork
git push origin dev

# Rebuild Docker
cd ..
docker compose build pob-api-1 pob-api-2 pob-api-3
docker compose up -d --force-recreate pob-api-1 pob-api-2 pob-api-3
```

---

## Troubleshooting

### "Version check shows we're behind but /update-pob fails"

1. Check network connectivity to GitHub
2. Verify community remote exists: `git remote -v`
3. Try manual fetch: `git fetch community --tags`

### "Merge conflicts"

Conflicts are usually limited to the small set of core files we patch on top of official PoB:
- `src/Modules/CalcPerform.lua`
- `src/Modules/CalcSetup.lua`
- `src/Modules/Main.lua`

If a conflict appears:
- review the conflict manually instead of blindly accepting sides
- keep our API layer files (`src/API/*`, `src/HeadlessWrapper.lua`)
- verify the merged fork still boots and loads a real build after rebuild

### "API doesn't work after update"

```bash
# Check container logs
docker logs poa-pob-api-1

# Rebuild completely
docker compose build --no-cache pob-api-1 pob-api-2 pob-api-3
docker compose up -d --force-recreate pob-api-1 pob-api-2 pob-api-3
```

### "Rollback to previous version"

```bash
cd pob-api-fork
git switch dev
git log --oneline -5  # Find the commit before the merge
git reset --hard <commit-hash>

cd ..
docker compose build pob-api-1 pob-api-2 pob-api-3
docker compose up -d --force-recreate pob-api-1 pob-api-2 pob-api-3
```

---

## Key Files

**In pob-api-fork:**
- `manifest.xml` - Version number (line 3)
- `src/API/BuildOps.lua` - Core API functions
- `src/API/Handlers.lua` - JSON-RPC handlers
- `src/HeadlessWrapper.lua` - Entry point

**In main repo:**
- `scripts/check-pob-version.ts` - Version comparison tool
- `.claude/commands/update-pob.md` - Slash command definition
- `docker-compose.yml` - Docker service definition

---

**Last Updated**: 2026-02-28
**Current Version**: v2.60.0
**Status**: Synced against PathOfBuildingCommunity/dev, official PoB is the source of truth
