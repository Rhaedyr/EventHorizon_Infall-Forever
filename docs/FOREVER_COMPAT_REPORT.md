# Forever compatibility conflict report

**Addon:** EventHorizon Infall  
**Branch:** `forever`  
**Scan date:** 2026-09-19 (America/Chicago)  
**Target game build (content):** Forever **1.60.1** (Camelot)  
**Client build:** **69913** (date string `Sep 17 2026`)  
**TOC `## Interface`:** **`16001`** (confirmed live via `GetBuildInfo()` — see below)  
**API family:** Mainline ~12.1.5 / Midnight Standard + Forever (secrets, AuraContainer, Cooldown Manager) — Lua posture may remain Midnight-like even though the TOC Interface is **16001**, not `120xxx`.

Sources: in-repo Lua/TOC scan; live Forever client dump; [Wowhead — Forever addon changes from Midnight](https://www.wowhead.com/news/wow-forever-will-have-addon-changes-from-midnight-382921).

---

## Confirmed client dump (Forever 1.60.1)

```lua
/dump GetBuildInfo()
-- [1] = "1.60.1"
-- [2] = "69913"
-- [3] = "Sep 17 2026"
-- [4] = 16001
```

| Field | Value |
| --- | --- |
| Version string | `1.60.1` |
| Build number | `69913` |
| Build date | `Sep 17 2026` |
| Interface (`select(4, GetBuildInfo())`) | **`16001`** |

### Interface correction (important)

Earlier docs treated `16001` as a Classic-style number to **avoid**, and kept `120100` as a Mainline-shaped placeholder. That advice is **wrong for this client**.

- Forever content version **1.60.1** reports TOC Interface **`16001`**. The addon `.toc` **must** use `## Interface: 16001` or the client will mark it out of date.
- The Lua API family may still be Mainline / Midnight-like (secrets, CDM, `C_*`) per Blizzard UI Discord / Wowhead — that does **not** mean the TOC should stay on `120xxx`.
- Do **not** keep `120100` as a Forever placeholder once `GetBuildInfo()` is known.
- Do **not** confuse Forever’s `16001` with Classic Era Interface numbers that also sit in the `1xxxx` range: same digit pattern, different product. Forever still uses Mainline-style addon APIs.

---

## Executive summary

This addon is **already largely Midnight / CDM / secret-aware**. Forever is announced as the same Mainline API family (~12.1.5) with the same disarmament (secrets, AuraContainer). **Classic-port conflicts are low** — there is no CLEU pipeline, no Classic TOC suffix, and spell/spec paths prefer `C_*`.

**TOC Interface is resolved:** `## Interface: 16001` matches live Forever 1.60.1 (build 69913).

**Remaining risks** are mostly:

1. A few **power / combat** call sites that still touch `UnitPower` / `UnitAffectingCombat` in ways that need Forever in-client confirmation under restriction.
2. **Hard-coded CDM / Edit Mode constants** that may drift if Forever’s enums differ.
3. **No direct `AuraContainer` usage** — the addon uses CDM frames + `C_UnitAuras` (correct Midnight pattern); still verify Forever viewer frame names and aura APIs behave the same.

Overall: **good Forever candidate**; Interface is set — verify load + combat-restricted power/indicators in the Forever client rather than rewriting architecture.

---

## Findings table

| Pattern | Location | Severity | Notes |
| --- | --- | --- | --- |
| `COMBAT_LOG_EVENT_UNFILTERED` / `CombatLogGetCurrentEventInfo` | *(none)* | **ok** | No CLEU usage in tree. |
| Bare `GetSpellInfo` / `GetSpellCooldown` | *(none bare)* | **ok** | Only `C_Spell.GetSpellInfo` / `C_Spell.GetSpellCooldown` (e.g. `Bars.lua:1562`, `Icons.lua:601`). |
| `GetSpellPowerCost` fallback | `ResourceBar.lua:127` | **ok-with-guards** | Prefers `C_Spell.GetSpellPowerCost`, falls back to global. |
| `UnitHealth` in branching | *(none)* | **ok** | No `UnitHealth` usage. |
| `UnitPower` — regen observe | `ResourceBar.lua:50-51` | **ok-with-guards** | `pcall` + `issecretvalue`; skips secret frames. |
| `UnitPower` — status bar / text display | `ResourceBar.lua:303,308,312,423` | **review** | Unguarded display sinks. Often OK under secrets; confirm Forever does not error on `SetValue`/`SetText` with secret power. |
| `UnitPower` — stack indicator applications | `Bars.lua:6548-6565` | **ok-with-guards** | Comment notes secret compare throws; empty check via `pcall(IsZero, …)`. Pip `SetValue(applications)` may still receive secrets. |
| `UnitPowerMax` settings | `Settings.lua:3508-3509`, `3599-3600` | **ok-with-guards** | Explicit `issecretvalue` handling. |
| `UnitPowerMax` resource bar | `ResourceBar.lua:319-324` | **ok-with-guards** | Falls back to cached max when secret. |
| `GetSpecialization` / `GetSpecializationInfo` | `Core.lua:12-26` | **ok-with-guards** | Prefers `C_SpecializationInfo.*`; bare global only as fallback via `ns.SpecIndex` / `ns.SpecInfo`. |
| `issecretvalue` / `C_Secrets` / `C_DurationUtil` | Widespread (`AuraCompat.lua`, `Bars.lua`, `Core.lua`, `Icons.lua`, `ResourceBar.lua`, …) | **ok** (good) | Core Forever/Midnight posture already present. |
| `C_CooldownViewer` / `CooldownViewer*` | Widespread (`Bars.lua`, `Settings.lua`, `Core.lua`, `AuraCompat.lua`, `Migrate121.lua`, …) | **ok** (good) | Addon is CDM-first; ideal for Forever. |
| `AuraContainer` / `AuraButton` literals | *(none)* | **review** | No direct API use. Uses CDM buff viewers + `C_UnitAuras` (`AuraCompat.lua`). Aligns with Midnight design; confirm Forever still exposes same viewer globals. |
| `C_UnitAuras` / `UNIT_AURA` | `AuraCompat.lua`; `Bars.lua:4600,5394+`; `Icons.lua:1190` | **ok-with-guards** | Restriction probe + Duration paths in `AuraCompat`. |
| `UnitAffectingCombat("player")` | `Bars.lua:3388-3390` | **review** | Branches press-mark “late” state on combat boolean. Usually non-secret; if Forever secrets this, wrap/`pcall`. Not used on secret *numeric* combat data. |
| `InCombatLockdown()` | Many settings/UI paths | **ok** | Secure/UI gating; appropriate. |
| Hard-coded Edit Mode / CDM visibility ints | `Bars.lua:4719-4723` | **review** / uncertain | `VIS_SETTING = 6`, `VIS_ALWAYS = 0` with enum comments. Verify on Forever or prefer `Enum.*` when present. |
| Viewer frame name strings | `Bars.lua:2109-2110`, `4608-4611`; `AuraCompat.lua:208-209` | **review** / uncertain | Assumes Standard CDM frame names exist on Forever. |
| Classic-only assumptions | *(none in Lua)* | **ok** | Docs/AGENTS warn against Classic ports; TOC is Forever `16001` (not a Classic `_Vanilla` / Era product). |
| TOC Interface vs Forever 1.60.1 | `EventHorizon_Infall.toc:1` | **ok** | **`## Interface: 16001`** matches live `GetBuildInfo()` build **69913** / version **1.60.1**. |

---

## Recommended next code changes

**Do not require large refactors for Forever bring-up.** Suggested follow-ups (separate commits after more in-client smoke tests):

1. **Interface — done** — `## Interface: 16001` set from live dump (version 1.60.1, build 69913, Sep 17 2026).
2. **Resource bar display** — optionally guard `UpdateResourceBar` `UnitPower` reads like `ObservePowerTick` (skip or keep last known when secret) if Forever errors on display sinks.
3. **Press marks** — `pcall` / nil-safe around `UnitAffectingCombat` if combat boolean becomes restricted.
4. **Edit Mode hide helpers** — resolve visibility settings via `Enum.EditModeCooldownViewerSetting` / `Enum.CooldownViewerVisibleSetting` when available; keep numeric fallbacks behind comments.
5. **Smoke-test CDM** — Essential/Utility/BuffIcon/BuffBar viewers, `IsCooldownViewerAvailable`, category sets, item cooldowns (`ns.ItemCooldownDurObj`).
6. **ClassConfig** — treat missing Forever spells as data updates, not API redesign.

---

## What the user should still supply (optional smoke tests)

Build / Interface dump is **done**. Still useful from a Forever 1.60.1 session:

1. Whether the addon loads cleanly (any “out of date” Interface warning, Lua errors on login / enter combat / open `/infall setup`).
2. Whether Cooldown Manager viewers are present and editable in Edit Mode.
3. Any aura/power UI anomalies **only while combat-restricted** (secret mode).

---

## Skill / agent pointers

| Path | Role |
| --- | --- |
| `agent-skills/universal/SKILL.md` | Shared Mainline 12.x rules |
| `agent-skills/midnight/SKILL.md` | Midnight Standard specifics |
| `agent-skills/forever/SKILL.md` | Forever vs Midnight + confirmed Interface **16001** |
| `.cursor/skills/*` | Copies for Cursor skill discovery |
| `AGENTS.md` | Repo entrypoint |
| `.cursor/rules/forever-addon-api.mdc` | Short always-on Cursor rule |
