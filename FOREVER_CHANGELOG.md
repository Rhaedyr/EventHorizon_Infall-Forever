# Forever port changelog

**Branch:** `forever`  
**Date:** 2026-09-19 (America/Chicago)  
**Addon:** EventHorizon Infall  
**Purpose:** Document every Forever bring-up code change so it can be discussed and reverted without archaeology.

Related prior work (TOC / docs only, not repeated as code edits here):

- `## Interface: 16001` already set from live Forever 1.60.1 `GetBuildInfo()`
- Compat scan: `docs/FOREVER_COMPAT_REPORT.md`
- Skills: `agent-skills/forever/SKILL.md`

---

## Client facts

| Field | Value |
| --- | --- |
| Forever version | `1.60.1` |
| Build | `69913` |
| Build date | `Sep 17 2026` |
| TOC `## Interface` | **`16001`** (unchanged by this commit) |
| API family | Mainline / Midnight-like (secrets, CDM, `C_*`) — not Classic |

Confirmed via prior live dump and repo docs. This change set does **not** alter the TOC Interface.

---

## Summary

Minimal, reversible Forever hardening for call sites the compat report flagged as **review**:

1. **Resource bar** — guard `UnitPower` / `UnitPowerMax` display sinks so secret values never reach `SetValue` / `SetText`; keep last readable power (same posture as `ObservePowerTick`).
2. **Press marks** — nil/secret-safe `UnitAffectingCombat` so a restricted boolean cannot clear miss state incorrectly.
3. **Edit Mode CDM visibility** — prefer `Enum.EditModeCooldownViewerSetting.VisibleSetting` / `Enum.CooldownViewerVisibleSetting.Always` with the previous numeric fallbacks (`6` / `0`) kept.
4. **Stack indicator power pips** — reject secret `UnitPower` before pip `SetValue`; hold last good application count.

**Not done (intentionally):** no CDM architecture rip-out, no Classic CLEU pipeline, no viewer-frame rename inventing, no Interface change, no formatting sweeps.

MCP (`user-hated-wow-mcp`) was available: `wow_api_diff` / `wow_api_search` / `wow_api_type_search` / `wow_lua_lint` (flavor `forever`) / `wow_toc_validate`. Forever enums match the old hard-coded ints. `C_CooldownViewer.*` is present on Forever. UI source grep for viewer frame names was unavailable (UI source dataset not synced); frame name strings left as-is.

---

## Changes

### 1. `ResourceBar.lua` — readable `UnitPower` for display

| | |
| --- | --- |
| **Change** | Added `lastPowerByType` + `ReadableUnitPower(powerType)` (`pcall` + `issecretvalue`; caches last non-secret number). `UpdateResourceBar` uses it for status bar, prediction ref bar, and value text. Channel prediction init uses it (clears prediction if no readable power yet). `UpdateMaxPower` uses `pcall(UnitPowerMax, …)` and falls back to `maxPowerByType` on failure/secret. |
| **Rationale** | Compat report: unguarded `UnitPower` at display sinks could error under Forever combat restriction. `ObservePowerTick` already skipped secrets; display paths did not. |
| **Revert** | Remove `ReadableUnitPower` / `lastPowerByType`; restore direct `UnitPower("player", currentPowerType)` in `UpdateResourceBar` and channel prediction; restore bare `UnitPowerMax` + `issecretvalue` branch in `UpdateMaxPower`. |

### 2. `Bars.lua` — press marks combat check

| | |
| --- | --- |
| **Change** | Replaced `if not UnitAffectingCombat("player") then …` with `pcall(UnitAffectingCombat, "player")`, then clear late/miss **only** when the result is a non-secret `false`. |
| **Rationale** | Compat report: combat boolean could become restricted; clearing miss state on a bad/secret read would hide legitimate late presses. Forever documents `UnitAffectingCombat` with `secretArguments: AllowedWhenUntainted`. |
| **Revert** | Restore the three-line `if not UnitAffectingCombat("player") then late, ns._pmMissed = false, false end` block in `JudgePress`. |

### 3. `Bars.lua` — Edit Mode visibility enums

| | |
| --- | --- |
| **Change** | `VIS_SETTING` / `VIS_ALWAYS` now take `Enum.EditModeCooldownViewerSetting.VisibleSetting` and `Enum.CooldownViewerVisibleSetting.Always` when present; else `6` / `0`. |
| **Rationale** | Forever type index confirms `VisibleSetting = 6`, `Always = 0` (same as prior hard-codes). Prefer Enum for drift resistance; keep numerics commented via fallback. |
| **Revert** | Restore `local VIS_SETTING = 6` and `local VIS_ALWAYS = 0` with the old inline comments. |

### 4. `Bars.lua` — stack indicator power applications

| | |
| --- | --- |
| **Change** | Power-type SI rows: only assign `applications` from `UnitPower` when non-nil and not secret; otherwise reuse `rowData._lastPowerApps` (or `0`). |
| **Rationale** | Avoid feeding secret power into pip `SetValue` under Forever restriction; prior `pcall` alone still passed secret numbers through. |
| **Revert** | Restore `if ok then applications = power end` and drop `_lastPowerApps`. |

### 5. `FOREVER_CHANGELOG.md` (this file)

| | |
| --- | --- |
| **Change** | New root changelog for Forever port discussion / revert. |
| **Revert** | Delete the file. |

---

## Known risks / still to test in-game (Forever 1.60.1)

1. **Load** — Addon enables with Interface `16001`; no out-of-date warning; no Lua errors on login.
2. **Resource bar** — Enter combat / restricted content: bar and value text should freeze on last readable power rather than error; leave combat and confirm updates resume.
3. **Press marks** — In and out of combat: late/miss clearing still feels right; no Lua errors on `UseAction`.
4. **CDM / Edit Mode** — Essential / Utility / BuffIcon / BuffBar viewers exist; hide helpers and “Always” visibility still work; `IsCooldownViewerAvailable` true when expected.
5. **Stack indicators** — Power-type pips (combo points, etc.) update OOC and do not error IC under restriction.
6. **Viewer frame globals** — Confirm `_G.EssentialCooldownViewer` (and siblings) exist; MCP UI source was not synced, so names were not re-verified against Forever Blizzard UI.
7. **`GetSpecializationInfoByID`** — Still used once in `Settings.lua` behind `pcall`; Forever API search did not list it. Profile-copy labels may fall back if missing — not changed here.
8. **ClassConfig spell IDs** — Content gaps are data issues, not addressed in this commit.

---

## MCP notes

| Tool | Result |
| --- | --- |
| `wow_toc_validate` | Interface targets Forever; 0 errors (backslash path warnings on `ClassConfig\*.lua` — pre-existing, not changed). |
| `wow_api_diff` / `wow_api_search` | `UnitPower`, `UnitPowerMax`, `UnitAffectingCombat`, `issecretvalue` documented on Forever; `C_CooldownViewer.*` present. |
| `wow_api_type_search` | `EditModeCooldownViewerSetting.VisibleSetting = 6`, `CooldownViewerVisibleSetting.Always = 0`, `EditModeSystem.CooldownViewer = 20`. |
| `wow_lua_lint` flavor `forever` | `ResourceBar.lua` / `Bars.lua`: **0 errors** (info notes only; Forever unknown-global checks disabled upstream). |
| `wow_ui_template_search` | Failed: Forever UI source dataset not built (`sync ui-source` needed). Viewer names left unchanged. |

Fallback docs were also read: `docs/FOREVER_COMPAT_REPORT.md`, `agent-skills/forever/SKILL.md`.
