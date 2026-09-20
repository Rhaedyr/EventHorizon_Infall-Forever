---
name: wow-mainline-12-universal
description: Shared Mainline 12.x addon rules — secret values, no CLEU, prefer C_* APIs. Use for any Midnight-era / Forever addon work.
---

# Universal Mainline 12.x addon rules

Applies to **Mainline** clients in the Midnight API family (retail **Standard** ~12.x and **Forever/Camelot**). These are differential rules, not a full API encyclopedia.

Public baseline: Forever shares Mainline’s UI architecture and the vast majority of APIs available around **12.1.5**, including Midnight’s addon disarmament (secret values) and AuraContainer/AuraButton. See [Wowhead: Forever addon changes from Midnight](https://www.wowhead.com/news/wow-forever-will-have-addon-changes-from-midnight-382921).

## Hard rules

1. **No CLEU combat pipelines.** Do not register `COMBAT_LOG_EVENT_UNFILTERED` or call `CombatLogGetCurrentEventInfo`. Reconstructing restricted combat state from chat or other side channels is also disallowed.
2. **Secret values are opaque.** Before compare, arithmetic, sort, string format that requires a number, or any API that rejects secrets, guard with `issecretvalue` (or project helpers). Prefer `C_DurationUtil` Duration objects for timing when values may be secret. Display-only sinks (many `SetValue` / texture paths) may accept secrets; **branching** must not.
3. **Prefer `C_*` namespaces** over bare pre-12 globals when both exist:
   - `C_Spell`, `C_SpellBook`, `C_SpecializationInfo`, `C_CooldownViewer`, `C_UnitAuras`, `C_Secrets`, `C_Item`, `C_DurationUtil`
4. **Do not port Classic Era / pre-Midnight WeakAura or EventHorizon CLEU recipes unchanged.**

## Prefer / avoid (quick)

| Prefer | Avoid |
| --- | --- |
| `C_Spell.GetSpellInfo` / `GetSpellCooldown` | bare `GetSpellInfo` / `GetSpellCooldown` |
| `C_SpecializationInfo.GetSpecialization*` | bare `GetSpecialization*` as the only path |
| `C_UnitAuras.*`, CDM aura frames, Duration objects | CLEU aura tracking; unguarded `UnitAura` loops for combat logic |
| `issecretvalue` + early return / cached last-known | `if unitHealth < x then` on possibly-secret numbers |
| `InCombatLockdown()` for secure UI / settings | assuming combat *power/aura* numbers stay readable |

## TOC / Interface

- **Midnight Standard** TOC `## Interface:` values are **12xxxx** (e.g. `120100`).
- **Forever 1.60.1** TOC Interface is **`16001`** (confirmed live via `GetBuildInfo()` build 69913). See [`forever/SKILL.md`](../forever/SKILL.md). Do **not** keep `120100` as a Forever placeholder.
- Forever’s `16001` is **not** Classic Era — same digit pattern, different product. Forever still uses Mainline-family Lua (secrets, CDM, `C_*`).
- A game **content** version like Forever **1.60.1** is the version string; the TOC Interface comes from `select(4, GetBuildInfo())`. Always prefer a live dump over guessing:

```lua
/dump select(4, GetBuildInfo())
```

## Severity guide for audits

- **blocker** — will error or violate disarmament (CLEU; unguarded secret compare in control flow)
- **review** — may work for display, or may differ on Forever; needs in-client verification
- **ok-with-guards** — pattern present but already pcall/`issecretvalue`/`C_*` fallback protected
