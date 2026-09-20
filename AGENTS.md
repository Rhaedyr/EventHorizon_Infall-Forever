# Agent rules — EventHorizon Infall (Forever)

This addon targets **WoW: Forever** on Mainline’s Midnight-era UI (TOC `Interface` ~`120100`). Forever shares Mainline’s architecture (roughly the **12.1.5** API set), including **secret values**, AuraContainer/AuraButton, and the **Cooldown Manager**.

Do **not** treat this as Classic Era, Cataclysm Classic, or pre-12.0 retail. Prefer Forever / Midnight patterns over “universal” older WoW snippets.

## Hard rules

1. **No CLEU combat pipelines.** Do not use `COMBAT_LOG_EVENT_UNFILTERED` or `CombatLogGetCurrentEventInfo`. Forever keeps Midnight’s addon disarmament.
2. **Secret values are opaque.** Guard with `issecretvalue` (or existing helpers) before compare, arithmetic, sort, or APIs that reject secrets. Prefer `C_DurationUtil` Duration objects for timing when the codebase already does. Do not reconstruct restricted combat state from chat or other side channels.
3. **Prefer `C_*` APIs** already used here: `C_Spell`, `C_SpellBook`, `C_SpecializationInfo`, `C_CooldownViewer`, `C_UnitAuras`, `C_Secrets`, `C_Item`, `C_DurationUtil`. Prefer `ns.SpecIndex` / `ns.SpecInfo` over bare `GetSpecialization*` when both exist.
4. **Drive UI from Cooldown Manager + AuraCompat**, not invented CLEU trackers. Follow existing safe CDM read paths (dirty/taint notes in `Core.lua`). Prefer `ns.AuraCompat` for aura timing and identity.
5. **Match local style.** Namespace is `EventHorizon_Infall` (`ns`). Wrap Blizzard calls in `pcall` where the repo already does. Explain *why* in comments for secret-value and CDM taint paths.
6. **Do not port Classic-era EventHorizon / WeakAura recipes unchanged.**

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

## Done when

- New or changed Lua is Forever / Mainline 12.x–safe and consistent with existing helpers.
- No new Classic Era APIs or unguarded secret comparisons.
- Behavior still matches README / CUSTOMIZATION expectations for secret values and CDM-driven UI.
