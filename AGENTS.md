# Agent rules — EventHorizon Infall (Forever)

This addon targets **WoW: Forever** (content **1.60.1**, build **69913**, TOC `## Interface: **16001**`). Lua follows Mainline Midnight-era patterns (~12.1.5 API family): **secret values**, AuraContainer/AuraButton, and the **Cooldown Manager**. The TOC Interface is **`16001`**, not `120xxx` — confirmed via live `GetBuildInfo()`.

Do **not** treat this as Classic Era, Cataclysm Classic, or pre-12.0 retail. Prefer Forever / Midnight patterns over “universal” older WoW snippets. Do **not** keep `120100` as a Forever placeholder.

**Forever content version** (e.g. **1.60.1**) is the game/version string; the TOC Interface for that build is **`16001`**. See `docs/FOREVER_COMPAT_REPORT.md`.

## Skill files (read these first for API posture)

| Skill | Path |
| --- | --- |
| Universal Mainline 12.x | [`agent-skills/universal/SKILL.md`](agent-skills/universal/SKILL.md) |
| Midnight Standard | [`agent-skills/midnight/SKILL.md`](agent-skills/midnight/SKILL.md) |
| Forever (vs Midnight) | [`agent-skills/forever/SKILL.md`](agent-skills/forever/SKILL.md) |

Cursor mirrors: `.cursor/skills/{universal,midnight,forever}/SKILL.md`. Short always-on rule: `.cursor/rules/forever-addon-api.mdc`.

## Hard rules

1. **No CLEU combat pipelines.** Do not use `COMBAT_LOG_EVENT_UNFILTERED` or `CombatLogGetCurrentEventInfo`. Forever keeps Midnight’s addon disarmament.
2. **Secret values are opaque.** Guard with `issecretvalue` (or existing helpers) before compare, arithmetic, sort, or APIs that reject secrets. Prefer `C_DurationUtil` Duration objects for timing when the codebase already does. Do not reconstruct restricted combat state from chat or other side channels.
3. **Prefer `C_*` APIs** already used here: `C_Spell`, `C_SpellBook`, `C_SpecializationInfo`, `C_CooldownViewer`, `C_UnitAuras`, `C_Secrets`, `C_Item`, `C_DurationUtil`. Prefer `ns.SpecIndex` / `ns.SpecInfo` over bare `GetSpecialization*` when both exist.
4. **Drive UI from Cooldown Manager + AuraCompat**, not invented CLEU trackers. Follow existing safe CDM read paths (dirty/taint notes in `Core.lua`). Prefer `ns.AuraCompat` for aura timing and identity.
5. **Match local style.** Namespace is `EventHorizon_Infall` (`ns`). Wrap Blizzard calls in `pcall` where the repo already does. Explain *why* in comments for secret-value and CDM taint paths.
6. **Do not port Classic-era EventHorizon / WeakAura recipes unchanged.**
7. **TOC Interface for Forever 1.60.1 is `16001`.** Do not revert to `120100` or claim Forever TOC must be `12xxxx`.

## Where to look

| Area | Files |
| --- | --- |
| Spec / CDM / item cooldown helpers | `Core.lua` |
| Secret-safe auras, estimates, identity | `AuraCompat.lua` |
| Timeline bars | `Bars.lua` |
| Icons | `Icons.lua`, `Settings_Icons.lua` |
| Per-class data | `ClassConfig/` |
| Settings UX | `Settings.lua`, `CUSTOMIZATION.md` |
| Load order / Interface | `EventHorizon_Infall.toc` |
| Forever compat scan | `docs/FOREVER_COMPAT_REPORT.md` |

## Done when

- New or changed Lua is Forever / Mainline 12.x–safe and consistent with existing helpers.
- No new Classic Era APIs or unguarded secret comparisons.
- TOC remains `## Interface: 16001` for Forever 1.60.1 unless a newer live dump says otherwise.
- Behavior still matches README / CUSTOMIZATION expectations for secret values and CDM-driven UI.
