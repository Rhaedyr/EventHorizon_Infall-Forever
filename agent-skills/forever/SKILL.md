---
name: wow-forever
description: WoW Forever (Camelot) specifics and how they relate to Midnight Standard. Use for Forever-targeted addon work and TOC Interface TODOs.
---

# WoW: Forever (Camelot)

Builds on [`../universal/SKILL.md`](../universal/SKILL.md) and [`../midnight/SKILL.md`](../midnight/SKILL.md).

## Relationship to Midnight

Blizzard (WoW UI Discord, via [Wowhead](https://www.wowhead.com/news/wow-forever-will-have-addon-changes-from-midnight-382921)):

- Forever and Midnight Standard are **two game types in the Mainline code family** (Camelot / Forever vs Standard).
- Forever shares **most APIs available around 12.1.5**.
- **Secrets**, **AuraContainer/AuraButton**, and similar disarmament rules are **active in Forever**.
- Future UI/API changes are expected to land on **both**.

Implication for addons: a Midnight-ready, CDM + secret-aware codebase is the correct starting point. Classic-era ports are the wrong starting point.

## Version naming (do not confuse)

| Label | Meaning | TOC? |
| --- | --- | --- |
| Forever **1.60.1** | Forever/Camelot **content / game** version | **No** — not an Interface number |
| `## Interface: 12xxxx` | Mainline UI addon Interface | **Yes** |
| Classic `115xx` / `404xx` / `505xx` | Other flavors | **Never** for Forever |

### TODO — Forever Interface for build 1.60.1

The exact `## Interface:` integer for Forever **1.60.1** is **unknown** until read from the Forever client. Do **not** invent it. Prefer keeping a known Mainline value (this repo currently uses `120100`) over guessing.

User should supply either:

```lua
/dump select(4, GetBuildInfo())
```

or the Interface line from a Forever-shipped Blizzard TOC / AddOns list once the beta client is available.

Optional later: comma-delimited `## Interface: 120100,XXXXXX` **only** if evidence shows Forever reports a different Interface than Standard and dual-load is desired.

## Forever-specific agent checklist

1. Follow universal secret / no-CLEU / `C_*` rules — Forever is not a CLEU sanctuary.
2. Prefer CDM + `C_UnitAuras` / Duration patterns already used for Midnight.
3. Mark **uncertain** any hard-coded retail-only enums, Edit Mode magic numbers, or Standard-only systems until verified in Forever.
4. Do not recommend Classic Interface numbers or `_Vanilla` / `_Cata` TOC suffixes for Forever.
5. Content gaps (missing spells, different talent trees) are **data** issues in `ClassConfig/`, not reasons to drop secret guards.

## EventHorizon Infall on `forever` branch

- Branch targets Forever while remaining Midnight-API-compatible.
- Compat scan report: `docs/FOREVER_COMPAT_REPORT.md`
- Cursor rule (short): `.cursor/rules/forever-addon-api.mdc`
- Project agent summary: `AGENTS.md`
