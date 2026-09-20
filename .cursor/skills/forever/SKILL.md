---
name: wow-forever
description: WoW Forever (Camelot) specifics and how they relate to Midnight Standard. Use for Forever-targeted addon work. Confirmed TOC Interface 16001 for Forever 1.60.1.
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

## Confirmed build — Forever 1.60.1

Live client `GetBuildInfo()`:

| Return | Value |
| --- | --- |
| `[1]` version | `1.60.1` |
| `[2]` build | `69913` |
| `[3]` date | `Sep 17 2026` |
| `[4]` Interface | **`16001`** |

**TOC requirement:** Forever 1.60.1 addons must use `## Interface: 16001`. Do **not** keep `120100` / other `120xxx` as a Forever placeholder once this dump is known. Lua may still follow Midnight/Mainline patterns; the TOC Interface number is separate and **must** be `16001` for this client.

## Version naming (do not confuse)

| Label | Meaning | TOC? |
| --- | --- | --- |
| Forever **1.60.1** | Forever/Camelot **content / game** version | **No** — not itself the Interface field |
| `## Interface: **16001**` | Forever 1.60.1 UI addon Interface (confirmed) | **Yes — use this** |
| Midnight / Standard `12xxxx` | Mainline Standard Interface | **Not** for Forever-only TOCs |
| Classic `115xx` / `404xx` / `505xx` | Other flavors | **Never** for Forever |

Note: Forever’s Interface **`16001`** sits in a `1xxxx` digit range that also appears on Classic products. That is a **coincidence of numbering**, not a reason to treat Forever as Classic Era. Forever still uses Mainline-family Lua (secrets, CDM, `C_*`). Do **not** advise “avoid Classic-style 16001” for this client — **16001 is correct**.

Optional later: comma-delimited `## Interface: 16001,120xxx` **only** if dual-load with Standard is explicitly desired and evidenced.

## Forever-specific agent checklist

1. Follow universal secret / no-CLEU / `C_*` rules — Forever is not a CLEU sanctuary.
2. Prefer CDM + `C_UnitAuras` / Duration patterns already used for Midnight.
3. Mark **uncertain** any hard-coded retail-only enums, Edit Mode magic numbers, or Standard-only systems until verified in Forever.
4. Use TOC Interface **`16001`** for Forever 1.60.1. Do not recommend Classic `_Vanilla` / `_Cata` TOC suffixes, and do not leave `120100` as a Forever placeholder.
5. Content gaps (missing spells, different talent trees) are **data** issues in `ClassConfig/`, not reasons to drop secret guards.

## EventHorizon Infall on `forever` branch

- Branch targets Forever while remaining Midnight-API-compatible in Lua.
- Compat scan report: `docs/FOREVER_COMPAT_REPORT.md`
- Cursor rule (short): `.cursor/rules/forever-addon-api.mdc`
- Project agent summary: `AGENTS.md`
