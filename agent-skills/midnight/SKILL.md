---
name: wow-midnight-standard
description: Midnight Standard (retail Mainline 12.x) specifics — secrets, AuraContainer, Cooldown Manager. Use when targeting retail Midnight.
---

# Midnight Standard (retail 12.x)

Builds on [`../universal/SKILL.md`](../universal/SKILL.md). **Standard** is Blizzard’s name for modern retail Mainline alongside Forever’s game type (Camelot → Forever).

## What Midnight added / tightened

- **Secret values** on many combat-adjacent numbers (health, power, aura durations, some cooldown fields) while restricted.
- **AuraContainer / AuraButton** (from ~12.1.0) — unit aura UI and addon-facing aura identity/timing shifts.
- **Cooldown Manager (CDM)** — `C_CooldownViewer`, viewer frames (`EssentialCooldownViewer`, `UtilityCooldownViewer`, `BuffIconCooldownViewer`, `BuffBarCooldownViewer`), Edit Mode visibility.
- **Addon disarmament** — CLEU and other combat-log driven “solve the fight for you” pipelines are not a supported design.

## Authoring expectations

1. Drive cooldown/buff **layout and identity** from CDM (`C_CooldownViewer.GetCooldownViewerCooldownInfo`, category sets, viewer item frames) when the feature is CDM-shaped.
2. For aura **timing**, prefer Duration objects (`C_DurationUtil`, `C_UnitAuras.GetAuraDuration`) and/or mirroring CDM bar values — not CLEU.
3. Probe restriction with `C_Secrets` helpers and failed `C_UnitAuras` calls; never assume unrestricted.
4. Spec reads: prefer `C_SpecializationInfo` (with optional legacy fallback only behind a thin wrapper).
5. Treat Edit Mode / CDM enum constants as **version-sensitive**; pcall and nil-check `Enum.*` before use.

## Retail vs Forever

| Topic | Midnight Standard | Forever |
| --- | --- | --- |
| API family | Mainline 12.x | Same family (~12.1.5) |
| Secrets / AuraContainer / CDM | Yes | Yes (announced) |
| Content / systems | Retail Midnight | Forever (Camelot) content |
| TOC Interface | 12xxxx from client | 12xxxx from client — **may differ**; do not copy Classic numbers |

When a change is Midnight-only (retail systems, midnight-only spells), gate it in data or feature flags — do not assume Forever has every Standard spell or UI panel.

## EventHorizon Infall examples (this repo)

- Spec wrappers: `Core.lua` → `ns.SpecIndex` / `ns.SpecInfo`
- Secret-safe auras / estimates: `AuraCompat.lua`
- CDM dirty reads & viewer hooks: `Core.lua`, `Bars.lua`
