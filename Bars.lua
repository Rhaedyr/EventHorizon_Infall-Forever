-- EventHorizon Infall: bar creation, update loop, event handling, slash commands.

local ns = EventHorizon_Infall
local AC = ns.AuraCompat

local CONFIG = ns.CONFIG
local EH_Parent = ns.EH_Parent
local cooldownBars = ns.cooldownBars
local barPool = ns.barPool

local ADDON_NAME = ns.ADDON_NAME

CONFIG.extraCasts = CONFIG.extraCasts or {}
CONFIG.buffMappings = CONFIG.buffMappings or {}
CONFIG.stackMappings = CONFIG.stackMappings or {}
CONFIG.castColors = CONFIG.castColors or {}
CONFIG.cooldownColors = CONFIG.cooldownColors or {}
CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
CONFIG.chargesDisabled = CONFIG.chargesDisabled or {}

local activeCast
-- activeCast is row-matched only.
local sparkCast
-- Forward declared here as one table: the main chunk has a hard
-- ceiling of 200 locals and these used to spend one apiece.
local EHF = {}
local queueWindowSeconds = 0
local cachedGcdDurObj
local lastFedGcdDurObj
local shownSetupHint = false
local deferredGen = {}
local specChangeToken = 0
local specChangePending = false
local K = {
    SLIDE_KEYS = {"activeCdSlide", "activeBuffSlide", "activeOverlaySlide", "activeThirdSlide", "activeDepletedSlide", "activeChargeSlide"},
    PTR_KEYS = {"lastPtr_cd", "lastPtr_charge", "lastPtr_buff", "lastPtr_overlay", "lastPtr_third"},
    HIDDEN_KEYS = {"hidden_cd", "hidden_charge", "hidden_buff", "hidden_overlay", "hidden_third"},

    -- Combat potion aura. No readable timing exists for it under aura restrictions,
    -- so the window is self-timed from the cast and outranks lane resolution.
    POTION_BUFF_DURATION = 30,

    -- Category 4 only. GetLastCategoryCooldownSource is secret in combat;
    -- CooldownViewerCooldown is not. An id missing here draws no aura bar.
    POTION_BUFF_DURATIONS = {
        [1236616] = 30,   -- Light's Potential
        [1236998] = 30,   -- Draught of Rampant Abandon
        [1236994] = 30,   -- Potion of Recklessness
        [1238443] = 30,   -- Potion of Zealotry
    },

    SPELL_CATEGORY_COMBAT_POTION = 4,
}


local function CombatPotionRowInfo(cooldownID)
    if not cooldownID or issecretvalue(cooldownID) then return nil end
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
    if not ok or not info then return nil end
    if info.spellID or info.equipSlot then return nil end
    if info.spellCategoryID ~= K.SPELL_CATEGORY_COMBAT_POTION then return nil end
    return info
end

local function GetCooldownColor(row)
    if row.isExtras then
        local extras = CONFIG.extras
        if extras then
            for _, e in ipairs(extras) do
                if e.key == row.extrasKey then
                    return e.cdColor or CONFIG.cooldownColor
                end
            end
        end
        return CONFIG.cooldownColor
    end
    local c = CONFIG.cooldownColors[row.cooldownID]
    return c or CONFIG.cooldownColor
end

local function GetEmpowerStageColor(stage)
    if stage == 1 then return CONFIG.empowerStage1Color
    elseif stage == 2 then return CONFIG.empowerStage2Color
    elseif stage == 3 then return CONFIG.empowerStage3Color
    elseif stage == 4 then return CONFIG.empowerStage4Color
    end
    return CONFIG.empowerStage4Color
end

local function HideCastOverlays(row)
    if not row then return end
    if row.castTex then row.castTex:Hide() end
    if row.empowerStageTex then
        for _, tex in ipairs(row.empowerStageTex) do
            tex:Hide()
        end
    end
    if row.chainWindowTex then
        row.chainWindowTex:Hide()
    end
end

-- Offscreen parent for hidden Cooldown frames.
local hiddenCDParent = CreateFrame("Frame", nil, UIParent)
hiddenCDParent:SetSize(1, 1)
hiddenCDParent:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -2000, 2000)
hiddenCDParent:Show()

-- Hidden GCD cooldown; OnCooldownDone fires when GCD ends.
local gcdActive = false

local hiddenGcdCooldown = CreateFrame("Cooldown", nil, hiddenCDParent, "CooldownFrameTemplate")
hiddenGcdCooldown:SetAllPoints(hiddenCDParent)
hiddenGcdCooldown:SetDrawSwipe(false)
hiddenGcdCooldown:SetDrawBling(false)
hiddenGcdCooldown:SetDrawEdge(false)
hiddenGcdCooldown:SetHideCountdownNumbers(true)
hiddenGcdCooldown:Show()

hiddenGcdCooldown:SetScript("OnCooldownDone", function(self)
    gcdActive = false
end)


-- BinaryCurve: 0% remaining = 0, >0% = 1 (for SetDesaturation).
-- AlphaCurve: 0s remaining = 0, >0s = 1 (for SetAlpha).
local BinaryCurve = C_CurveUtil and C_CurveUtil.CreateCurve and C_CurveUtil.CreateCurve()
if BinaryCurve then
    BinaryCurve:AddPoint(0.0, 0)
    BinaryCurve:AddPoint(0.001, 1)
    BinaryCurve:AddPoint(1.0, 1)
end

local AlphaCurve = C_CurveUtil and C_CurveUtil.CreateCurve and C_CurveUtil.CreateCurve()
if AlphaCurve then
    AlphaCurve:AddPoint(0.0, 0)
    AlphaCurve:AddPoint(0.001, 1)
    AlphaCurve:AddPoint(300, 1)
end


-- Rebuilt whenever CONFIG.future changes. Built at file load it would capture
-- Core.lua's default forever: ApplyProfile runs later, from an event.
local BuffFillCurve
local buffFillCurveFuture
local function RebuildBuffFillCurve()
    if not (C_CurveUtil and C_CurveUtil.CreateCurve) then return end
    if BuffFillCurve and buffFillCurveFuture == CONFIG.future then return end
    BuffFillCurve = C_CurveUtil.CreateCurve()
    buffFillCurveFuture = CONFIG.future
    BuffFillCurve:AddPoint(0.0, CONFIG.future)
    BuffFillCurve:AddPoint(0.01, 0.01)
    BuffFillCurve:AddPoint(3600, 3600)
end
RebuildBuffFillCurve()
ns.RebuildBuffFillCurve = RebuildBuffFillCurve

local SMOOTH_INTERPOLATION = Enum and Enum.StatusBarInterpolation
    and Enum.StatusBarInterpolation.ExponentialEaseOut or nil
local function GetInterpolation()
    return CONFIG.smoothBars and SMOOTH_INTERPOLATION or nil
end


local chargeDurWarned = {}

-- Apply CONFIG font (or fallback) to a FontString at a given size.
local function ApplyFont(fontString, size)
    if CONFIG.font then
        fontString:SetFont(CONFIG.font, size, CONFIG.fontFlags)
    else
        fontString:SetFontObject(GameFontNormalLarge)
        local fontFace = fontString:GetFont()
        fontString:SetFont(fontFace, size, CONFIG.fontFlags)
    end
end

local function GetChargesWithOverride(spellID, baseSpellID)
    local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
    if not (ok and info and info.maxCharges) then
        local ovOk, ovID = pcall(C_Spell.GetOverrideSpell, baseSpellID or spellID)
        if ovOk and ovID and ovID ~= spellID then
            ok, info = pcall(C_Spell.GetSpellCharges, ovID)
        end
    end
    return info
end

local function PreCacheChargeSpells()
    InfallDB.chargeSpells = {}
    InfallDB.chargeDurations = {}

    local cooldownIDs = {}
    local success, result = pcall(function()
        return C_CooldownViewer.GetCooldownViewerCategorySet(0, true)
    end)
    if success and result then cooldownIDs = result end

    for _, cooldownID in ipairs(cooldownIDs) do
        local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
        local spellID = infoOk and cdInfo and cdInfo.spellID
        if spellID then
            local ovOk, ovID = pcall(C_Spell.GetOverrideSpell, spellID)
            local resolvedID = (ovOk and ovID and ovID ~= spellID) and ovID or spellID
            local chargeInfo = GetChargesWithOverride(resolvedID, spellID)
            if chargeInfo and chargeInfo.maxCharges then
                local override = CONFIG.chargeOverflow and CONFIG.chargeOverflow[spellID]
                local cachedMax = chargeInfo.maxCharges
                if override and override.trueMax and cachedMax > override.trueMax then
                    cachedMax = override.trueMax
                end
                InfallDB.chargeSpells[cooldownID] = {
                    hasChargeMechanic = true,
                    maxCharges = cachedMax
                }
                pcall(function()
                    if chargeInfo.cooldownDuration and chargeInfo.cooldownDuration > 0 then
                        InfallDB.chargeDurations[cooldownID] = chargeInfo.cooldownDuration
                    end
                end)
            end
        end
    end
end


local siIsBuilt = false

-- Bar spans -past..+future; "now" at (past / totalSpan) from left.

local function GetTotalSpan()
    return CONFIG.past + CONFIG.future
end

local function GetNowPixelOffset()
    return (CONFIG.past / GetTotalSpan()) * CONFIG.width
end
ns.GetNowPixelOffset = GetNowPixelOffset

local function GetFutureWidth()
    return CONFIG.width - GetNowPixelOffset()
end

local function TimeToPixel(timeOffset)
    local fraction = (timeOffset + CONFIG.past) / GetTotalSpan()
    return fraction * CONFIG.width
end

local function CleanupActiveCast(excludeRow)
    if not activeCast then return end
    if activeCast.pastSlide then
        EHF.DetachPastSlide(activeCast.pastSlide)
    end
    if activeCast.row and activeCast.row ~= excludeRow then
        HideCastOverlays(activeCast.row)
    end
end

-- straddles now line

-- A transform reports a DIFFERENT spellID than the row holds, so comparing
-- spellID and baseSpellID alone misses it. Resolve both sides, compare sets.
local function SpellIdentitySet(id)
    if not id then return nil end
    local t = { [id] = true }
    local function add(fn, arg)
        if type(fn) ~= "function" then return end
        local ok, res = pcall(fn, arg)
        if ok and not issecretvalue(res) and type(res) == "number" and res > 0 then
            t[res] = true
        end
    end
    add(C_Spell and C_Spell.GetOverrideSpell, id)
    add(C_Spell and C_Spell.GetBaseSpell, id)
    add(C_SpellBook and C_SpellBook.FindBaseSpellByID, id)
    add(C_SpellBook and C_SpellBook.FindSpellOverrideByID, id)
    return t
end

local function RowMatchesCastSpell(row, castSpellID)
    if not castSpellID then return false end
    if row.spellID == castSpellID or row.baseSpellID == castSpellID then return true end
    local castSet = SpellIdentitySet(castSpellID)
    if not castSet then return false end
    if (row.spellID and castSet[row.spellID]) or (row.baseSpellID and castSet[row.baseSpellID]) then
        return true
    end
    local rowSet = SpellIdentitySet(row.baseSpellID or row.spellID)
    return (rowSet and rowSet[castSpellID]) and true or false
end

local channelRetryPending = false

-- Channels whose final tick interval is a clip window, shaded on the cast
-- segment. The fraction is always 1/intervals, so only the interval count
-- differs per spell.
local CHANNEL_CLIP = {
    -- Disintegrate. Azure Celerity shortens the interval only, which adds one.
    [356995] = { intervals = 3, modSpell = 1219723, modIntervals = 4 },

    -- Rapid Fire. 7 shots base, so 6 intervals. Quick Draw adds 3 shots and
    -- leaves the channel length alone. The clip point is SimC's
    -- `interrupt_if=talent.unload&ticks_remain<2`, which is this last interval.
    [257044] = { missiles = 7, addMissiles = { [459794] = 3 } },
}

local function ChannelClipFraction(spellID)
    local def = CHANNEL_CLIP[spellID]
    if not def then return nil end

    local intervals
    if def.missiles then
        local shots = def.missiles
        for talentID, extra in pairs(def.addMissiles or {}) do
            if ns.IsTalentKnown(talentID) then shots = shots + extra end
        end
        intervals = shots - 1
    elseif def.modSpell and ns.IsTalentKnown(def.modSpell) then
        intervals = def.modIntervals
    else
        intervals = def.intervals
    end

    if not intervals or intervals < 1 then return nil end
    return 1 / intervals
end

local function UpdateCastBar(event, isRetry)
    local name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID
    local isChannel
    local numStages

    -- Prioritize based on event type to avoid stale data
    if event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
       or event == "UNIT_SPELLCAST_EMPOWER_START" or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        name, text, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellID, _, numStages = UnitChannelInfo("player")
        isChannel = true
        if not name then
            name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo("player")
            isChannel = false
        end
        -- UnitChannelInfo can be empty on the frame the start event fires.
        -- One retry, then the nil path below cleans up as normal.
        if not name and not isRetry and not channelRetryPending then
            channelRetryPending = true
            C_Timer.After(0, function()
                channelRetryPending = false
                UpdateCastBar(event, true)
            end)
            return
        end
    else
        name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo("player")
        if not name then
            name, text, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellID, _, numStages = UnitChannelInfo("player")
            isChannel = true
        end
    end

    -- Empowered cast: extended endTime to include hold-at-max time
    local isEmpowered = numStages and numStages > 0
    if isEmpowered and endTimeMS then
        local ok, holdTimeMS = pcall(GetUnitEmpowerHoldAtMaxTime, "player")
        if ok and holdTimeMS then
            endTimeMS = endTimeMS + holdTimeMS
        end
    end
    
    -- Recorded before the row lookup, so an untracked spell still gets a spark.
    if name and spellID and startTimeMS and endTimeMS then
        sparkCast = { endTime = endTimeMS / 1000, spellID = spellID }
    else
        sparkCast = nil
    end

    if name and spellID then
        local targetRow
        for _, row in ipairs(cooldownBars) do
            if RowMatchesCastSpell(row, spellID) then
                targetRow = row
                break
            end
            
            local extraCasts = CONFIG.extraCasts[row.cooldownID] or CONFIG.extraCasts[row.baseSpellID] or CONFIG.extraCasts[row.spellID]
            if extraCasts then
                for _, extraSpellID in ipairs(extraCasts) do
                    if extraSpellID == spellID then
                        targetRow = row
                        break
                    end
                end
            end
            
            if targetRow then break end
        end
        
        if targetRow then
            -- If this is the same cast already tracked, just update timing (channel tick, pushback)
            if activeCast and activeCast.spellID == spellID and activeCast.row == targetRow then
                local startSec = startTimeMS / 1000
                local durSec = (endTimeMS - startTimeMS) / 1000
                activeCast.isChannel = isChannel
                if isEmpowered or activeCast.hasClipWindow then
                    activeCast.startTimeSec = startSec
                end
                if C_DurationUtil and durSec > 0 then
                    local durObj = C_DurationUtil.CreateDuration()
                    durObj:SetTimeFromStart(startSec, durSec, 1)
                    activeCast.durObj = durObj
                else
                    activeCast.endTime = endTimeMS / 1000
                end
                return
            end
            
            -- Clean up previous cast if one was active (queued spell transition)
            CleanupActiveCast(targetRow)

            local startSec = startTimeMS / 1000
            local durSec = (endTimeMS - startTimeMS) / 1000
            activeCast = {
                spellID = spellID,
                row = targetRow,
                isChannel = isChannel,
                castID = castID
            }
            -- DurObj for countdown; fallback to raw endTime
            if C_DurationUtil and durSec > 0 then
                local durObj = C_DurationUtil.CreateDuration()
                durObj:SetTimeFromStart(startSec, durSec, 1)
                activeCast.durObj = durObj
            else
                activeCast.endTime = endTimeMS / 1000
            end

            -- Empowered: build stage boundary array and create stage textures
            if isEmpowered then
                activeCast.isEmpowered = true
                activeCast.startTimeSec = startSec
                local stagePoints = {}
                local cumMS = 0
                for i = 1, numStages do
                    local sOk, stageDurMS = pcall(GetUnitEmpowerStageDuration, "player", i - 1)
                    if sOk and stageDurMS and stageDurMS > 0 then
                        cumMS = cumMS + stageDurMS
                        stagePoints[i] = cumMS / 1000
                    end
                end
                -- Final boundary: hold-at-max stage
                local hOk, holdMS = pcall(GetUnitEmpowerHoldAtMaxTime, "player")
                if hOk and holdMS and holdMS > 0 then
                    stagePoints[numStages + 1] = (cumMS + holdMS) / 1000
                end
                if #stagePoints > 0 then
                    activeCast.stagePoints = stagePoints
                    activeCast.numStages = #stagePoints

                    -- Create/reuse stage textures on this row
                    if not targetRow.empowerStageTex then
                        targetRow.empowerStageTex = {}
                    end
                    for i = 1, #stagePoints do
                        if not targetRow.empowerStageTex[i] then
                            local tex = targetRow.castFrame:CreateTexture(nil, "ARTWORK")
                            tex:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                            tex:SetSnapToPixelGrid(false)
                            tex:SetTexelSnappingBias(0)
                            targetRow.empowerStageTex[i] = tex
                        end
                        local c = GetEmpowerStageColor(i)
                        targetRow.empowerStageTex[i]:SetVertexColor(unpack(c))
                        targetRow.empowerStageTex[i]:Show()
                    end
                    -- Hide extras from a previous empowered cast with more stages
                    for i = #stagePoints + 1, #targetRow.empowerStageTex do
                        targetRow.empowerStageTex[i]:Hide()
                    end

                    -- Empowered uses stage textures, hide single castTex
                    targetRow.castTex:Hide()
                end
            end

            -- Per spell cast colour: check castColors mapping, fall back to global
            local castColors = CONFIG.castColors
            local color = castColors and castColors[spellID]
            if not color then
                color = CONFIG.castColor
            end
            -- Spawn past slide (stage 1 colour for empowered, cast colour otherwise)
            local slideColor = (isEmpowered and GetEmpowerStageColor(1)) or color
            activeCast.pastSlide = EHF.SpawnPastSlide(targetRow, targetRow.pastCastClip, slideColor)

            if not isEmpowered then
                -- Non-empowered: show castTex, hide any leftover overlays
                HideCastOverlays(targetRow)
                targetRow.castTex:SetVertexColor(unpack(color))
                targetRow.castTex:Show()

                -- Clip window: coloured tail segment on the final tick interval
                local clipFraction = ChannelClipFraction(spellID)
                if clipFraction then
                    activeCast.hasClipWindow = true
                    activeCast.startTimeSec = startSec
                    activeCast.chainWindowFraction = clipFraction

                    if not targetRow.chainWindowTex then
                        local tex = targetRow.castFrame:CreateTexture(nil, "ARTWORK", nil, 1)
                        tex:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                        tex:SetSnapToPixelGrid(false)
                        tex:SetTexelSnappingBias(0)
                        targetRow.chainWindowTex = tex
                    end
                    targetRow.chainWindowTex:SetVertexColor(unpack(CONFIG.disintegrateChainColor))
                    targetRow.chainWindowTex:Show()
                end
            end
        else
            -- Casting an untracked spell, clean up any previous tracked cast
            CleanupActiveCast()
            activeCast = nil
        end
    else
        CleanupActiveCast()
        activeCast = nil
    end
end

-- One line at the cast's end, crossing every lane, moving toward the now line.

-- Named rather than a closure: this is pcall'd per pip per frame.
local function IsZero(v) return v == 0 end

-- The engine re-snaps a texture after layout, which moves a 1px rule off its anchor.
function ns.NoPixelSnap(tex)
    if not tex then return end
    tex:SetSnapToPixelGrid(false)
    tex:SetTexelSnappingBias(0)
end

local castSparkFrame, castSparkTex

function EHF.HideCastSpark()
    if castSparkFrame then castSparkFrame:Hide() end
end

local function UpdateCastSpark()
    local wantCast = CONFIG.castSpark and sparkCast
    local wantQueue = CONFIG.queueSpark and sparkCast and queueWindowSeconds > 0
    if not wantCast and not wantQueue then
        EHF.HideCastSpark()
        return
    end

    local remaining = sparkCast.endTime - GetTime()
    if remaining <= 0 then
        sparkCast = nil
        EHF.HideCastSpark()
        return
    end
    -- Past the edge of the timeline there is nowhere honest to draw it.
    if remaining > CONFIG.future then
        EHF.HideCastSpark()
        return
    end

    if not castSparkFrame then
        castSparkFrame = CreateFrame("Frame", nil, EH_Parent)
        castSparkFrame:SetFrameLevel(EH_Parent:GetFrameLevel() + 20)
        castSparkTex = castSparkFrame:CreateTexture(nil, "OVERLAY", nil, 7)
        castSparkFrame.queueTex = castSparkFrame:CreateTexture(nil, "OVERLAY", nil, 6)
        castSparkFrame.queueFill = castSparkFrame:CreateTexture(nil, "OVERLAY", nil, 4)
        ns.NoPixelSnap(castSparkTex)
        ns.NoPixelSnap(castSparkFrame.queueTex)
        ns.NoPixelSnap(castSparkFrame.queueFill)
    end
    local castQueueTex = castSparkFrame.queueTex
    local castQueueFill = castSparkFrame.queueFill

    -- Padded like a row: GetBarOffset is the icon column only.
    castSparkFrame:ClearAllPoints()
    castSparkFrame:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT",
        CONFIG.paddingLeft, -CONFIG.paddingTop)
    castSparkFrame:SetPoint("BOTTOMRIGHT", EH_Parent, "BOTTOMRIGHT",
        -CONFIG.paddingRight, CONFIG.paddingBottom)

    -- Left edge on the cast's end, matching the GCD spark's anchor.
    local x = EHF.GetBarOffset() + TimeToPixel(remaining)

    if wantCast then
        local colour = CONFIG.castSparkColor
        if CONFIG.castSparkMatchCast then
            colour = (CONFIG.castColors and CONFIG.castColors[sparkCast.spellID])
                or CONFIG.castColor or colour
        end
        castSparkTex:SetColorTexture(unpack(colour))
        castSparkTex:ClearAllPoints()
        castSparkTex:SetPoint("TOPLEFT", castSparkFrame, "TOPLEFT", x, 0)
        castSparkTex:SetPoint("BOTTOMLEFT", castSparkFrame, "BOTTOMLEFT", x, 0)
        castSparkTex:SetWidth(CONFIG.castSparkWidth or 1)
        castSparkTex:Show()
    else
        castSparkTex:Hide()
    end

    -- Only the later of the cast and the GCD draws the window.
    local gcdLeft = 0
    if gcdActive and cachedGcdDurObj then
        local gOk, gLeft = pcall(cachedGcdDurObj.GetRemainingDuration, cachedGcdDurObj)
        if gOk and not issecretvalue(gLeft) and type(gLeft) == "number" then
            gcdLeft = gLeft
        end
    end

    if wantQueue and castQueueTex and remaining > queueWindowSeconds
        and remaining >= gcdLeft then
        local qx = x - (TimeToPixel(queueWindowSeconds) - TimeToPixel(0))
        castQueueTex:SetColorTexture(unpack(CONFIG.queueSparkColor or {1, 0.82, 0, 0.8}))
        castQueueTex:ClearAllPoints()
        castQueueTex:SetPoint("TOPLEFT", castSparkFrame, "TOPLEFT", qx, 0)
        castQueueTex:SetPoint("BOTTOMLEFT", castSparkFrame, "BOTTOMLEFT", qx, 0)
        castQueueTex:SetWidth(CONFIG.queueSparkWidth or 2)
        castQueueTex:Show()
        if castQueueFill then
            castQueueFill:SetColorTexture(unpack(CONFIG.queueBarColor or {1, 0.82, 0, 0.12}))
            castQueueFill:ClearAllPoints()
            castQueueFill:SetPoint("TOPLEFT", castSparkFrame, "TOPLEFT", qx, 0)
            castQueueFill:SetPoint("BOTTOMLEFT", castSparkFrame, "BOTTOMLEFT", qx, 0)
            castQueueFill:SetWidth(math.max(x - qx, 1))
            castQueueFill:Show()
        end
    else
        if castQueueTex then castQueueTex:Hide() end
        if castQueueFill then castQueueFill:Hide() end
    end

    castSparkFrame:Show()
end

local function UpdateActiveCastBar()
    if not activeCast then return end

    local remaining
    if activeCast.durObj then
        remaining = activeCast.durObj:GetRemainingDuration()
    else
        remaining = (activeCast.endTime or 0) - GetTime()
    end


    if remaining > 0 then
        local row = activeCast.row
        local barOffset = EHF.GetBarOffset()
        local nowPx = GetNowPixelOffset()
        local rowH = row:GetHeight()

        if activeCast.isEmpowered and activeCast.stagePoints and row.empowerStageTex then
            -- Empowered: position each stage segment individually
            local elapsed = GetTime() - activeCast.startTimeSec
            local currentStage = 1
            for i = 1, activeCast.numStages do
                local tex = row.empowerStageTex[i]
                if not tex then break end

                local stageStart = (i == 1) and 0 or (activeCast.stagePoints[i - 1] or 0)
                local stageEnd = activeCast.stagePoints[i]
                if not stageEnd then break end

                if elapsed >= stageStart then currentStage = i end

                -- Convert to time-from-now (positive = future)
                local segStartFromNow = stageStart - elapsed
                local segEndFromNow = stageEnd - elapsed

                -- Clamp to visible bar range [0, remaining]
                if segStartFromNow < 0 then segStartFromNow = 0 end
                if segEndFromNow > remaining then segEndFromNow = remaining end

                if segEndFromNow <= 0 or segStartFromNow >= remaining or segEndFromNow <= segStartFromNow then
                    tex:Hide()
                else
                    local segLeftPx = TimeToPixel(segStartFromNow)
                    local segRightPx = TimeToPixel(segEndFromNow)
                    local segWidth = segRightPx - segLeftPx
                    if segWidth < 1 then segWidth = 1 end

                    tex:ClearAllPoints()
                    tex:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + segLeftPx, 0)
                    tex:SetSize(segWidth, rowH)
                    tex:Show()
                end
            end

            -- Past slide colour follows current stage
            if activeCast.pastSlide and activeCast.pastSlide.tex then
                local c = GetEmpowerStageColor(currentStage)
                activeCast.pastSlide.tex:SetVertexColor(unpack(c))
                activeCast.pastSlide.color = c
            end
        else
            -- Non-empowered cast/channel
            if activeCast.hasClipWindow and row.chainWindowTex then
                -- Disintegrate: split into main segment + chain window tail
                local elapsed = GetTime() - activeCast.startTimeSec
                local totalDur = remaining + elapsed
                local chainStartFromNow = totalDur * (1 - activeCast.chainWindowFraction) - elapsed

                if chainStartFromNow <= 0 then
                    -- Fully inside chain window: only chain colour in the future
                    row.castTex:Hide()
                    local cwRightPx = TimeToPixel(remaining)
                    local cwWidth = cwRightPx - nowPx
                    if cwWidth < 1 then cwWidth = 1 end
                    row.chainWindowTex:ClearAllPoints()
                    row.chainWindowTex:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + nowPx, 0)
                    row.chainWindowTex:SetSize(cwWidth, rowH)
                    row.chainWindowTex:Show()

                    -- Transition: detach green past slide, spawn teal one
                    if not activeCast.chainWindowPastStarted then
                        activeCast.chainWindowPastStarted = true
                        if activeCast.pastSlide then
                            EHF.DetachPastSlide(activeCast.pastSlide)
                        end
                        activeCast.pastSlide = EHF.SpawnPastSlide(row, row.pastCastClip, CONFIG.disintegrateChainColor)
                    end
                elseif chainStartFromNow >= remaining then
                    -- Chain window not visible yet, full cast colour
                    row.chainWindowTex:Hide()
                    local rightPx = TimeToPixel(remaining)
                    local texLeft = barOffset + nowPx
                    local texWidth = rightPx - nowPx
                    if texWidth < 1 then texWidth = 1 end
                    row.castTex:ClearAllPoints()
                    row.castTex:SetPoint("TOPLEFT", row, "TOPLEFT", texLeft, 0)
                    row.castTex:SetSize(texWidth, rowH)
                    row.castTex:Show()
                else
                    -- Split: main portion + chain window
                    local splitPx = TimeToPixel(chainStartFromNow)

                    -- Main cast portion: now to chain window start
                    local mainLeft = barOffset + nowPx
                    local mainWidth = splitPx - nowPx
                    if mainWidth < 1 then mainWidth = 1 end
                    row.castTex:ClearAllPoints()
                    row.castTex:SetPoint("TOPLEFT", row, "TOPLEFT", mainLeft, 0)
                    row.castTex:SetSize(mainWidth, rowH)
                    row.castTex:Show()

                    -- Chain window: chain start to end
                    local cwRightPx = TimeToPixel(remaining)
                    local cwWidth = cwRightPx - splitPx
                    if cwWidth < 1 then cwWidth = 1 end
                    row.chainWindowTex:ClearAllPoints()
                    row.chainWindowTex:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + splitPx, 0)
                    row.chainWindowTex:SetSize(cwWidth, rowH)
                    row.chainWindowTex:Show()
                end
            else
                -- Standard non-empowered: single castTex from now to remaining
                local rightPx = TimeToPixel(remaining)
                local leftPx = nowPx
                local texLeft = barOffset + leftPx
                local texWidth = rightPx - leftPx
                if texWidth < 1 then texWidth = 1 end

                row.castTex:ClearAllPoints()
                row.castTex:SetPoint("TOPLEFT", row, "TOPLEFT", texLeft, 0)
                row.castTex:SetSize(texWidth, rowH)
                row.castTex:Show()
            end
        end
    else
        -- Cast completed, detach past slide
        if activeCast.pastSlide then
            EHF.DetachPastSlide(activeCast.pastSlide)
        end
        HideCastOverlays(activeCast.row)
        activeCast = nil
    end
end

-- Spawns at now, grows left, detaches and slides out

function EHF.SpawnPastSlide(row, clip, color, height, yOffset)
    if not clip or CONFIG.past <= 0 or not CONFIG.showPastBars then return nil end
    
    height = height or clip:GetHeight()
    yOffset = yOffset or 0
    
    -- Recycle from the same clip frame only.
    local slide
    for _, s in ipairs(row.pastSlides) do
        if not s.active and s.clip == clip then
            slide = s
            slide.active = true
            slide.startTime = GetTime()
            slide.color = color
            slide.detachTime = nil
            slide.detachWidth = nil
            slide.height = height
            slide.yOffset = yOffset
            break
        end
    end
    
    if not slide then
        local tex = clip:CreateTexture(nil, "ARTWORK")
        tex:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
        slide = {
            tex = tex,
            active = true,
            startTime = GetTime(),
            color = color,
            detachTime = nil,
            detachWidth = nil,
            height = height,
            yOffset = yOffset,
            clip = clip,
        }
        table.insert(row.pastSlides, slide)
    end
    
    slide.tex:SetSize(1, height)
    slide.tex:SetVertexColor(color[1], color[2], color[3], color[4] or 0.7)
    slide.tex:ClearAllPoints()
    slide.tex:SetPoint("TOPRIGHT", clip, "TOPRIGHT", 0, -yOffset)
    slide.tex:Show()
    
    return slide
end

function EHF.DetachPastSlide(slide)
    if not slide or not slide.active or slide.detachTime then return end
    slide.detachTime = GetTime()
    local pastWidth = GetNowPixelOffset()
    if pastWidth <= 0 then
        slide.tex:Hide()
        slide.active = false
        return
    end
    local pxPerSec = pastWidth / CONFIG.past
    local age = slide.detachTime - slide.startTime
    local w = math.min(age * pxPerSec, pastWidth)
    -- Frozen for the slide's whole life, so a fractional value here is a permanent
    -- half pixel edge, not a transient one.
    local onePx = ns.OnePxForFrame(EH_Parent)
    if not onePx or onePx <= 0 then onePx = 1 end
    w = math.floor(w / onePx + 0.5) * onePx
    slide.detachWidth = math.max(onePx, w)
end


local function UpdatePastSlides()
    local now = GetTime()
    local pastWidth = GetNowPixelOffset()
    if pastWidth <= 0 then return end
    
    local pxPerSec = pastWidth / CONFIG.past
    local onePx = ns.OnePxForFrame(EH_Parent)
    if not onePx or onePx <= 0 then onePx = 1 end

    for _, row in ipairs(cooldownBars) do
        if row.pastSlides then
            for _, slide in ipairs(row.pastSlides) do
                if slide.active then
                    if not slide.detachTime then
                        local age = now - slide.startTime
                        local w = math.min(age * pxPerSec, pastWidth)
                        w = math.floor(w / onePx + 0.5) * onePx
                        if w < onePx then w = onePx end
                        slide.tex:SetWidth(w)
                        slide.tex:SetHeight(slide.height)
                    else
                        local sinceDetach = now - slide.detachTime
                        local slideOffset = sinceDetach * pxPerSec
                        slideOffset = math.floor(slideOffset / onePx + 0.5) * onePx
                        if slideOffset > pastWidth then
                            slide.tex:Hide()
                            slide.active = false
                        else
                            slide.tex:SetWidth(slide.detachWidth)
                            slide.tex:ClearAllPoints()
                            slide.tex:SetPoint("TOPRIGHT", slide.clip, "TOPRIGHT", -slideOffset, -slide.yOffset)
                        end
                    end
                end
            end
        end
    end
end

local QUEUED_DEFAULT = {1, 1, 1, 0.22}

local function UpdateIconState(row)
    if CONFIG.hideIcons then return end
    if not row.spellID then return end

    -- Queued composes over cooldown, ready and buff alike, so it is not gated on
    -- reactiveIcons.
    if row.iconQueued then
        local q = false
        if CONFIG.iconQueued ~= false and C_Spell and C_Spell.IsCurrentSpell then
            local okQ, isQ = pcall(C_Spell.IsCurrentSpell, row.spellID)
            q = okQ and isQ and true or false
        end
        if q then
            local c = CONFIG.iconQueuedColor or QUEUED_DEFAULT
            row.iconQueued:SetColorTexture(c[1], c[2], c[3], c[4] or 0.22)
            row.iconQueued:Show()
        else
            row.iconQueued:Hide()
        end
    end

    if not CONFIG.reactiveIcons then
        row.icon:SetVertexColor(unpack(CONFIG.iconUsableColor))
        return
    end
    
    local ok = pcall(function()
        local isUsable, notEnoughMana = C_Spell.IsSpellUsable(row.spellID)
        local inRange
        if C_Spell.SpellHasRange(row.spellID) then
            inRange = C_Spell.IsSpellInRange(row.spellID, "target")
        end
        
        if inRange == false then
            row.icon:SetVertexColor(unpack(CONFIG.iconNotInRangeColor))
        elseif not isUsable and notEnoughMana then
            row.icon:SetVertexColor(unpack(CONFIG.iconNotEnoughManaColor))
        elseif not isUsable then
            row.icon:SetVertexColor(unpack(CONFIG.iconNotUsableColor))
        else
            row.icon:SetVertexColor(unpack(CONFIG.iconUsableColor))
        end
    end)
    
    if not ok then
        row.icon:SetVertexColor(unpack(CONFIG.iconUsableColor))
    end
end

local function UpdateAllIconStates()
    for _, row in ipairs(cooldownBars) do
        UpdateIconState(row)
    end
end

local function HandleProcGlow(row, show)
    row.isGlowing = show
    if not CONFIG.reactiveIcons then return end
    if CONFIG.hideIcons then return end

    if show then
        if row.iconBorder then row.iconBorder:SetColorTexture(1, 0.82, 0, 1) end
        if row.innerGlowAnim then row.innerGlowAnim:Play() end
        if row.glowAnim then row.glowAnim:Play() end
        if row.iconGlow then row.iconGlow:Show() end
    else
        if row.iconBorder then row.iconBorder:SetColorTexture(0, 0, 0, 1) end
        if row.innerGlowAnim then row.innerGlowAnim:Stop() end
        if row.glowAnim then row.glowAnim:Stop() end
        if row.innerGlow then row.innerGlow:SetAlpha(0) end
        if row.iconGlow then row.iconGlow:Hide() end
    end
end


-- Space left of the bars when icons are off. Zero puts them flush.
local function HiddenIconWidth()
    return math.max(0, CONFIG.hiddenIconWidth or 0)
end

-- Icon while there is one, bar lane when there is not. The icon box is a few
-- pixels wide with icons off, so anchor points inside it are indistinguishable.
local function TextAnchorHome(row)
    if CONFIG.hideIcons then return row.barTextOverlay or row.textOverlay end
    return row.textOverlay
end

local function ApplyTextAnchors(row)
    local home = TextAnchorHome(row)
    if not home then return end
    if row.chargeText then
        row.chargeText:ClearAllPoints()
        row.chargeText:SetPoint(CONFIG.chargeTextAnchor, home,
            CONFIG.chargeTextRelPoint, CONFIG.chargeTextOffsetX, CONFIG.chargeTextOffsetY)
    end
    if row.stackText then
        row.stackText:ClearAllPoints()
        row.stackText:SetPoint(CONFIG.stackTextAnchor, home,
            CONFIG.stackTextRelPoint, CONFIG.stackTextOffsetX, CONFIG.stackTextOffsetY)
    end
end
ns.ApplyTextAnchors = ApplyTextAnchors

-- Settings call this rather than a full reload: a text offset does not need one,
-- and it re-anchors every live row instead of relying on the rebuild path.
function ns.RefreshTextAnchors()
    for _, row in ipairs(cooldownBars) do
        ApplyTextAnchors(row)
    end
end

-- Whole physical pixels. Snapping the height alone is NOT enough: the separator
-- rides on the pitch, and a pitch off the grid drifts by lane index.
local lanePitchCache = setmetatable({}, { __mode = "k" })

local function ChargeLaneMetrics(frame, barHeight, maxC)
    maxC = math.max(2, maxC or 2)
    local _, physH = GetPhysicalScreenSize()
    local es = (frame and frame:GetEffectiveScale()) or 1
    if es <= 0 then es = 1 end
    if not physH or physH <= 0 then
        local raw = (barHeight - (maxC - 1)) / maxC
        return math.max(1, raw), math.max(1, raw) + 1
    end
    local onePx = ns.OnePx(es)
    local totalPx = math.max(1, math.floor(barHeight / onePx + 0.5))
    local sepPx = math.max(1, math.floor(1 / onePx + 0.5))
    local laneP = math.max(1, math.floor((totalPx - (maxC - 1) * sepPx) / maxC))
    return laneP * onePx, (laneP + sepPx) * onePx
end

-- Set alongside laneHeight, read wherever a lane's y offset is derived.
local function SetChargeLaneMetrics(row, barHeight, maxC)
    local h, pitch = ChargeLaneMetrics(row, barHeight, maxC)
    row.cdBar.laneHeight = h
    lanePitchCache[row] = pitch
    return h, pitch
end

local function ChargeLanePitch(row, laneH)
    return lanePitchCache[row] or ((laneH or 0) + 1)
end

local function ChargeBottomY(row, laneH, maxC)
    return -((math.max(2, maxC or 2) - 1) * ChargeLanePitch(row, laneH))
end
ns.ChargeLanePitch = ChargeLanePitch

function EHF.GetBarOffset()
    if CONFIG.hideIcons then
        return HiddenIconWidth()
    else
        return CONFIG.iconSize + (CONFIG.iconGap or 10)
    end
end
ns.GetBarOffset = EHF.GetBarOffset
ns.TimeToPixel = TimeToPixel

function EHF.GetContainerWidth()
    local barOffset = EHF.GetBarOffset()
    return CONFIG.paddingLeft + barOffset + CONFIG.width + CONFIG.paddingRight
end

local function ApplyIconMode(row)
    local barOffset = EHF.GetBarOffset()
    local nowPx = GetNowPixelOffset()
    local futureWidth = GetFutureWidth()
    
    if CONFIG.hideIcons then
        row.icon:Hide()
        row.iconBorder:Hide()
        if row.cooldownFrame then row.cooldownFrame:Hide() end
        row.innerGlow:Hide()
        if row.iconGlow then row.iconGlow:Hide() end
        if row.innerGlowAnim and row.innerGlowAnim:IsPlaying() then row.innerGlowAnim:Stop() end
        if row.glowAnim and row.glowAnim:IsPlaying() then row.glowAnim:Stop() end

        -- A frame cannot be zero wide; 1px and empty.
        row.iconContainer:SetSize(math.max(1, HiddenIconWidth()), CONFIG.height)
        if row.textOverlay then row.textOverlay:SetAllPoints(row.iconContainer) end
        ApplyTextAnchors(row)
    else
        row.icon:Show()
        row.iconBorder:Show()
        row.innerGlow:SetAlpha(0)  -- default hidden state, procs will show it

        row.iconContainer:SetSize(CONFIG.iconSize, CONFIG.iconSize)
        if row.textOverlay then row.textOverlay:SetAllPoints(row.iconContainer) end
        ApplyTextAnchors(row)
        row.iconBorder:SetSize(CONFIG.iconSize + 2, CONFIG.iconSize + 2)
        row.innerGlow:ClearAllPoints()
        row.innerGlow:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        row.innerGlow:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", CONFIG.iconSize, 0)
        if row.iconGlow then
            row.iconGlow:ClearAllPoints()
            row.iconGlow:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            row.iconGlow:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", CONFIG.iconSize, 0)
        end
    end

    local nowOffset = barOffset + nowPx
    
    row.cdBar:ClearAllPoints()
    row.cdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.cdBar:SetWidth(futureWidth)
    
    row.buffBar:ClearAllPoints()
    row.buffBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBar:SetSize(futureWidth, row:GetHeight())
    
    row.buffBarOverlay:ClearAllPoints()
    row.buffBarOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBarOverlay:SetSize(futureWidth, row:GetHeight())

    row.buffBarThird:ClearAllPoints()
    row.buffBarThird:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBarThird:SetSize(futureWidth, row:GetHeight())

    row.gcdBar:ClearAllPoints()
    row.gcdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.gcdBar:SetSize(futureWidth, row:GetHeight())
    
    -- GCD spark
    row.gcdSpark:ClearAllPoints()
    row.gcdSpark:SetPoint("LEFT", row, "LEFT", nowOffset, 0)
    
    -- Now line texture
    if row.nowLine then
        row.nowLine:ClearAllPoints()
        row.nowLine:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + nowPx - (CONFIG.nowLineWidth / 2), 0)
        row.nowLine:SetSize(CONFIG.nowLineWidth, row:GetHeight())
        row.nowLine:SetColorTexture(unpack(CONFIG.nowLineColor))
        row.nowLine:Show()
    end
    
    -- Past clip frames
    local pastWidth = GetNowPixelOffset()
    local pastClips = {row.pastCdClip, row.pastBuffClip, row.pastOverlayClip, row.pastThirdClip, row.pastCastClip}
    for _, clip in ipairs(pastClips) do
        if clip then
            clip:ClearAllPoints()
            clip:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset, 0)
            clip:SetSize(pastWidth, row:GetHeight())
        end
    end

    row.cdBar:SetStatusBarColor(unpack(GetCooldownColor(row)))
    -- Extras buff colour (extras bars skip UpdateBuffState, so apply here)
    if row.isExtras then
        local extras = CONFIG.extras
        if extras then
            for _, e in ipairs(extras) do
                if e.key == row.extrasKey then
                    local bc = e.buffColor or CONFIG.buffColor
                    row.buffBar:SetStatusBarColor(bc[1], bc[2], bc[3], bc[4] or 1)
                    row.resolvedBuffColor = bc
                    break
                end
            end
        end
    end
    if row.castTex then row.castTex:SetVertexColor(unpack(CONFIG.castColor)) end
    row.gcdBar:SetStatusBarColor(unpack(CONFIG.gcdColor))
    row.gcdSpark:SetColorTexture(unpack(CONFIG.gcdSparkColor))
    row.gcdSpark:SetSize(CONFIG.gcdSparkWidth or 2, row:GetHeight())
    if row.queueSpark then
        row.queueSpark:SetColorTexture(unpack(CONFIG.queueSparkColor or {1, 0.82, 0, 0.8}))
        row.queueSpark:SetSize(CONFIG.queueSparkWidth or 2, row:GetHeight())
    end
    if row.queueBar then
        row.queueBar:SetColorTexture(unpack(CONFIG.queueBarColor or {1, 0.82, 0, 0.12}))
        row.queueBar:SetHeight(row:GetHeight())
    end

    if row.barTextOverlay then
        row.barTextOverlay:ClearAllPoints()
        row.barTextOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset, 0)
        row.barTextOverlay:SetSize(CONFIG.width, row:GetHeight())
    end

    -- Which frame the text hangs off flips with the icon toggle.
    ApplyTextAnchors(row)
end

local function ApplyBuffLayer(row)
    local baseLevel = row:GetFrameLevel()
    if CONFIG.buffLayerAbove then
        -- Buff above cooldown
        row.cdBar:SetFrameLevel(baseLevel + 1)
        row.buffBar:SetFrameLevel(baseLevel + 3)
        row.buffBarOverlay:SetFrameLevel(baseLevel + 4)
        row.buffBarThird:SetFrameLevel(baseLevel + 5)
        row.castFrame:SetFrameLevel(baseLevel + 6)
        row.gcdBar:SetFrameLevel(baseLevel + 7)
    else
        -- Buff below cooldown
        row.buffBar:SetFrameLevel(baseLevel + 1)
        row.buffBarOverlay:SetFrameLevel(baseLevel + 2)
        row.buffBarThird:SetFrameLevel(baseLevel + 3)
        row.cdBar:SetFrameLevel(baseLevel + 4)
        row.castFrame:SetFrameLevel(baseLevel + 6)
        row.gcdBar:SetFrameLevel(baseLevel + 7)
    end
    -- Charge wrappers + indicator match cdBar level
    local cdLevel = row.cdBar:GetFrameLevel()
    if row.depletedIndicator then row.depletedIndicator:SetFrameLevel(cdLevel) end
    if row.depletedWrapper then row.depletedWrapper:SetFrameLevel(cdLevel) end
    if row.notDepletedWrapper then row.notDepletedWrapper:SetFrameLevel(cdLevel) end
    if row.middleClipIndicators then
        for _, ind in pairs(row.middleClipIndicators) do ind:SetFrameLevel(cdLevel) end
    end
    if row.middleClipWrappers then
        for _, wrap in pairs(row.middleClipWrappers) do wrap:SetFrameLevel(cdLevel) end
    end
    -- Past clip frames mirror their future counterparts' frame levels
    if row.pastCdClip then
        row.pastCdClip:SetFrameLevel(cdLevel)
    end
    if row.pastBuffClip then
        row.pastBuffClip:SetFrameLevel(row.buffBar:GetFrameLevel())
    end
    if row.pastOverlayClip then
        row.pastOverlayClip:SetFrameLevel(row.buffBarOverlay:GetFrameLevel())
    end
    if row.pastThirdClip then
        row.pastThirdClip:SetFrameLevel(row.buffBarThird:GetFrameLevel())
    end
    if row.pastCastClip then
        row.pastCastClip:SetFrameLevel(row.castFrame:GetFrameLevel())
    end
    -- Now line always on top
    if row.nowLineFrame then
        row.nowLineFrame:SetFrameLevel(baseLevel + 8)
    end
end
ns.ApplyBuffLayer = ApplyBuffLayer

local function ApplyLayoutToAllBars()
    -- Snapped so the box ends on a whole pixel. Timeline geometry reads CONFIG.width.
    EH_Parent:SetWidth(ns.SnapPx(EHF.GetContainerWidth(), ns.OnePxForFrame(EH_Parent)))
    
    EHF.ResizeContainer()
    
    local rowWidth = EH_Parent:GetWidth() - CONFIG.paddingLeft - CONFIG.paddingRight
    for _, row in ipairs(cooldownBars) do
        row:SetWidth(rowWidth)
        ApplyIconMode(row)
        ApplyBuffLayer(row)
    end
    
    if not CONFIG.hideIcons then
        UpdateAllIconStates()
    end
    
    EHF.CreateTimeLines()
    if EHF.SyncStackContainerLayout then EHF.SyncStackContainerLayout() end
end

local function UpdateAllMinMax()
    RebuildBuffFillCurve()
    for _, row in ipairs(cooldownBars) do
        if row.cdBar then row.cdBar:SetMinMaxValues(0, CONFIG.future) end
        if row.buffBar then row.buffBar:SetMinMaxValues(0, CONFIG.future) end
        if row.buffBarOverlay then row.buffBarOverlay:SetMinMaxValues(0, CONFIG.future) end
        if row.buffBarThird then row.buffBarThird:SetMinMaxValues(0, CONFIG.future) end
        if row.gcdBar then row.gcdBar:SetMinMaxValues(0, CONFIG.future) end
    end
end
ns.UpdateAllMinMax = UpdateAllMinMax

local function CrispBar(bar)
    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
    end
end

local function CreateStatusBar(parent, maxVal)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    bar:SetMinMaxValues(0, maxVal or CONFIG.future)
    bar:SetOrientation("HORIZONTAL")
    bar:GetStatusBarTexture():SetHorizTile(false)
    bar:GetStatusBarTexture():SetVertTile(false)
    CrispBar(bar)
    return bar
end

local hiddenKeys = {
    cd      = { frame = "hidden_cd",      ptr = "lastPtr_cd" },
    charge  = { frame = "hidden_charge",  ptr = "lastPtr_charge" },
    buff    = { frame = "hidden_buff",    ptr = "lastPtr_buff" },
    overlay = { frame = "hidden_overlay", ptr = "lastPtr_overlay" },
    third   = { frame = "hidden_third",   ptr = "lastPtr_third" },
}

local function CreateHiddenCooldown(rowRef, timerType)
    local cd = CreateFrame("Cooldown", nil, hiddenCDParent, "CooldownFrameTemplate")
    cd:SetAllPoints(hiddenCDParent)
    cd:SetDrawSwipe(false)
    cd:SetDrawBling(false)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(true)
    cd:SetCooldown(0, 0)

    cd:SetScript("OnCooldownDone", function(self)
        if timerType == "cd" then
            if rowRef.isChargeSpell then
                -- Charge past slides detach via texture checks in the per-frame loop.
                EHF.UpdateChargeState(rowRef)
                EHF.UpdateDesaturation(rowRef)
            else
                if rowRef.activeCdSlide then
                    EHF.DetachPastSlide(rowRef.activeCdSlide)
                    rowRef.activeCdSlide = nil
                end
                rowRef.activeCooldown = nil
                rowRef.cdBar:Hide()
                if rowRef.cooldownFrame then rowRef.cooldownFrame:Hide() end
                EHF.UpdateDesaturation(rowRef)
            end
        elseif timerType == "charge" then
            EHF.UpdateChargeState(rowRef)
            EHF.UpdateDesaturation(rowRef)
        elseif timerType == "buff" then
            if rowRef.activeBuffSlide then
                EHF.DetachPastSlide(rowRef.activeBuffSlide)
                rowRef.activeBuffSlide = nil
            end
            rowRef.activeBuffDuration = nil
            rowRef.buffBar:Hide()
        elseif timerType == "overlay" then
            if rowRef.activeOverlaySlide then
                EHF.DetachPastSlide(rowRef.activeOverlaySlide)
                rowRef.activeOverlaySlide = nil
            end
            rowRef.activeBuffOverlayDuration = nil
            if rowRef.buffBarOverlay then rowRef.buffBarOverlay:Hide() end
        elseif timerType == "third" then
            if rowRef.activeThirdSlide then
                EHF.DetachPastSlide(rowRef.activeThirdSlide)
                rowRef.activeThirdSlide = nil
            end
            rowRef.activeBuffThirdDuration = nil
            if rowRef.buffBarThird then rowRef.buffBarThird:Hide() end
        end
    end)

    return cd
end

-- Style the engine countdown FontString on first feed (position, size, colour from CONFIG)
local function StyleCdText(row)
    if row.cdTextCooldown and not row._cdTextStyled then
        local fsOk, fs = pcall(row.cdTextCooldown.GetCountdownFontString, row.cdTextCooldown)
        if fsOk and fs then
            fs:ClearAllPoints()
            fs:SetPoint(CONFIG.cdDurationTextAnchor, row.barTextOverlay, CONFIG.cdDurationTextRelPoint, CONFIG.cdDurationTextOffsetX, CONFIG.cdDurationTextOffsetY)
            ApplyFont(fs, CONFIG.cdDurationTextSize or CONFIG.fontSize)
            fs:SetTextColor(unpack(CONFIG.cdDurationTextColor))
            row._cdTextStyled = true
        end
    end
end

-- Feed cdTextCooldown with toggle gate , single entry point for all cd duration text
local function FeedCdText(row, durObj)
    if not row.cdTextCooldown then return end
    if not CONFIG.showCooldownDuration then
        row.cdTextCooldown:SetCooldown(0, 0)
        return
    end
    if durObj then
        pcall(row.cdTextCooldown.SetCooldownFromDurationObject, row.cdTextCooldown, durObj, true)
        StyleCdText(row)
    else
        row.cdTextCooldown:SetCooldown(0, 0)
    end
end

local function FeedHiddenCooldown(rowRef, timerType, durObj, clearIfZero)
    local keys = hiddenKeys[timerType]
    if not keys then return end
    local cd = rowRef[keys.frame]
    if not cd then return end
    local oldPtr = rowRef[keys.ptr]
    if durObj == oldPtr then return end
    rowRef[keys.ptr] = durObj

    local doClearIfZero = clearIfZero ~= false
    if durObj then
        pcall(cd.SetCooldownFromDurationObject, cd, durObj, doClearIfZero)
    else
        cd:SetCooldown(0, 0)
    end

    -- Feed duration text cooldown alongside cd timer
    if timerType == "cd" then FeedCdText(rowRef, durObj) end
end

-- Raw write that also updates the pointer cache. FeedHiddenCooldown early-returns
-- on a matching pointer, so a stale cache makes the next clear a no-op.
local function FeedHiddenCooldownRaw(rowRef, timerType, durObj)
    local keys = hiddenKeys[timerType]
    if not keys then return end
    local cd = rowRef[keys.frame]
    if not cd then return end
    if durObj then
        pcall(cd.SetCooldownFromDurationObject, cd, durObj)
    else
        cd:SetCooldown(0, 0)
    end
    rowRef[keys.ptr] = durObj
end

function EHF.ArmPotionWindow(row, windowSeconds)
    if not row or not row.buffBar then return end
    local window = windowSeconds or K.POTION_BUFF_DURATION
    local now = GetTime()
    local durObj = C_DurationUtil.CreateDuration()
    durObj:SetTimeFromStart(now, window)
    local buffColor = CONFIG.potionBuffColor or CONFIG.buffColor
    row.activeBuffDuration = durObj
    row._potionWindowExpiry = now + window
    row._auraMirrorCdID = nil
    row.resolvedBuffColor = buffColor
    row.trackedBuffAuraInstanceID = nil
    row.buffBar:SetStatusBarColor(buffColor[1], buffColor[2], buffColor[3], buffColor[4] or 1)
    FeedHiddenCooldown(row, "buff", durObj)
    if not row.buffBar:IsShown() then
        row.buffBar:SetValue(0)
        row.buffBar:Show()
    end
end

local function FeedChargeIndicators(row, chargeInfo)
    if not chargeInfo then return end
    local cc = chargeInfo.currentCharges
    if ns.ChargePast_Push then ns.ChargePast_Push(row, cc) end
    row.depletedIndicator:SetValue(cc)
    if row.ndHelperSpacer then row.ndHelperSpacer:SetValue(cc) end
    if row.middleClipIndicators then
        for _, ind in pairs(row.middleClipIndicators) do ind:SetValue(cc) end
    end
    if row.middleLanes then
        for _, ml2 in ipairs(row.middleLanes) do
            if ml2.helperSpacer then ml2.helperSpacer:SetValue(cc) end
        end
    end
    -- Never concatenated: currentCharges has no NeverSecret flag.
    if row.chargeText and row.hasCharges then
        row.chargeText:SetText(cc)
    end
end

-- Event-driven charge bar fill via SetTimerDuration.
local IMM_INTERP = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate
local REMAIN_DIR = Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime
function EHF.FeedChargeBarTimers(row)
    if not row.isChargeSpell or not row.depletedWrapper then return end

    if row.baseSpellID then
        local ovOk, ovID = pcall(C_Spell.GetOverrideSpell, row.baseSpellID)
        if ovOk and ovID and ovID ~= 0 then row.spellID = ovID end
    end

    local chargeOk, chargeDurObj = pcall(C_Spell.GetSpellChargeDuration, row.spellID)
    if not chargeOk then chargeDurObj = nil end
    local cdOk, cdDurObj = pcall(C_Spell.GetSpellCooldownDuration, row.spellID, true)
    if not cdOk then cdDurObj = nil end
    local cdInfoOk, cdInfo = pcall(C_Spell.GetSpellCooldown, row.spellID)
    local isOnGCD = cdInfoOk and cdInfo and cdInfo.isOnGCD
    if isOnGCD then cdDurObj = nil end

    local chargesOk, chargeInfo = pcall(C_Spell.GetSpellCharges, row.spellID)
    if chargesOk then FeedChargeIndicators(row, chargeInfo) end

    row._chargeDurObj = chargeDurObj
    row._cdDurObj = cdDurObj

    FeedHiddenCooldown(row, "charge", chargeDurObj, false)
    if chargesOk and chargeInfo and chargeInfo.isActive == false then
        if row.hidden_charge then row.hidden_charge:SetCooldown(0, 0) end
        row.lastPtr_charge = nil
    end
    FeedHiddenCooldown(row, "cd", cdDurObj)

    local timed = chargeDurObj and IMM_INTERP and REMAIN_DIR
        and not row._chargeDurUnknown
    if timed then
        row.depletedChargeBar:SetTimerDuration(chargeDurObj, IMM_INTERP, REMAIN_DIR)
        row.normalChargeBar:SetTimerDuration(chargeDurObj, IMM_INTERP, REMAIN_DIR)
    else
        row.depletedChargeBar:SetValue(0)
        row.normalChargeBar:SetValue(0)
    end

    if row.middleLanes and row.maxCharges and row.maxCharges > 2 then
        for j = 1, row.maxCharges - 2 do
            local ml = row.middleLanes[j]
            if ml then
                if timed then
                    ml.depletedChargeBar:SetTimerDuration(chargeDurObj, IMM_INTERP, REMAIN_DIR)
                else
                    ml.depletedChargeBar:SetValue(0)
                end
            end
        end
    end
end

local function CreateCooldownBar(spellID, index)
    local barOffset = EHF.GetBarOffset()
    
    local row = CreateFrame("Frame", nil, EH_Parent)
    row:SetSize(EH_Parent:GetWidth() - CONFIG.paddingLeft - CONFIG.paddingRight, CONFIG.height)
    row:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - ((index - 1) * (CONFIG.height + CONFIG.spacing)))
    row:SetClipsChildren(true)
    
    row.iconContainer = CreateFrame("Frame", nil, row)
    if CONFIG.hideIcons then
        row.iconContainer:SetSize(math.max(1, HiddenIconWidth()), CONFIG.height)
    else
        row.iconContainer:SetSize(CONFIG.iconSize, CONFIG.iconSize)
    end
    row.iconContainer:SetPoint("LEFT", row, "LEFT", 0, 0)
    
    row.icon = row.iconContainer:CreateTexture(nil, "OVERLAY")
    row.icon:SetAllPoints(row.iconContainer)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon:SetSnapToPixelGrid(false)
    row.icon:SetTexelSnappingBias(0)
    
    -- Sublevel 1: over the art, under the proc glow at 2. Same layering as the strip.
    row.iconQueued = row.iconContainer:CreateTexture(nil, "OVERLAY", nil, 1)
    row.iconQueued:SetAllPoints(row.iconContainer)
    row.iconQueued:Hide()

    -- Inner glow for procs (anchored to visible icon rectangle)
    row.innerGlow = row.iconContainer:CreateTexture(nil, "OVERLAY")
    row.innerGlow:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.innerGlow:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", CONFIG.iconSize, 0)
    row.innerGlow:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
    row.innerGlow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    row.innerGlow:SetBlendMode("ADD")
    row.innerGlow:SetVertexColor(1, 1, 0.5, 0)

    row.innerGlowAnim = row.innerGlow:CreateAnimationGroup()
    row.innerGlowAnim:SetLooping("BOUNCE")

    local fadeIn = row.innerGlowAnim:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(0.8)
    fadeIn:SetDuration(0.6)
    fadeIn:SetSmoothing("IN_OUT")

    local fadeOut = row.innerGlowAnim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(0.8)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.6)
    fadeOut:SetSmoothing("IN_OUT")
    fadeOut:SetStartDelay(0.6)
    
    local spellInfo = spellID and C_Spell.GetSpellInfo(spellID) or nil
    if spellInfo then
        row.icon:SetTexture(spellInfo.iconID)
        row.spellName = spellInfo.name
    else
        row.icon:SetColorTexture(0.5, 0.5, 0.5, 1)
        row.spellName = "Unknown"
    end
    
    row.iconBorder = row.iconContainer:CreateTexture(nil, "BORDER")
    row.iconBorder:SetSize(CONFIG.iconSize + 2, CONFIG.iconSize + 2)
    row.iconBorder:SetPoint("CENTER", row.iconContainer, "CENTER")
    row.iconBorder:SetColorTexture(0, 0, 0, 1)
    
    row.iconGlow = row.iconContainer:CreateTexture(nil, "OVERLAY", nil, 2)
    row.iconGlow:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.iconGlow:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", CONFIG.iconSize, 0)
    row.iconGlow:SetColorTexture(1, 0.95, 0.3, 0.4)
    row.iconGlow:SetBlendMode("ADD")
    row.iconGlow:Hide()
    
    row.glowAnim = row.iconGlow:CreateAnimationGroup()
    row.glowAnim:SetLooping("BOUNCE")
    local pulse = row.glowAnim:CreateAnimation("Alpha")
    pulse:SetFromAlpha(0.3)
    pulse:SetToAlpha(0.7)
    pulse:SetDuration(0.6)
    pulse:SetSmoothing("IN_OUT")
    
    row.textOverlay = CreateFrame("Frame", nil, EH_Parent)
    row.textOverlay:SetAllPoints(row.iconContainer)
    row.textOverlay:SetFrameLevel(row.iconContainer:GetFrameLevel() + 10)
    
    row.chargeText = row.textOverlay:CreateFontString(nil, "OVERLAY")
    row.chargeText:SetPoint(CONFIG.chargeTextAnchor, row.textOverlay, CONFIG.chargeTextRelPoint, CONFIG.chargeTextOffsetX, CONFIG.chargeTextOffsetY)
    ApplyFont(row.chargeText, CONFIG.fontSize)
    row.chargeText:SetTextColor(unpack(CONFIG.chargeTextColor))
    row.chargeText:Hide()

    row.stackText = row.textOverlay:CreateFontString(nil, "OVERLAY")
    row.stackText:SetPoint(CONFIG.stackTextAnchor, row.textOverlay, CONFIG.stackTextRelPoint, CONFIG.stackTextOffsetX, CONFIG.stackTextOffsetY)
    ApplyFont(row.stackText, CONFIG.fontSize)
    row.stackText:SetTextColor(unpack(CONFIG.stackTextColor))
    row.stackText:Hide()

    -- Variant name text, shown on the bar area (right of icon, vertically centred)
    row.barTextOverlay = CreateFrame("Frame", nil, EH_Parent)
    row.barTextOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset, 0)
    row.barTextOverlay:SetSize(CONFIG.width, CONFIG.height)
    row.barTextOverlay:SetFrameLevel(row.iconContainer:GetFrameLevel() + 11)

    row.variantNameText = row.barTextOverlay:CreateFontString(nil, "OVERLAY")
    row.variantNameText:SetPoint(CONFIG.variantTextAnchor, row.barTextOverlay, CONFIG.variantTextRelPoint, CONFIG.variantTextOffsetX, CONFIG.variantTextOffsetY)
    ApplyFont(row.variantNameText, CONFIG.variantTextSize or (CONFIG.fontSize - 2))
    row.variantNameText:SetTextColor(unpack(CONFIG.variantTextColor))
    row.variantNameText:Hide()

    -- Engine-driven cooldown duration text (text-only Cooldown frame).
    local cdTextOk, cdTextFrame = pcall(CreateFrame, "Cooldown", nil, row.barTextOverlay, "CooldownFrameTemplate")
    if cdTextOk and cdTextFrame then
        row.cdTextCooldown = cdTextFrame
        row._cdTextStyled = false
        cdTextFrame:SetAllPoints(row.barTextOverlay)
        cdTextFrame:EnableMouse(false)
        pcall(cdTextFrame.SetDrawSwipe, cdTextFrame, false)
        pcall(cdTextFrame.SetDrawEdge, cdTextFrame, false)
        pcall(cdTextFrame.SetDrawBling, cdTextFrame, false)
        pcall(cdTextFrame.SetHideCountdownNumbers, cdTextFrame, not CONFIG.showCooldownDuration)
        pcall(cdTextFrame.SetCountdownAbbrevThreshold, cdTextFrame, 60)
        pcall(cdTextFrame.SetMinimumCountdownDuration, cdTextFrame, (CONFIG.cdTextMinDuration or 30) * 1000)
    end

    -- After barTextOverlay exists, which is what it anchors to with icons off.
    ApplyTextAnchors(row)

    -- Cooldown bar (top half for charge spells, full height otherwise).
    local nowPx = GetNowPixelOffset()
    local futureWidth = GetFutureWidth()
    local nowOffset = barOffset + nowPx
    
    row.cdBar = CreateStatusBar(row)
    row.cdBar:SetSize(futureWidth, CONFIG.height)
    row.cdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.cdBar:SetStatusBarColor(unpack(GetCooldownColor(row)))
    row.cdBar:SetFrameLevel(row:GetFrameLevel() + 1)
    
    row.cdBar:Hide()
    row.cdBar.fullHeight = CONFIG.height
    SetChargeLaneMetrics(row, CONFIG.height, 2)
    
    -- Past clip frames, one per lane, matching future counterpart frame levels.
    local baseLevel = row:GetFrameLevel()
    
    local function CreatePastClip(level)
        local clip = CreateFrame("Frame", nil, row)
        clip:SetClipsChildren(true)
        clip:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset, 0)
        clip:SetSize(nowPx, CONFIG.height)
        clip:SetFrameLevel(level)
        clip:Show()
        return clip
    end
    
    row.pastCdClip = CreatePastClip(baseLevel + 1)       -- matches cdBar initial level
    row.pastBuffClip = CreatePastClip(baseLevel + 3)      -- matches buffBar initial level
    row.pastOverlayClip = CreatePastClip(baseLevel + 4)   -- matches buffBarOverlay initial level
    row.pastThirdClip = CreatePastClip(baseLevel + 5)     -- matches buffBarThird initial level
    row.pastCastClip = CreatePastClip(baseLevel + 6)
    
    -- Sliding past markers
    row.pastSlides = {}

    row.hidden_cd = CreateHiddenCooldown(row, "cd")
    row.hidden_charge = CreateHiddenCooldown(row, "charge")
    row.hidden_buff = CreateHiddenCooldown(row, "buff")
    row.hidden_overlay = CreateHiddenCooldown(row, "overlay")
    row.hidden_third = CreateHiddenCooldown(row, "third")

    row.lastPtr_cd = nil
    row.lastPtr_charge = nil
    row.lastPtr_buff = nil
    row.lastPtr_overlay = nil
    row.lastPtr_third = nil

    -- Cast bar texture
    row.castFrame = CreateFrame("Frame", nil, row)
    row.castFrame:SetAllPoints(row)
    row.castFrame:SetFrameLevel(row:GetFrameLevel() + 6)
    
    row.castTex = row.castFrame:CreateTexture(nil, "ARTWORK")
    row.castTex:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    row.castTex:SetVertexColor(unpack(CONFIG.castColor))
    row.castTex:SetSnapToPixelGrid(false)
    row.castTex:SetTexelSnappingBias(0)
    row.castTex:Hide()
    

    
    -- Buff bar (primary)
    row.buffBar = CreateStatusBar(row)
    row.buffBar:SetSize(futureWidth, CONFIG.height)
    row.buffBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBar:SetStatusBarColor(unpack(CONFIG.buffColor))
    row.buffBar:SetFrameLevel(row:GetFrameLevel() + 3)
    row.buffBar:Hide()
    
    -- Pandemic pulse animation
    row.buffPandemicAnim = row.buffBar:CreateAnimationGroup()
    row.buffPandemicAnim:SetLooping("BOUNCE")
    
    local pandemicFade = row.buffPandemicAnim:CreateAnimation("Alpha")
    pandemicFade:SetFromAlpha(1.0)
    pandemicFade:SetToAlpha(0.5)
    pandemicFade:SetDuration(0.5)
    pandemicFade:SetSmoothing("IN_OUT")
    
    -- Buff overlay bar
    row.buffBarOverlay = CreateStatusBar(row)
    row.buffBarOverlay:SetSize(futureWidth, CONFIG.height)
    row.buffBarOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBarOverlay:SetStatusBarColor(unpack(CONFIG.buffColor))
    row.buffBarOverlay:SetFrameLevel(row:GetFrameLevel() + 4)
    row.buffBarOverlay:Hide()

    -- Buff third bar
    row.buffBarThird = CreateStatusBar(row)
    row.buffBarThird:SetSize(futureWidth, CONFIG.height)
    row.buffBarThird:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBarThird:SetStatusBarColor(unpack(CONFIG.buffColor))
    row.buffBarThird:SetFrameLevel(row:GetFrameLevel() + 5)
    row.buffBarThird:Hide()

    -- Cooldown swirl
    row.cooldownFrame = CreateFrame("Cooldown", nil, row.iconContainer)
    row.cooldownFrame:SetAllPoints(row.iconContainer)
    row.cooldownFrame:SetDrawEdge(false) 
    row.cooldownFrame:SetDrawSwipe(true)
    row.cooldownFrame:SetSwipeColor(0, 0, 0, 0.6) 
    row.cooldownFrame:SetReverse(false)
    row.cooldownFrame:SetHideCountdownNumbers(true)
    
    if row.cooldownFrame.SetUseCircularEdge then
        row.cooldownFrame:SetUseCircularEdge(true)
    end
    
    row.cooldownFrame:Hide()
    
    -- GCD overlay
    row.gcdBar = CreateStatusBar(row)
    row.gcdBar:SetSize(futureWidth, CONFIG.height)
    row.gcdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.gcdBar:SetStatusBarColor(unpack(CONFIG.gcdColor))
    row.gcdBar:SetFrameLevel(row:GetFrameLevel() + 7)
    row.gcdBar:Hide()

    -- GCD spark
    row.gcdSpark = row.gcdBar:CreateTexture(nil, "OVERLAY", nil, 5)
    row.gcdSpark:SetSnapToPixelGrid(false)
    row.gcdSpark:SetTexelSnappingBias(0)
    row.gcdSpark:SetSize(CONFIG.gcdSparkWidth or 2, CONFIG.height)
    row.gcdSpark:SetColorTexture(unpack(CONFIG.gcdSparkColor))
    row.gcdSpark:SetPoint("LEFT", row, "LEFT", nowOffset, 0)

    row.queueBar = row.gcdBar:CreateTexture(nil, "OVERLAY", nil, 4)
    row.queueBar:SetSnapToPixelGrid(false)
    row.queueBar:SetTexelSnappingBias(0)
    row.queueBar:SetSize(1, CONFIG.height)
    row.queueBar:SetColorTexture(unpack(CONFIG.queueBarColor or {1, 0.82, 0, 0.12}))
    row.queueBar:SetPoint("LEFT", row, "LEFT", nowOffset, 0)
    row.queueBar:Hide()

    row.queueSpark = row.gcdBar:CreateTexture(nil, "OVERLAY", nil, 6)
    row.queueSpark:SetSnapToPixelGrid(false)
    row.queueSpark:SetTexelSnappingBias(0)
    row.queueSpark:SetSize(CONFIG.queueSparkWidth or 2, CONFIG.height)
    row.queueSpark:SetColorTexture(unpack(CONFIG.queueSparkColor or {1, 0.82, 0, 0.8}))
    row.queueSpark:SetPoint("LEFT", row, "LEFT", nowOffset, 0)
    row.queueSpark:Hide()
    row.gcdSpark:Hide()

    -- Now line
    row.nowLineFrame = CreateFrame("Frame", nil, row)
    row.nowLineFrame:SetFrameLevel(row:GetFrameLevel() + 8)
    row.nowLineFrame:SetAllPoints(row)
    row.nowLine = row.nowLineFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    row.nowLine:SetSize(CONFIG.nowLineWidth, CONFIG.height)
    row.nowLine:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + nowPx - (CONFIG.nowLineWidth / 2), 0)
    row.nowLine:SetColorTexture(unpack(CONFIG.nowLineColor))
    row.nowLine:Show()
    
    row:Show()
    
    ApplyIconMode(row)
    ApplyBuffLayer(row)
    
    if not CONFIG.hideIcons then
        UpdateIconState(row)
    end
    
    return row
end

function EHF.ResizeContainer()
    local numBars = #cooldownBars
    if numBars == 0 then
        EH_Parent:SetHeight(CONFIG.paddingTop + CONFIG.paddingBottom)
        return
    end

    local useStatic = type(CONFIG.staticHeight) == "number" and numBars >= (CONFIG.staticFrames or 0)
    local barHeight

    if useStatic then
        EH_Parent:SetHeight(CONFIG.staticHeight)
        local availableHeight = CONFIG.staticHeight - CONFIG.paddingTop - CONFIG.paddingBottom
        barHeight = (availableHeight - (CONFIG.spacing * (numBars - 1))) / numBars
        barHeight = math.max(barHeight, 4)
    else
        barHeight = CONFIG.height
    end

    local yOff = 0
    for i, row in ipairs(cooldownBars) do
        local rowHeight = barHeight
        if not useStatic and row.isExtras and CONFIG.extrasHeight then
            rowHeight = CONFIG.extrasHeight
        end
        row:SetHeight(rowHeight)
        row.cdBar.fullHeight = rowHeight
        local maxC = row.maxCharges or 2
        SetChargeLaneMetrics(row, rowHeight, maxC)

        if row.isChargeSpell then
            local lH = row.cdBar.laneHeight
            local bottomY = ChargeBottomY(row, lH, maxC)
            row.cdBar:SetHeight(lH)
            if row.depletedWrapper then
                local futW = GetFutureWidth()
                local nowOff = EHF.GetBarOffset() + GetNowPixelOffset()

                -- Re-anchor, not just resize: these were positioned once at
                -- configure time and stayed put when the bar offset moved.
                row.depletedIndicator:ClearAllPoints()
                row.depletedIndicator:SetPoint("TOPLEFT", row, "TOPLEFT", nowOff, 0)
                row.depletedIndicator:SetSize(futW, rowHeight)

                row.depletedWrapper:ClearAllPoints()
                row.depletedWrapper:SetPoint("TOPLEFT", row, "TOPLEFT", nowOff, 0)
                row.depletedWrapper:SetPoint("BOTTOMRIGHT",
                    row.depletedIndicator:GetStatusBarTexture(), "TOPRIGHT")

                row.notDepletedWrapper:ClearAllPoints()
                row.notDepletedWrapper:SetPoint("TOPLEFT", row.depletedIndicator:GetStatusBarTexture(), "TOPLEFT")
                row.notDepletedWrapper:SetPoint("BOTTOMRIGHT", row, "TOPLEFT", nowOff + futW, -rowHeight)
                row.depletedCdBar:SetHeight(lH)
                row.depletedHelperBar:SetHeight(lH)
                row.depletedHelperBar:ClearAllPoints()
                row.depletedHelperBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", 0, bottomY)
                row.depletedChargeBar:SetHeight(lH)
                row.depletedChargeBar:ClearAllPoints()
                local slotPx = row._chargeSlotPx or 0
                row.depletedChargeBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", (maxC - 1) * slotPx, bottomY)
                row.normalChargeBar:SetHeight(lH)
                row.normalChargeBar:ClearAllPoints()
                if row.ndHelperSpacer then
                    row.ndHelperSpacer:SetSize(math.max(1, (maxC - 1) * slotPx), lH)
                    row.ndHelperSpacer:ClearAllPoints()
                    row.ndHelperSpacer:SetPoint("TOPLEFT", row.notDepletedWrapper, "TOPLEFT", 0, bottomY)
                    row.normalChargeBar:SetPoint("TOPLEFT", row.ndHelperSpacer:GetStatusBarTexture(), "TOPLEFT")
                else
                    row.normalChargeBar:SetPoint("TOPLEFT", row.notDepletedWrapper, "TOPLEFT", 0, bottomY)
                end
                if row.notDepletedHelperBar then
                    row.notDepletedHelperBar:ClearAllPoints()
                    row.notDepletedHelperBar:SetPoint("TOPLEFT", row.notDepletedWrapper, "TOPLEFT", 0, bottomY)
                    if row.ndHelperSpacer then
                        row.notDepletedHelperBar:SetPoint("BOTTOMRIGHT", row.ndHelperSpacer:GetStatusBarTexture(), "BOTTOMLEFT")
                    else
                        row.notDepletedHelperBar:SetHeight(lH)
                    end
                end
            end
            if row.middleLanes and row.maxCharges and row.maxCharges > 2 then
                if ns.ChargePast_Build then
                    ns.ChargePast_Build(row, row.maxCharges, lH)
                end
                local slotPx = row._chargeSlotPx or 0
                for j = 1, row.maxCharges - 2 do
                    if row.middleClipIndicators and row.middleClipIndicators[j] then
                        row.middleClipIndicators[j]:SetSize(GetFutureWidth(), rowHeight)
                    end
                    local ml = row.middleLanes[j]
                    if ml then
                        local laneY = -(j * ChargeLanePitch(row, lH))
                        ml.depletedHelperBar:SetSize(math.max(1, j * slotPx), lH)
                        ml.depletedHelperBar:ClearAllPoints()
                        ml.depletedHelperBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", 0, laneY)
                        if ml.helperSpacer then
                            ml.helperSpacer:SetSize(math.max(1, j * slotPx), lH)
                            ml.helperSpacer:ClearAllPoints()
                            ml.helperSpacer:SetPoint("TOPLEFT", row.middleClipWrappers[j], "TOPLEFT", 0, laneY)
                        end
                        ml.depletedChargeBar:SetHeight(lH)
                        ml.depletedChargeBar:ClearAllPoints()
                        if ml.helperSpacer then
                            ml.depletedChargeBar:SetPoint("TOPLEFT", ml.helperSpacer:GetStatusBarTexture(), "TOPLEFT")
                        else
                            ml.depletedChargeBar:SetPoint("TOPLEFT", row.middleClipWrappers and row.middleClipWrappers[j] or row.depletedWrapper, "TOPLEFT", j * slotPx, laneY)
                        end
                    end
                end
            end
        else
            row.cdBar:SetHeight(rowHeight)
        end
        row.castFrame:SetHeight(rowHeight)
        row.buffBar:SetHeight(rowHeight)
        row.buffBarOverlay:SetHeight(rowHeight)
        row.buffBarThird:SetHeight(rowHeight)
        row.gcdBar:SetHeight(rowHeight)
        row.gcdSpark:SetHeight(rowHeight)
        if row.queueSpark then row.queueSpark:SetHeight(rowHeight) end
        if row.queueBar then row.queueBar:SetHeight(rowHeight) end
        if row.nowLine then
            row.nowLine:SetHeight(rowHeight)
        end
        for _, clip in ipairs({row.pastCdClip, row.pastBuffClip, row.pastOverlayClip, row.pastThirdClip, row.pastCastClip}) do
            if clip then clip:SetHeight(rowHeight) end
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - yOff)
        yOff = yOff + rowHeight + CONFIG.spacing
    end

    if not useStatic then
        local contentHeight = yOff > 0 and (yOff - CONFIG.spacing) or 0
        local totalHeight = CONFIG.paddingTop + contentHeight + CONFIG.paddingBottom
        EH_Parent:SetHeight(totalHeight)
    end
end

local linesOverlay = CreateFrame("Frame", nil, EH_Parent)
linesOverlay:SetAllPoints(EH_Parent)
linesOverlay:SetFrameLevel(EH_Parent:GetFrameLevel() + 50) -- above everything
ns.linesOverlay = linesOverlay
local frameTimeLines = {}

function EHF.CreateTimeLines()
    local lineDef = CONFIG.lines
    if not lineDef then
        for i = 1, #frameTimeLines do
            if frameTimeLines[i] then frameTimeLines[i]:Hide() end
        end
        return
    end
    
    -- Normalize to table
    if type(lineDef) == "number" then lineDef = {lineDef} end
    if type(lineDef) ~= "table" then return end
    
    local colorDef = CONFIG.linesColor or {1, 1, 1, 0.3}
    local multiColor = type(colorDef[1]) == "table"
    local barOffset = EHF.GetBarOffset()
    local onePx = ns.OnePxForFrame(linesOverlay)

    local count = #lineDef
    for i = 1, count do
        local seconds = lineDef[i]
        local line = frameTimeLines[i]
        if not line then
            line = linesOverlay:CreateTexture(nil, "OVERLAY")
            -- The engine snaps a texture to its own grid AFTER layout, which moves
            -- a 1px rule off the position it was anchored to.
            line:SetSnapToPixelGrid(false)
            line:SetTexelSnappingBias(0)
            frameTimeLines[i] = line
        end
        if type(seconds) == "number" and seconds > 0 and seconds <= CONFIG.future then
            local color
            if multiColor then
                color = colorDef[i] or colorDef[#colorDef]
            else
                color = colorDef
            end
            line:SetColorTexture(unpack(color))

            -- Use timeline coordinate system: seconds is a future offset
            local xOffset = CONFIG.paddingLeft + barOffset + TimeToPixel(seconds)
            -- Snapped as an absolute screen edge, so every line is pixel crisp.
            local overlayLeft = linesOverlay:GetLeft()
            if overlayLeft then
                xOffset = math.floor((overlayLeft + xOffset) / onePx + 0.5) * onePx
                    - overlayLeft
            else
                xOffset = math.floor(xOffset / onePx + 0.5) * onePx
            end
            -- Opposite corners, so both horizontal edges are pinned.
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", linesOverlay, "TOPLEFT", xOffset, 0)
            line:SetPoint("BOTTOMRIGHT", linesOverlay, "BOTTOMLEFT", xOffset + onePx, 0)
            line:Show()
        else
            line:Hide()
        end
    end

    for i = count + 1, #frameTimeLines do
        if frameTimeLines[i] then frameTimeLines[i]:Hide() end
    end
end


local function SmartReorder()
    local newOrderCooldownIDs = {}
    
    -- Never the raw provider: its accessors build lazily and a build on our
    -- stack is created tainted. See ns.OrderedCooldownIDs in Core.lua.
    do
        local displayedCooldownIDs = ns.OrderedCooldownIDs and ns.OrderedCooldownIDs(0)
        do
            if displayedCooldownIDs then
                for _, cdID in ipairs(displayedCooldownIDs) do
                    local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    -- Item entries have no spellID. The count still disagrees when extras
                    -- or hidden rows exist, so a full reload is not fully avoided.
                    if infoOk and info and (info.spellID or info.spellCategoryID or info.equipSlot) then
                        table.insert(newOrderCooldownIDs, cdID)
                    end
                end
            end
        end
    end
    
    if #newOrderCooldownIDs == 0 then return end
    
    -- Hidden rows out, extras out. cooldownBars holds both, so a raw count never matches.
    local hidden = CONFIG.hiddenCooldownIDs
    local visibleOrder = {}
    for _, cdID in ipairs(newOrderCooldownIDs) do
        if not (hidden and hidden[cdID]) then
            visibleOrder[#visibleOrder + 1] = cdID
        end
    end

    local cdmBars = {}
    for _, bar in ipairs(cooldownBars) do
        if not bar.isExtras then cdmBars[#cdmBars + 1] = bar end
    end

    if #visibleOrder == #cdmBars then
        local same = true
        for i = 1, #visibleOrder do
            if cdmBars[i].cooldownID ~= visibleOrder[i] then
                same = false
                break
            end
        end
        -- Nothing moved, so nothing to reorder.
        if same then return end
    end

    -- Full reload only; there is no in place reorder path.
    EHF.LoadEssentialCooldowns()
end

local function ScanViewer(viewerName)
    local viewer = _G[viewerName]
    if not viewer then return nil end
    
    -- Prefer pool enumeration
    if viewer.itemFramePool then
        local ok, iter, pool, first = pcall(viewer.itemFramePool.EnumerateActive, viewer.itemFramePool)
        if ok and iter then
            return iter, pool, first
        end
    end
    
    -- Fallback to GetChildren()
    local success, children = pcall(function() return {viewer:GetChildren()} end)
    if success and children then
        local i = 0
        return function()
            i = i + 1
            return children[i]
        end
    end
    
    return nil
end

-- File-scope pcall extractors (no closure allocation per call)
local function extractCooldownID(frame)
    return frame:GetObjectType() and frame.cooldownID
end

local function extractAuraInstanceID(frame)
    return frame.auraInstanceID
end

local function extractIconTexture(frame)
    return frame.Icon and frame.Icon:GetTexture()
end

-- Cached tables reused by ScanViewerFrames to avoid per-call allocation
local cachedCooldownViewerFrames = {}
local cachedBuffViewerFrames = {}
local cooldownViewerNames = {"EssentialCooldownViewer", "UtilityCooldownViewer"}
local buffViewerNames = {"BuffIconCooldownViewer", "BuffBarCooldownViewer"}

-- Hook-maintained persistent maps: survive combat without frame pool iteration
local persistentCooldownMap = {}
local persistentBuffMap = {}

-- A cooldown-viewer frame can stand in for a buff frame but has no Bar.
-- Tracked so it can be upgraded on read.
local persistentBuffFallback = {}
local buffPromoteNext = {}

local function ResolveBuffFrame(cdID)
    if not cdID then return nil end
    local frame = persistentBuffMap[cdID]
    if frame and not persistentBuffFallback[cdID] then return frame end
    -- Stand-ins only; walking every id returns pool iteration to the combat path.
    if not persistentBuffFallback[cdID] then return frame end

    local now = GetTime()
    local nextTry = buffPromoteNext[cdID]
    if nextTry and now < nextTry then return frame end
    buffPromoteNext[cdID] = now + 1

    for _, viewerName in ipairs(buffViewerNames) do
        local iter, pool, first = ScanViewer(viewerName)
        if iter then
            for f in iter, pool, first do
                local ok, id = pcall(extractCooldownID, f)
                if ok and id == cdID then
                    persistentBuffMap[cdID] = f
                    persistentBuffFallback[cdID] = nil
                    buffPromoteNext[cdID] = nil
                    EHF.InstallBuffFrameHooks(f)
                    return f
                end
            end
        end
    end

    -- Stop retrying: re-walking both pools puts frame-pool iteration back on the
    -- combat path. The SetCooldownID and SetAuraInstanceInfo hooks catch late ones.
    persistentBuffFallback[cdID] = nil
    buffPromoteNext[cdID] = nil
    return frame
end

local function IsBuffViewerFrame(frame)
    local ok, viewer = pcall(function() return frame.viewerFrame end)
    if not ok or not viewer then return false end
    return viewer == _G["BuffIconCooldownViewer"] or viewer == _G["BuffBarCooldownViewer"]
end

-- Consumers only index this map, so a proxy upgrades stand-ins on read.
local buffMapProxy = setmetatable({}, {
    __index = function(_, cdID) return ResolveBuffFrame(cdID) end,
})

ns.GetPersistentBuffFrame = function(cdID) return ResolveBuffFrame(cdID) end

-- The engine writes auraInstanceID onto this frame for whichever aura it
-- associates with the entry, including a phase with no entry of its own.
ns.GetPersistentCooldownFrame = function(cdID)
    if not cdID then return nil end
    return persistentCooldownMap[cdID]
end
local viewerScanDirty = true
local cdmFrameToCdID = setmetatable({}, { __mode = "k" })
local hookedAuraFrames = setmetatable({}, { __mode = "k" })

-- Mirror push: forward the CDM's own bar write instead of reading it back a tick later.
--
-- VALUE ONLY. Our min max stays (0, CONFIG.future) because the lane width is the
-- future window in pixels; taking theirs turns every lane into a percentage.
local MIRROR_PUSH = true
-- Only has to outlast one client frame. Short on purpose: a redundant read is
-- harmless, holding a stale lane is not.
local MIRROR_FRESH = 0.2
local mirrorRowsByCdID = {}
local hookedMirrorBars = setmetatable({}, { __mode = "k" })
local mirrorInterp = nil
local mirrorPushCount, mirrorPollCount = 0, 0

local function MarkBuffDirtyForCdID(cdID)
    for _, row in ipairs(cooldownBars) do
        if row.cooldownID == cdID then
            row._buffDirty = true
        elseif row._buffCooldownIDs and row._buffCooldownIDs[cdID] then
            row._buffDirty = true
        end
    end
end

local function GetTotemSlotForRow(buffFrame)
    if buffFrame.totemData == nil then return nil end
    return buffFrame.preferredTotemUpdateSlot
end

function EHF.InstallBuffFrameHooks(frame)
    if hookedAuraFrames[frame] then return end
    hookedAuraFrames[frame] = true
    if frame.SetAuraInstanceInfo then
        hooksecurefunc(frame, "SetAuraInstanceInfo", function(self)
            AC.NoteAuraStart(self)
            -- Measured on application, not on the sweep: the sweep runs every two
            -- seconds and a short buff can start and end between two of them, so
            -- it never got measured at all. No-ops while auras are restricted.
            AC.Learn(self)
            local cdID = cdmFrameToCdID[self]
            if not cdID then cdID = self.cooldownID end
            if cdID then
                if IsBuffViewerFrame(self) then
                    persistentBuffMap[cdID] = self
                    persistentBuffFallback[cdID] = nil
                    buffPromoteNext[cdID] = nil
                elseif not persistentBuffMap[cdID] or persistentBuffFallback[cdID] then
                    persistentBuffMap[cdID] = self
                    persistentBuffFallback[cdID] = true
                end
                MarkBuffDirtyForCdID(cdID)
            end
        end)
    end
    if frame.ClearAuraInstanceInfo then
        hooksecurefunc(frame, "ClearAuraInstanceInfo", function(self)
            AC.ClearAuraStart(self)
            local cdID = cdmFrameToCdID[self]
            if not cdID then cdID = self.cooldownID end
            if cdID then MarkBuffDirtyForCdID(cdID) end
        end)
    end
    if EHF.InstallMirrorBarHook then EHF.InstallMirrorBarHook(frame) end
end

function EHF.ScanViewerFrames()
    -- In combat: return hook-maintained persistent maps (no frame pool iteration)
    if InCombatLockdown() then
        return persistentCooldownMap, persistentBuffMap
    end

    if not viewerScanDirty then
        return cachedCooldownViewerFrames, cachedBuffViewerFrames
    end
    viewerScanDirty = false

    wipe(cachedCooldownViewerFrames)
    wipe(cachedBuffViewerFrames)
    -- Cleared before the scan, not after: the loops below set the stand-in flags.
    wipe(persistentBuffFallback)
    wipe(buffPromoteNext)

    if C_CVar and not C_CVar.GetCVarBool("cooldownViewerEnabled") then
        return cachedCooldownViewerFrames, cachedBuffViewerFrames
    end

    for _, viewerName in ipairs(cooldownViewerNames) do
        local iter, pool, first = ScanViewer(viewerName)
        if iter then
            for frame in iter, pool, first do
                local ok, cdID = pcall(extractCooldownID, frame)
                if ok and cdID then
                    cachedCooldownViewerFrames[cdID] = frame
                    -- Category 0 hasAura: make active auras available for buff tracking
                    local aOk, aID = pcall(extractAuraInstanceID, frame)
                    if aOk and aID and not cachedBuffViewerFrames[cdID] then
                        cachedBuffViewerFrames[cdID] = frame
                        persistentBuffFallback[cdID] = true
                    end
                end
            end
        end
    end

    -- Buff viewers scanned second; overwrites Category 0 fallback entries above
    for _, viewerName in ipairs(buffViewerNames) do
        local iter, pool, first = ScanViewer(viewerName)
        if iter then
            for frame in iter, pool, first do
                local ok, cdID = pcall(extractCooldownID, frame)
                if ok and cdID then
                    cachedBuffViewerFrames[cdID] = frame
                    persistentBuffFallback[cdID] = nil
                    buffPromoteNext[cdID] = nil
                end
            end
        end
    end

    -- Sync persistent maps from OOC scan
    wipe(persistentCooldownMap)
    wipe(persistentBuffMap)
    for k, v in pairs(cachedCooldownViewerFrames) do
        persistentCooldownMap[k] = v
        EHF.InstallBuffFrameHooks(v)
    end
    for k, v in pairs(cachedBuffViewerFrames) do
        persistentBuffMap[k] = v
        EHF.InstallBuffFrameHooks(v)
    end

    return cachedCooldownViewerFrames, cachedBuffViewerFrames
end

local function MirrorECMState(row, cooldownViewerFrames)
    if not row.cooldownID then
        row.chargeText:Hide()
        return
    end
    
    local ecmFrame = cooldownViewerFrames[row.cooldownID]
    if not ecmFrame then
        row.chargeText:Hide()
        return
    end
    
    -- Resolve current spellID via GetOverrideSpell.
    if row.baseSpellID then
        local overrideOk, overrideID = pcall(C_Spell.GetOverrideSpell, row.baseSpellID)
        if overrideOk and overrideID and overrideID ~= row.spellID then
            row.spellID = overrideID
            -- SpellID changed; re-check glow for the new identity
            if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
                local gOk, isOverlayed = pcall(C_SpellActivationOverlay.IsSpellOverlayed, overrideID)
                if gOk then HandleProcGlow(row, isOverlayed) end
            end
        end
    end

    -- Mirror ECM icon texture (unless a custom icon override is set)
    if not CONFIG.hideIcons then
        local customID = CONFIG.customIcons and CONFIG.customIcons[row.cooldownID]
        if customID then
            local customTex = C_Spell.GetSpellTexture(customID)
            if customTex then
                row.icon:SetTexture(customTex)
            end
        else
            local texOk, tex = pcall(extractIconTexture, ecmFrame)
            if texOk and tex then
                row.icon:SetTexture(tex)
            end
        end
    end
    
    -- Charge text
    if row.hasCharges then
        local ok, chargeInfo = pcall(C_Spell.GetSpellCharges, row.spellID)
        if ok and chargeInfo then
            -- Never concatenate: currentCharges is secret and the pcall above
            -- covers only the API call.
            row.chargeText:SetText(chargeInfo.currentCharges)
            row.chargeText:Show()
        else
            row.chargeText:Hide()
        end
    else
        row.chargeText:Hide()
    end
end

-- Item entries have no spellID; the category reports whichever item most
-- recently started its cooldown.
local function ResolveCooldownSpellID(row)
    if row.spellID then return row.spellID end
    if row._spellCategoryID and C_Spell.GetLastCategoryCooldownSource then
        local ok, spellID = pcall(C_Spell.GetLastCategoryCooldownSource, row._spellCategoryID)
        if ok and spellID then return spellID end
    end
    return nil
end

-- The reported cooldown is the later of the spell's own and the rune wait,
-- with no API separating them. Rebuilt from a ClassConfig base plus cast time.
local runeCastAt = {}

-- Resolves through the base as well: row.spellID holds the override form, and
-- the table is keyed by base ids.
local function RuneBaseFor(row, spellID)
    local t = CONFIG.runeBaseCooldowns
    if not t then return nil end
    -- spellID is secret for item-category rows; a secret table key throws.
    if issecretvalue(spellID) then return nil end
    local base = t[spellID]
    if base ~= nil then return base, spellID end
    local b = row and row.baseSpellID
    if b and t[b] ~= nil then return t[b], b end
    return nil
end

local function RuneEstimateFor(row, spellID)
    if not CONFIG.estimateRuneCooldowns then return nil end
    local base, key = RuneBaseFor(row, spellID)
    if not base then return nil end
    if base <= 0 then return 0 end
    local castAt = runeCastAt[key]
    if not castAt then return nil end
    local remaining = (castAt + base) - GetTime()
    if remaining <= 0 then
        runeCastAt[key] = nil
        return 0
    end
    return remaining, base, castAt
end

ns.NoteRuneCast = function(spellID)
    local t = CONFIG.runeBaseCooldowns
    if not t or not spellID then return end
    if t[spellID] then runeCastAt[spellID] = GetTime() end
    local ok, baseID = pcall(C_Spell.GetBaseSpell, spellID)
    if ok and baseID and t[baseID] then runeCastAt[baseID] = GetTime() end
end

local function UpdateRowCooldown(row)
    if row.isChargeSpell then return end
    if row.extrasType == "custom" then return end

    -- An equipped item's cooldown is authoritative over its on-use spell's, which
    -- can be shorter and draws ready while the trinket is still down.
    if row._equipSlot then
        local itemDur, readable = ns.ItemCooldownDurObj(row._equipSlot)
        if not readable then return end
        FeedHiddenCooldown(row, "cd", itemDur)
        if itemDur and row.hidden_cd and row.hidden_cd:IsShown() then
            row.activeCooldown = itemDur
            if not row.cdBar:IsShown() then row.cdBar:Show() end
            if CONFIG.reactiveIcons and not CONFIG.hideIcons and row.cooldownFrame
                and itemDur ~= row.lastCdDurObj then
                pcall(row.cooldownFrame.SetCooldownFromDurationObject,
                    row.cooldownFrame, itemDur, false)
                row.cooldownFrame:Show()
                row.lastCdDurObj = itemDur
            end
        else
            row.activeCooldown = nil
            row.cdBar:Hide()
            row.lastCdDurObj = nil
            if row.cooldownFrame then row.cooldownFrame:Hide() end
        end
        return
    end

    local cdSpellID = ResolveCooldownSpellID(row)
    if not cdSpellID then
        -- Nothing has started a cooldown in this category yet.
        row.activeCooldown = nil
        row.cdBar:Hide()
        row.lastCdDurObj = nil
        if row.cooldownFrame then row.cooldownFrame:Hide() end
        FeedHiddenCooldown(row, "cd", nil)
        return
    end

    -- ignoreGCD=true returns the real cooldown, zero-span during a pure GCD.
    local successCD, cdDurObj = pcall(C_Spell.GetSpellCooldownDuration, cdSpellID, true)

    -- Declared base plus cast time, built from plain numbers, so no rune wait
    -- can leak in. Zero means the spell has no cooldown of its own.
    local estRemaining, estBase, estCastAt = RuneEstimateFor(row, cdSpellID)
    if estRemaining ~= nil then
        if estRemaining <= 0 or not C_DurationUtil then
            row.activeCooldown = nil
            row.cdBar:Hide()
            row.lastCdDurObj = nil
            if row.cooldownFrame then row.cooldownFrame:Hide() end
            FeedHiddenCooldown(row, "cd", nil)
            return
        end
        local built = C_DurationUtil.CreateDuration()
        built:SetTimeFromStart(estCastAt, estBase)
        cdDurObj, successCD = built, true
    end

    -- A failed read is UNKNOWN, not "no cooldown". Feeding nil would clear hidden_cd.
    if not successCD then return end

    -- Zero-span clears hidden_cd; IsShown() then gates the bar.
    FeedHiddenCooldown(row, "cd", cdDurObj)

    if successCD and cdDurObj and row.hidden_cd and row.hidden_cd:IsShown() then
        row.activeCooldown = cdDurObj
        if not row.cdBar:IsShown() then row.cdBar:Show() end

        if CONFIG.reactiveIcons and not CONFIG.hideIcons and row.cooldownFrame and cdDurObj ~= row.lastCdDurObj then
            pcall(row.cooldownFrame.SetCooldownFromDurationObject, row.cooldownFrame, cdDurObj, false)
            row.cooldownFrame:Show()
            row.lastCdDurObj = cdDurObj
        end
    else
        row.activeCooldown = nil
        row.cdBar:Hide()
        row.lastCdDurObj = nil
        if row.cooldownFrame then row.cooldownFrame:Hide() end
    end
end

-- Bar display is curve-driven in OnUpdate via wrapper frame alpha.
function EHF.UpdateChargeState(row)
    if not row.isChargeSpell then
        return
    end

    row.activeCooldown = nil

    EHF.FeedChargeBarTimers(row)

    -- Icon cooldown swirl from cached values
    local feedDurObj = row._cdDurObj or row._chargeDurObj
    if feedDurObj and CONFIG.reactiveIcons and not CONFIG.hideIcons and row.cooldownFrame then
        if feedDurObj ~= row.lastChargeDurObj then
            pcall(row.cooldownFrame.SetCooldownFromDurationObject, row.cooldownFrame, feedDurObj, false)
            row.cooldownFrame:Show()
            row.lastChargeDurObj = feedDurObj
        end
    elseif not feedDurObj and row.cooldownFrame then
        row.cooldownFrame:Hide()
        row.lastChargeDurObj = nil
    end
end

-- Pre-allocated buff entry tables (reused per UpdateBuffState call)
local _primaryBuffEntry = {}
local _overlayBuffEntry = {}
local _thirdBuffEntry = {}

-- One row per buff lane. Values are literal field names; never a secret key.
local BUFF_LANES = {
    { entry = _primaryBuffEntry, bar = "buffBar",        timer = "buff",
      dur = "activeBuffDuration",        mirror = "_auraMirrorCdID",
      color = "resolvedBuffColor",       tracked = "trackedBuffAuraInstanceID",
      totemSlot = "_totemSlot",          totemFed = "_totemCooldownFed",
      push = "_mirrorPushAt" },
    { entry = _overlayBuffEntry, bar = "buffBarOverlay", timer = "overlay",
      dur = "activeBuffOverlayDuration", mirror = "_auraMirrorCdIDOverlay",
      color = "resolvedOverlayColor",    tracked = "trackedOverlayAuraInstanceID",
      totemSlot = "_overlayTotemSlot",   totemFed = "_overlayTotemFed",
      push = "_mirrorPushAtOverlay" },
    { entry = _thirdBuffEntry,   bar = "buffBarThird",   timer = "third",
      dur = "activeBuffThirdDuration",   mirror = "_auraMirrorCdIDThird",
      color = "resolvedThirdColor",      tracked = "trackedThirdAuraInstanceID",
      totemSlot = "_thirdTotemSlot",     totemFed = "_thirdTotemFed",
      push = "_mirrorPushAtThird" },
}

local function ResolveBuffColor(buffEntry)
    if buffEntry.hasCustomColor then
        return buffEntry.color
    elseif buffEntry.unit == "target" then
        return CONFIG.debuffColor
    else
        return buffEntry.color or CONFIG.buffColor
    end
end


-- Pre-allocated buff entry tables (reused per UpdateBuffState call)

-- One row per buff lane. Values are literal field names; never a secret key.

local _buffLanes = {}

-- A row registers itself against the buff cooldownID it mirrors. The list is
-- append only; the lane test below is what keeps a stale entry harmless, so
-- there is no bookkeeping at the twelve sites that clear a mirror id.
function EHF.RegisterMirrorRow(cdID, row)
    if not MIRROR_PUSH or not cdID or not row then return end
    local list = mirrorRowsByCdID[cdID]
    if not list then
        list = {}
        mirrorRowsByCdID[cdID] = list
    end
    for i = 1, #list do
        if list[i] == row then return end
    end
    list[#list + 1] = row
end

-- Runs inside Blizzard's own call stack, so it must be incapable of erroring:
-- table lookups, a secret accepting SetValue, and one comparison against a
-- literal zero that Blizzard pushes as a plain number. No arithmetic on v, ever.
function EHF.InstallMirrorBarHook(frame)
    if not MIRROR_PUSH then return end
    -- Bare read, matching FillBuffLaneBar: callers only ever pass a live pooled
    -- frame, either from an out of combat walk or from the SetCooldownID hook.
    local bar = frame.Bar
    if not bar or not bar.SetValue or hookedMirrorBars[bar] then return end
    hookedMirrorBars[bar] = true

    hooksecurefunc(bar, "SetValue", function(_, v)
        local cdID = cdmFrameToCdID[frame]
        if not cdID then return end
        local list = mirrorRowsByCdID[cdID]
        if not list then return end
        local now = GetTime()
        for i = 1, #list do
            local row = list[i]
            for l = 1, 3 do
                local lane = BUFF_LANES[l]
                -- The identity re-check: a pooled frame can be reassigned, and
                -- only the row that currently mirrors THIS id may be written.
                if row[lane.mirror] == cdID and row[lane.tracked] then
                    local b = row[lane.bar]
                    if b then
                        b:SetValue(v, mirrorInterp)
                        row[lane.push] = now
                        mirrorPushCount = mirrorPushCount + 1
                    end
                end
            end
        end
    end)

    if bar.SetMinMaxValues then
        hooksecurefunc(bar, "SetMinMaxValues", function(_, _, mx)
            -- Their inactive push is a literal SetMinMaxValues(0, 0), so this
            -- is a non-secret comparison and the only clean "row went dead"
            -- edge available. Never mirror their scale onto our lane.
            if issecretvalue and issecretvalue(mx) then return end
            if mx ~= 0 then return end
            local cdID = cdmFrameToCdID[frame]
            if not cdID then return end
            local list = mirrorRowsByCdID[cdID]
            if not list then return end
            for i = 1, #list do
                local row = list[i]
                for l = 1, 3 do
                    if row[BUFF_LANES[l].mirror] == cdID then
                        row[BUFF_LANES[l].push] = nil
                        row._buffDirty = true
                    end
                end
            end
        end)
    end
end

ns.MirrorStats = function()
    return mirrorPushCount, mirrorPollCount, MIRROR_PUSH
end

-- Callers must test the lane is unclaimed first; these wipe the shared entry table.
local function FillAuraLane(laneIdx, frame, mapData, unitHint, secretAuraSpellId)
    local e = BUFF_LANES[laneIdx].entry
    wipe(e)
    e.frame = frame
    e.color = mapData.color or CONFIG.buffColor
    e.hasCustomColor = mapData.color ~= nil
    e.unit = unitHint
    e.secretAuraSpellId = secretAuraSpellId
    e.requireGlow = mapData.requireGlow
    return e
end

local function FillTotemLane(laneIdx, frame, mapData, totemSlot)
    local e = BUFF_LANES[laneIdx].entry
    wipe(e)
    e.frame = frame
    e.color = (mapData and mapData.color) or CONFIG.buffColor
    e.hasCustomColor = (mapData and mapData.color) ~= nil
    e.unit = "player"
    e.totemSlot = totemSlot
    return e
end

-- Shared by lanes 2 and 3. Lane 1 is separate: pandemic pulse, variant name, potion window.
local function UpdateSecondaryLane(row, buffEntry, lane)
    local bar = row[lane.bar]
    if not bar then return end

    if not buffEntry then
        bar:Hide()
        row[lane.dur] = nil
        row[lane.color] = nil
        row[lane.tracked] = nil
        row[lane.mirror] = nil
        row[lane.totemSlot] = nil
        row[lane.totemFed] = false
        FeedHiddenCooldown(row, lane.timer, nil)
        return
    end

    local resolvedColor = ResolveBuffColor(buffEntry)
    row[lane.color] = resolvedColor
    bar:SetStatusBarColor(unpack(resolvedColor))

    local hidden = row["hidden_" .. lane.timer]
    local lastPtr = "lastPtr_" .. lane.timer

    if buffEntry.totemSlot then
        if not row[lane.totemFed] then
            -- Bound first: passing the call through directly would forward any
            -- extra return values as further arguments.
            local totemDurObj = GetTotemDuration(buffEntry.totemSlot)
            FeedHiddenCooldownRaw(row, lane.timer, totemDurObj)
            row[lane.totemFed] = true
        end
        row[lane.dur] = nil
        row[lane.totemSlot] = buffEntry.totemSlot
        if hidden:IsShown() then bar:Show() else bar:Hide() end
        row[lane.tracked] = nil
        return
    end

    row[lane.totemSlot] = nil
    -- A custom lane carries its own ids and length, so there is nothing for the
    -- resolver to read off a frame it does not have.
    local kind, payload
    if buffEntry.timerDurObj then
        kind, payload = "durobj", buffEntry.timerDurObj
    else
        kind, payload = AC.ResolveFill(buffEntry.frame, buffEntry.unit)
    end
    if kind == "permanent" then
        row[lane.dur] = nil
        row[lane.mirror] = nil
        bar:SetValue(CONFIG.future)
        bar:Show()
        row[lane.tracked] = buffEntry.frame and buffEntry.frame.auraInstanceID or nil
        if hidden and row[lastPtr] ~= true then
            hidden:SetCooldown(GetTime(), 86400)
            row[lastPtr] = true
        end
    elseif kind then
        row[lane.dur] = (kind == "durobj") and payload or nil
        local newMirror = (kind == "mirror") and buffEntry.frame.cooldownID or nil
        if row[lane.mirror] ~= newMirror then row[lane.push] = nil end
        row[lane.mirror] = newMirror
        if newMirror then EHF.RegisterMirrorRow(newMirror, row) end
        FeedHiddenCooldown(row, lane.timer, row[lane.dur])
        row[lane.tracked] = buffEntry.frame and buffEntry.frame.auraInstanceID or nil
        if not bar:IsShown() then bar:SetValue(0) end
        bar:Show()
    else
        bar:Hide()
        row[lane.dur] = nil
        row[lane.color] = nil
        row[lane.tracked] = nil
        row[lane.mirror] = nil
        FeedHiddenCooldown(row, lane.timer, nil)
    end
end


-- Two CDM entries can present the same aura only if they name a common spell.
-- Unknown identity on either side answers true: an item entry has no spell id.
function EHF.IdentityShared(mapCdID, rowCdID)
    if not mapCdID or not rowCdID or mapCdID == rowCdID then return true end
    local a = AC.IdentityIDsForCooldown(mapCdID)
    local b = AC.IdentityIDsForCooldown(rowCdID)
    if not a or not b then return true end
    for i = 1, #a do
        for j = 1, #b do
            if a[i] == b[j] then return true end
        end
    end
    return false
end

function EHF.UpdateBuffState(row, buffViewerFrames)
    if row.isExtras and row.extrasType ~= "custom" then return end
    -- Each mapping entry owns a fixed lane: [1] = primary, [2] = overlay, [3] = third.
    wipe(_buffLanes)
    local mappings = row.cooldownID and CONFIG.buffMappings and (CONFIG.buffMappings[row.cooldownID] or CONFIG.buffMappings[row.baseSpellID] or CONFIG.buffMappings[row.spellID])

    if row.cooldownID then
        -- Mapping matches: direct lookup by each buffCooldownID
        if mappings then
            for mapIdx, mapData in ipairs(mappings) do
                if mapData.buffCooldownIDs then
                    for _, mappedID in ipairs(mapData.buffCooldownIDs) do
                        local buffFrame = buffViewerFrames[mappedID]
                        if buffFrame and buffFrame.auraInstanceID then
                            local unitHint = mapData.unit or buffFrame.auraDataUnit or "player"
                            local secretAuraSpellId
                            if CONFIG.showVariantNames and buffFrame.auraInstanceID then
                                secretAuraSpellId = AC.ReadAuraSpellID(buffFrame)
                            end
                            if mapIdx <= 3 and not _buffLanes[mapIdx] then
                                _buffLanes[mapIdx] = FillAuraLane(mapIdx, buffFrame, mapData, unitHint, secretAuraSpellId)
                            end
                            break
                        end
                    end
                end
            end
        end

        -- Self-match fallback: CDM may track the aura on the ability's own frame
        -- (same cooldownID in buff viewer) rather than a separate buffCooldownID.
        if mappings then
            for mapIdx, mapData in ipairs(mappings) do
                local alreadyMatched = _buffLanes[mapIdx]
                if not alreadyMatched and mapData.buffCooldownIDs then
                    local selfFrame = buffViewerFrames[row.cooldownID]
                    -- The row's own frame is a fallback for the mapped aura, not a
                    -- substitute for it. Inlined: Bars.lua is at Lua's 200 local ceiling.
                    local selfUnit = selfFrame and selfFrame.auraDataUnit
                    local wrongUnit = mapData.unit and selfUnit and mapData.unit ~= selfUnit
                    local claimed = false
                    for l = 1, 3 do
                        if _buffLanes[l] and _buffLanes[l].frame == selfFrame then
                            claimed = true
                            break
                        end
                    end
                    -- The row's frame stands in for the mapped aura, never substitutes
                    -- a different one. Identity, not frame pointers: one aura, two frames.
                    local shares = false
                    for _, mappedID in ipairs(mapData.buffCooldownIDs) do
                        if EHF.IdentityShared(mappedID, row.cooldownID) then
                            shares = true
                            break
                        end
                    end
                    if selfFrame and selfFrame.auraInstanceID
                        and shares and not claimed and not wrongUnit then
                        local unitHint = mapData.unit or selfFrame.auraDataUnit or "player"
                        local secretAuraSpellId
                        if CONFIG.showVariantNames and selfFrame.auraInstanceID then
                            secretAuraSpellId = AC.ReadAuraSpellID(selfFrame)
                        end
                        if mapIdx <= 3 and not _buffLanes[mapIdx] then
                            _buffLanes[mapIdx] = FillAuraLane(mapIdx, selfFrame, mapData, unitHint, secretAuraSpellId)
                        end
                    end
                end
            end
        end
    end

    -- Totem pass (CDM tracks summon abilities via preferredTotemUpdateSlot)
    if not _buffLanes[1] and row.cooldownID then
        local selfFrame = buffViewerFrames[row.cooldownID]
        if selfFrame and not selfFrame.auraInstanceID then
            local totemSlot = GetTotemSlotForRow(selfFrame)
            if totemSlot then
                _buffLanes[1] = FillTotemLane(1, selfFrame, nil, totemSlot)
            end
        end
        if not _buffLanes[1] and mappings then
            for mapIdx, mapData in ipairs(mappings) do
                if _buffLanes[1] then break end
                if mapData.buffCooldownIDs then
                    for _, mappedID in ipairs(mapData.buffCooldownIDs) do
                        local buffFrame = buffViewerFrames[mappedID]
                        if buffFrame and not buffFrame.auraInstanceID then
                            local totemSlot = GetTotemSlotForRow(buffFrame)
                            if totemSlot then
                                if mapIdx <= 3 and not _buffLanes[mapIdx] then
                                    _buffLanes[mapIdx] = FillTotemLane(mapIdx, buffFrame, mapData, totemSlot)
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Unfed frame pass, for frames the game leaves without an auraInstanceID
    -- while the buff is up. The read decides presence, so a down aura resolves
    -- to nothing. Needs a frame to exist: an unlearned entry has none.
    if row.cooldownID and mappings and AC.AuraFill then
        for mapIdx, mapData in ipairs(mappings) do
            if mapIdx <= 3 and not _buffLanes[mapIdx] and mapData.buffCooldownIDs then
                for _, mappedID in ipairs(mapData.buffCooldownIDs) do
                    local buffFrame = buffViewerFrames[mappedID]
                    if buffFrame and not buffFrame.auraInstanceID
                        and AC.AuraFill(buffFrame, mapData.unit) then
                        _buffLanes[mapIdx] = FillAuraLane(mapIdx, buffFrame, mapData,
                            mapData.unit or "player", nil)
                        break
                    end
                end
            end
        end
    end

    if mappings and ns.TierSpellIDForCooldown and AC.AuraFillBySpellID then
        for mapIdx, mapData in ipairs(mappings) do
            if mapIdx <= 3 and not _buffLanes[mapIdx] and mapData.buffCooldownIDs then
                for _, mappedID in ipairs(mapData.buffCooldownIDs) do
                    local tierSpell = ns.TierSpellIDForCooldown(mappedID)
                    if tierSpell then
                        local kind, durObj = AC.AuraFillBySpellID(tierSpell, mapData.unit)
                        if kind == "durobj" and durObj then
                            local e = BUFF_LANES[mapIdx].entry
                            wipe(e)
                            e.timerDurObj = durObj
                            e.color = mapData.color or CONFIG.buffColor
                            e.hasCustomColor = mapData.color ~= nil
                            e.unit = mapData.unit
                            _buffLanes[mapIdx] = e
                            break
                        end
                    end
                end
            end
        end
    end

    -- Custom timer pass. Produced as a plain DurationObject so it travels the
    -- same path every other lane uses, which is what lets it work in all three.
    local customStarts = row._customTimerStart
    if mappings and customStarts then
        local now = GetTime()
        for mapIdx, mapData in ipairs(mappings) do
            if mapIdx <= 3 and not _buffLanes[mapIdx] and mapData.customDuration then
                local startedAt = customStarts[mapIdx]
                if startedAt and (now - startedAt) < mapData.customDuration then
                    -- Cached on the start stamp. FeedHiddenCooldown skips a
                    -- re-feed by pointer identity, so a new object each pass
                    -- re-feeds forever and OnCooldownDone never fires.
                    row._customTimerObj = row._customTimerObj or {}
                    local cached = row._customTimerObj[mapIdx]
                    local durObj
                    if cached and cached.at == startedAt
                        and cached.dur == mapData.customDuration then
                        durObj = cached.obj
                    else
                        durObj = C_DurationUtil.CreateDuration()
                        durObj:SetTimeFromStart(startedAt, mapData.customDuration)
                        row._customTimerObj[mapIdx] =
                            { at = startedAt, dur = mapData.customDuration, obj = durObj }
                    end
                    local e = BUFF_LANES[mapIdx].entry
                    wipe(e)
                    e.timerDurObj = durObj
                    e.color = mapData.color or CONFIG.buffColor
                    e.hasCustomColor = mapData.color ~= nil
                    e.unit = mapData.unit
                    _buffLanes[mapIdx] = e
                end
            end
        end
    end

    -- Glow-gated: suppress buff bar but preserve secretAuraSpellId for variant text.
    local primaryBuff, overlayBuff, thirdBuff = _buffLanes[1], _buffLanes[2], _buffLanes[3]

    row._glowGatedVariant = false
    if primaryBuff and primaryBuff.requireGlow and not row.isGlowing then
        row.secretAuraSpellId = primaryBuff.secretAuraSpellId
        row._glowGatedVariant = true
        primaryBuff = nil
    end
    if overlayBuff and overlayBuff.requireGlow and not row.isGlowing then
        overlayBuff = nil
    end
    if thirdBuff and thirdBuff.requireGlow and not row.isGlowing then
        thirdBuff = nil
    end

    -- A live potion window is checked first: a resolved lane on a potion row
    -- gives an empty mirror, which would hide the window's bar.
    local potionWindowLive = row._potionWindowExpiry and GetTime() < row._potionWindowExpiry
        and not (primaryBuff and primaryBuff.timerDurObj)
    if potionWindowLive then
        -- Owned by the window. Reapplying it each tick makes the bar strobe.
    elseif primaryBuff then
        local resolvedColor = ResolveBuffColor(primaryBuff)
        row.resolvedBuffColor = resolvedColor
        row.buffBar:SetStatusBarColor(unpack(resolvedColor))

        if primaryBuff.totemSlot then
            if not row._totemCooldownFed then
                local totemDurObj = GetTotemDuration(primaryBuff.totemSlot)
                if totemDurObj then
                    FeedHiddenCooldownRaw(row, "buff", totemDurObj)
                else
                    FeedHiddenCooldownRaw(row, "buff", nil)
                end
                row._totemCooldownFed = true
            end
            row.activeBuffDuration = nil
            row._totemSlot = primaryBuff.totemSlot
            row.cachedPandemicIcon = nil
            if row.buffPandemicAnim and row.buffPandemicAnim:IsPlaying() then
                row.buffPandemicAnim:Stop()
                row.buffBar:SetAlpha(1.0)
            end
            if row.hidden_buff:IsShown() then
                row.buffBar:Show()
            else
                row.buffBar:Hide()
            end
            row.trackedBuffAuraInstanceID = nil
            row.secretAuraSpellId = nil
        else
            row._totemSlot = nil
            -- A frameless or user declared lane carries its own ids and length, so
            -- there is nothing for the resolver to read off a frame it does not have.
            local fillKind, fillPayload, resolvedUnit
            if primaryBuff.timerDurObj then
                fillKind, fillPayload = "durobj", primaryBuff.timerDurObj
            else
                fillKind, fillPayload, resolvedUnit =
                    AC.ResolveFill(primaryBuff.frame, primaryBuff.unit)
            end
            if resolvedUnit and resolvedUnit ~= primaryBuff.unit then
                primaryBuff.unit = resolvedUnit
            end
            if fillKind == "permanent" then
                -- Full bar, no animation
                row.activeBuffDuration = nil
                row._auraMirrorCdID = nil
                row.cachedPandemicIcon = nil
                if row.buffPandemicAnim and row.buffPandemicAnim:IsPlaying() then
                    row.buffPandemicAnim:Stop()
                    row.buffBar:SetAlpha(1.0)
                end
                row.buffBar:SetValue(CONFIG.future)
                row.buffBar:Show()
                row.trackedBuffAuraInstanceID = primaryBuff.frame
                    and primaryBuff.frame.auraInstanceID or nil
                row.secretAuraSpellId = primaryBuff.secretAuraSpellId
                if row.hidden_buff and row.lastPtr_buff ~= true then
                    row.hidden_buff:SetCooldown(GetTime(), 86400)
                    row.lastPtr_buff = true
                end
            elseif fillKind then
                row.activeBuffDuration = (fillKind == "durobj") and fillPayload or nil
                local newMirror = (fillKind == "mirror") and primaryBuff.frame.cooldownID or nil
                -- Freshness belongs to the source. Keeping it across a source
                -- change lets the lane hold the previous aura's value.
                if row._auraMirrorCdID ~= newMirror then row._mirrorPushAt = nil end
                row._auraMirrorCdID = newMirror
                if newMirror then EHF.RegisterMirrorRow(newMirror, row) end

                if primaryBuff.unit == "target" and CONFIG.pandemicPulse then
                    row.cachedPandemicIcon = primaryBuff.frame
                        and primaryBuff.frame.PandemicIcon or nil
                else
                    row.cachedPandemicIcon = nil
                end
                if not row.cachedPandemicIcon and row.buffPandemicAnim:IsPlaying() then
                    row.buffPandemicAnim:Stop()
                    row.buffBar:SetAlpha(1.0)
                end

                if not row.buffBar:IsShown() then
                    row.buffBar:SetValue(0)
                end
                row.buffBar:Show()
                FeedHiddenCooldown(row, "buff", row.activeBuffDuration)
                row.trackedBuffAuraInstanceID = primaryBuff.frame
                    and primaryBuff.frame.auraInstanceID or nil
                row.secretAuraSpellId = primaryBuff.secretAuraSpellId
            else
                row.buffBar:Hide()
                if row.buffPandemicAnim and row.buffPandemicAnim:IsPlaying() then
                    row.buffPandemicAnim:Stop()
                end
                row.activeBuffDuration = nil
                row._auraMirrorCdID = nil
                row.resolvedBuffColor = nil
                row.cachedPandemicIcon = nil
                row.trackedBuffAuraInstanceID = nil
                row.secretAuraSpellId = nil
                FeedHiddenCooldown(row, "buff", nil)
            end
        end
    else
        if row._potionWindowExpiry then
            row._potionWindowExpiry = nil
        end
        row.buffBar:Hide()
        if row.buffPandemicAnim:IsPlaying() then
            row.buffPandemicAnim:Stop()
        end
        row.activeBuffDuration = nil
        row._auraMirrorCdID = nil
        row.resolvedBuffColor = nil
        row.cachedPandemicIcon = nil
        row.trackedBuffAuraInstanceID = nil
        row._totemSlot = nil
        row._totemCooldownFed = false
        if not row._glowGatedVariant then
            row.secretAuraSpellId = nil
        end
        FeedHiddenCooldown(row, "buff", nil)
    end

    UpdateSecondaryLane(row, overlayBuff, BUFF_LANES[2])
    UpdateSecondaryLane(row, thirdBuff, BUFF_LANES[3])


end

function EHF.UpdateStackText(row, buffViewerFrames)
    if not row.stackText then return end

    -- Variant name text (IE Roll the Bones outcome) on the bar area
    local variantShown = false
    if row.variantNameText and CONFIG.showVariantNames then
        local hasVariants = row._isMultiVariant
        if hasVariants and row.secretAuraSpellId then
            local name = C_Spell.GetSpellName(row.secretAuraSpellId)
            if name then
                row.variantNameText:SetText(name)
                row.variantNameText:SetTextColor(unpack(CONFIG.variantTextColor))
                row.variantNameText:Show()
                variantShown = true
            end
        end
    end
    if row.variantNameText and not variantShown then
        row.variantNameText:Hide()
    end

    local stackMapping = CONFIG.stackMappings and (CONFIG.stackMappings[row.cooldownID] or CONFIG.stackMappings[row.baseSpellID] or CONFIG.stackMappings[row.spellID])
    if not stackMapping then
        row.stackText:Hide()
        return
    end
    
    local tierStackSpell = ns.TierSpellIDForCooldown
        and ns.TierSpellIDForCooldown(stackMapping.buffCooldownID)
    if tierStackSpell then
        local apps = AC.ApplicationsBySpellID and AC.ApplicationsBySpellID(tierStackSpell)
        if apps and apps > 0 then
            row.stackText:SetText(apps)
            row.stackText:SetTextColor(unpack(stackMapping.color or CONFIG.stackTextColor))
            row.stackText:Show()
        else
            row.stackText:Hide()
        end
        return
    end

    local buffFrame = buffViewerFrames[stackMapping.buffCooldownID]
    if buffFrame and buffFrame.auraInstanceID ~= nil then
        local unit = buffFrame.auraDataUnit or stackMapping.unit or "player"

        do
            local appVal = AC.ReadApplications(buffFrame)
            if appVal ~= nil then
                row.stackText:SetText(appVal)
                if stackMapping.color then
                    row.stackText:SetTextColor(unpack(stackMapping.color))
                else
                    row.stackText:SetTextColor(unpack(CONFIG.stackTextColor))
                end
                row.stackText:Show()
            else
                row.stackText:Hide()
            end
        end
        return
    end

    row.stackText:Hide()
end

-- Desaturation update via curve evaluation.
function EHF.UpdateDesaturation(row)
    if not CONFIG.desaturateOnCooldown then return end
    if CONFIG.hideIcons then return end

    if row.isChargeSpell then
        -- Use event-cached _cdDurObj (already nil when GCD-only)
        local cdDurObj = row._cdDurObj
        if cdDurObj and BinaryCurve then
            local curveOk, result = pcall(cdDurObj.EvaluateRemainingPercent, cdDurObj, BinaryCurve)
            if curveOk and result then
                row.icon:SetDesaturation(result)
            else
                row.icon:SetDesaturation(0)
            end
        else
            row.icon:SetDesaturation(0)
        end
        return
    end

    -- Non-charge spells
    if row.activeCooldown and BinaryCurve then
        local ok, result = pcall(row.activeCooldown.EvaluateRemainingPercent, row.activeCooldown, BinaryCurve)
        if ok and result then
            row.icon:SetDesaturation(result)
        else
            row.icon:SetDesaturation(0)
        end
    else
        row.icon:SetDesaturation(0)
    end
end

local lastUpdateBarsTime = 0
local buffViewerWarningShown = false

local function UpdateBars()
    local now = GetTime()
    if now - lastUpdateBarsTime < 0.016 then return end
    lastUpdateBarsTime = now

    local cooldownViewerFrames = EHF.ScanViewerFrames()
    local buffViewerFrames = buffMapProxy

    -- One-time warning if buff viewers have no frames but mappings exist
    if not buffViewerWarningShown and CONFIG.buffMappings and next(CONFIG.buffMappings) then
        -- next() ignores metamethods, so this must test the backing map.
        local hasBuff = next(persistentBuffMap) ~= nil
        if not hasBuff and _G["BuffIconCooldownViewer"] then
            buffViewerWarningShown = true
            print("|cff00ff00[Infall]|r Buff tracking requires the Cooldown Manager buff viewer to be visible. Set it to Always in CDM settings, then use /infall ecm to hide it.")
        elseif hasBuff then
            buffViewerWarningShown = true
        end
    end

    local P = ns.Perf
    -- Hoisted to upvalues: these run per row per frame, and a function local costs
    -- nothing against the main chunk's 200 the way a file scope one does.
    local UpdateChargeState, UpdateBuffState = EHF.UpdateChargeState, EHF.UpdateBuffState
    local UpdateStackText, UpdateDesaturation = EHF.UpdateStackText, EHF.UpdateDesaturation

    for _, row in ipairs(cooldownBars) do
        -- Dormancy: a hidden row does no per-row work. The show edge marks it
        -- dirty so it reconciles rather than displaying stale state.
        local visible = row:IsShown()
        if visible and not row._wasVisible then
            row._buffDirty = true
        end
        row._wasVisible = visible

        if visible then
            if P and P.enabled then
                P.Time("MirrorECMState", MirrorECMState, row, cooldownViewerFrames)
                P.Time("UpdateRowCooldown", UpdateRowCooldown, row)
                P.Time("UpdateChargeState", UpdateChargeState, row)
                P.Time("UpdateBuffState", UpdateBuffState, row, buffViewerFrames)
                P.Time("UpdateStackText", UpdateStackText, row, buffViewerFrames)
                P.Time("UpdateDesaturation", UpdateDesaturation, row)
            else
                MirrorECMState(row, cooldownViewerFrames)
                UpdateRowCooldown(row)
                UpdateChargeState(row)
                UpdateBuffState(row, buffViewerFrames)
                UpdateStackText(row, buffViewerFrames)
                UpdateDesaturation(row)
            end
        end
    end
end

local function ScheduleDeferredUpdate(delay)
    deferredGen[delay] = (deferredGen[delay] or 0) + 1
    local myGen = deferredGen[delay]
    C_Timer.After(delay, function()
        if deferredGen[delay] == myGen then
            UpdateBars()
        end
    end)
end

local function UpdateBuffPastSlide(row, isActive, slideKey, clipKey, colorKey)
    local slide = row[slideKey]
    -- Waits for a colour. The repaint below only runs while one exists, so a
    -- slide spawned on a nil-colour tick keeps the default for its whole life.
    if isActive and not slide and row[colorKey] then
        row[slideKey] = EHF.SpawnPastSlide(row, row[clipKey], row[colorKey], row.cdBar.fullHeight or CONFIG.height, 0)
    elseif not isActive and slide then
        EHF.DetachPastSlide(slide)
        row[slideKey] = nil
    end
    slide = row[slideKey]
    if slide and not slide.detachTime and row[colorKey] then
        local c = row[colorKey]
        slide.color = c
        slide.tex:SetVertexColor(c[1], c[2], c[3], c[4] or 0.7)
    end
end

-- OnUpdate helpers (defined once to avoid per-frame closure allocation)

-- Spell queue window in seconds, cached; the CVar is the only thing that moves it.
local function ReadQueueWindow()
    queueWindowSeconds = 0
    if not C_Spell or not C_Spell.GetSpellQueueWindow then return end
    local ok, ms = pcall(C_Spell.GetSpellQueueWindow)
    if issecretvalue and issecretvalue(ms) then return end
    if ok and type(ms) == "number" and ms > 0 then
        queueWindowSeconds = ms / 1000
    end
end

local queueWindowWatcher = CreateFrame("Frame")
queueWindowWatcher:RegisterEvent("PLAYER_LOGIN")
queueWindowWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
queueWindowWatcher:RegisterEvent("CVAR_UPDATE")
queueWindowWatcher:SetScript("OnEvent", function(_, event, name)
    if event ~= "CVAR_UPDATE" or name == "SpellQueueWindow" then
        ReadQueueWindow()
    end
end)
ReadQueueWindow()

local function GcdBarAndSpark(durObj, gcdBar, gcdSpark, row, future, interp)
    local remaining = durObj:GetRemainingDuration()
    gcdBar:SetValue(remaining, interp)
    if remaining <= future then
        local sparkPx = TimeToPixel(remaining)
        local sparkXOffset = EHF.GetBarOffset() + sparkPx
        gcdSpark:ClearAllPoints()
        gcdSpark:SetPoint("LEFT", row, "LEFT", sparkXOffset, 0)
        gcdSpark:Show()

        -- Stands down while a cast outlasts the GCD; the cast spark draws it there.
        local qs, qb = row.queueSpark, row.queueBar
        local castLeft = sparkCast and (sparkCast.endTime - GetTime()) or 0
        if qs and CONFIG.queueSpark and queueWindowSeconds > 0
            and remaining > queueWindowSeconds and castLeft <= remaining then
            local qOffset = sparkXOffset - (TimeToPixel(queueWindowSeconds) - TimeToPixel(0))
            qs:ClearAllPoints()
            qs:SetPoint("LEFT", row, "LEFT", qOffset, 0)
            qs:Show()
            if qb then
                qb:ClearAllPoints()
                qb:SetPoint("LEFT", row, "LEFT", qOffset, 0)
                qb:SetWidth(math.max(sparkXOffset - qOffset, 1))
                qb:Show()
            end
        else
            if qs then qs:Hide() end
            if qb then qb:Hide() end
        end
    else
        gcdSpark:Hide()
        if row.queueSpark then row.queueSpark:Hide() end
        if row.queueBar then row.queueBar:Hide() end
    end
end


-- Seconds left on whatever is running, or nil when nothing is. gcdActive alone is NOT
-- usable: it is cleared solely by OnCooldownDone and was measured true with the GCD
-- already at 0, so the duration is the authority.
local function RunningLeft(now)
    if sparkCast and sparkCast.endTime > now then
        return sparkCast.endTime - now
    end
    if gcdActive and cachedGcdDurObj then
        local gOk, g = pcall(cachedGcdDurObj.GetRemainingDuration, cachedGcdDurObj)
        if gOk and not issecretvalue(g) and type(g) == "number" and g > 0 then
            return g
        end
    end
    return nil
end

-- How long after a secured cast ends a press still counts as a redundant mash rather
-- than a miss. The seam measured ~70ms; this is bounded well above that.
local SEAM_GRACE = 0.25

-- MEASURED: UseAction is the press. Colour is WHEN it landed; brightness is whether it
-- was the one that actually got queued, which only dispatch can tell us.
-- See docs/press-marks.md.
local function JudgePress()
    if not CONFIG.pressSpark or not ns.PressMarks_Push then return end
    local now = GetTime()
    -- UseAction fires twice per press, same millisecond.
    if ns._pmLastPress and (now - ns._pmLastPress) < 0.02 then return end
    ns._pmLastPress = now

    -- A press inside the window SECURES the cast, which excuses a mash in the seam
    -- just after it. Anything else with nothing running is a miss.
    local left = RunningLeft(now)
    local inWindow = left ~= nil and left <= queueWindowSeconds
    if inWindow then
        -- Securing a cast protects only the SEAM: from now until that cast ends, plus
        -- a little. A sticky flag excused presses two seconds later.
        ns._pmSeamUntil = now + left + SEAM_GRACE
        ns._pmMissed = false
    elseif left == nil and now > (ns._pmSeamUntil or 0) then
        ns._pmMissed = true
    end
    local late = ns._pmMissed and not inWindow or false
    -- Out of combat there is no window to have missed.
    -- Forever: pcall + reject secret/nil so a restricted boolean cannot clear miss state.
    local okCombat, inCombat = pcall(UnitAffectingCombat, "player")
    if okCombat and inCombat ~= nil and not (issecretvalue and issecretvalue(inCombat)) and not inCombat then
        late, ns._pmMissed = false, false
    end
    ns.PressMarks_Push(late)
end

-- Wrapped: fires on every press, inside Blizzard's secure call chain.
-- ArcUI also hooks CastSpellByID and CastSpellByName. Deliberately not copied: an
-- action bar macro already reaches UseAction, so those only add trigger surface.
if hooksecurefunc then
    hooksecurefunc("UseAction", function() pcall(JudgePress) end)
end

local updateTimer = 0
local buffPollTimer = 0
-- The mirror widget is re-resolved every call because the viewer pools frames.
local function FillBuffLaneBar(row, lane, interp)
    local bar = row[lane.bar]
    if not bar then return end

    local slot = row[lane.totemSlot]
    if slot then
        local timeLeft = GetTotemTimeLeft(slot)
        if timeLeft ~= nil then
            bar:SetValue(timeLeft, interp)
        else
            bar:Hide()
            row[lane.totemSlot] = nil
        end
        return
    end

    if row[lane.mirror] and row[lane.tracked] then
        -- A fresh push already wrote this lane with the value the read would
        -- return. If pushes stop, the read resumes on the next frame by itself.
        local pushAt = row[lane.push]
        if pushAt and (GetTime() - pushAt) < MIRROR_FRESH then return end

        local mf = ResolveBuffFrame(row[lane.mirror])
        local mbar = mf and mf.Bar
        local ok, val = false, nil
        if mbar then ok, val = pcall(mbar.GetValue, mbar) end
        if ok then
            bar:SetValue(val, interp)
            mirrorPollCount = mirrorPollCount + 1
        else
            -- A failed read is unknown, not ended, so mark dirty rather than hide.
            row._buffDirty = true
        end
        return
    end

    local dur = row[lane.dur]
    if dur then
        local ok, val
        if BuffFillCurve then
            ok, val = pcall(dur.EvaluateRemainingDuration, dur, BuffFillCurve)
        else
            ok, val = pcall(dur.GetRemainingDuration, dur)
        end
        if ok then bar:SetValue(val, interp) else bar:Hide() end
    end
end

EH_Parent:SetScript("OnUpdate", function(self, elapsed)
    updateTimer = updateTimer + elapsed

    -- 10Hz buff data polling
    buffPollTimer = buffPollTimer + elapsed
    if buffPollTimer >= 0.1 then
        buffPollTimer = 0
        if InCombatLockdown() then
            -- In combat: only process rows dirtied by aura hooks (no frame pool iteration)
            for _, row in ipairs(cooldownBars) do
                local visible = row:IsShown()
                if visible and not row._wasVisible then
                    row._buffDirty = true
                end
                row._wasVisible = visible
                -- Hidden rows keep their dirty flag so the show edge reconciles.
                if row._buffDirty and visible then
                    row._buffDirty = false
                    EHF.UpdateBuffState(row, buffMapProxy)
                    EHF.UpdateStackText(row, buffMapProxy)
                end
            end
        else
            UpdateBars()
        end
        if siIsBuilt and CONFIG.stackIndicators then
            EHF.UpdateAllSIPips()
        end
    end

    if updateTimer >= 0.033 then
        local interp = GetInterpolation()
        -- The push runs on Blizzard's frame, between our ticks, so it reads the
        -- last resolved value rather than recomputing inside their call stack.
        mirrorInterp = interp

        for _, row in ipairs(cooldownBars) do
            -- Cooldown bar fill
            if row.activeCooldown then
                local ok, remaining = pcall(row.activeCooldown.GetRemainingDuration, row.activeCooldown)
                if ok then
                    row.cdBar:SetValue(remaining, interp)
                elseif not row.isChargeSpell then
                    row.cdBar:Hide()
                end
            end

            -- CD past slide
            if not row.isChargeSpell and row.hidden_cd then
                local cdActive = row.hidden_cd:IsShown()
                if cdActive and not row.activeCdSlide then
                    row.activeCdSlide = EHF.SpawnPastSlide(row, row.pastCdClip, GetCooldownColor(row), row.cdBar.fullHeight or CONFIG.height, 0)
                elseif not cdActive and row.activeCdSlide then
                    EHF.DetachPastSlide(row.activeCdSlide)
                    row.activeCdSlide = nil
                end
            end

            FillBuffLaneBar(row, BUFF_LANES[1], interp)
            FillBuffLaneBar(row, BUFF_LANES[2], interp)
            FillBuffLaneBar(row, BUFF_LANES[3], interp)

            -- Charge bars
            if row.isChargeSpell and row.depletedWrapper then
                -- Per-frame charge count feed
                local cOk, cInfo = pcall(C_Spell.GetSpellCharges, row.spellID)
                if cOk then FeedChargeIndicators(row, cInfo) end

                local chargeDurObj = row._chargeDurObj

                -- depletedCdBar fill
                local cdDurObj = row._cdDurObj

                -- Charge bar alpha
                if chargeDurObj and AlphaCurve then
                    local ok, chargeAlpha = pcall(chargeDurObj.EvaluateRemainingDuration, chargeDurObj, AlphaCurve)
                    if ok then
                        row.depletedChargeBar:SetAlpha(chargeAlpha)
                        row.normalChargeBar:SetAlpha(chargeAlpha)
                        if row.middleLanes then
                            for j = 1, #row.middleLanes do
                                local ml = row.middleLanes[j]
                                if ml then ml.depletedChargeBar:SetAlpha(chargeAlpha) end
                            end
                        end
                    end
                else
                    row.depletedChargeBar:SetAlpha(0)
                    row.normalChargeBar:SetAlpha(0)
                    if row.middleLanes then
                        for j = 1, #row.middleLanes do
                            local ml = row.middleLanes[j]
                            if ml then ml.depletedChargeBar:SetAlpha(0) end
                        end
                    end
                end

                -- depletedCdBar alpha
                if cdDurObj and AlphaCurve then
                    local ok, a = pcall(cdDurObj.EvaluateRemainingDuration, cdDurObj, AlphaCurve)
                    if ok then row.depletedCdBar:SetAlpha(a) end
                else
                    row.depletedCdBar:SetAlpha(0)
                end

                -- depletedCdBar fill
                if cdDurObj then
                    local ok, remaining = pcall(cdDurObj.GetRemainingDuration, cdDurObj)
                    if ok then row.depletedCdBar:SetValue(remaining) end
                else
                    row.depletedCdBar:SetValue(0)
                end

                -- Helper bar alpha
                local isRecharging = row.hidden_charge and row.hidden_charge:IsShown()
                row.depletedHelperBar:SetAlpha(isRecharging and 1 or 0)
                if row.maxCharges and row.maxCharges > 2 then
                    if row.notDepletedHelperBar then
                        row.notDepletedHelperBar:SetAlpha(isRecharging and 1 or 0)
                    end
                    if row.middleLanes then
                        for j = 1, row.maxCharges - 2 do
                            local ml = row.middleLanes[j]
                            if ml then
                                ml.depletedHelperBar:SetAlpha(isRecharging and 1 or 0)
                            end
                        end
                    end
                end

                -- Past slides
                local topTexShown = row.hidden_cd and row.hidden_cd:IsShown()
                local bottomTexShown = isRecharging
                local laneH = row.cdBar.laneHeight or ((CONFIG.height / 2) - 0.5)

                -- Top lane
                if topTexShown and not row.activeDepletedSlide then
                    row.activeDepletedSlide = EHF.SpawnPastSlide(row,
                        row.pastCdClip, GetCooldownColor(row), laneH, 0)
                    row._depletedSpawnTime = GetTime()
                elseif row.activeDepletedSlide and not row.activeDepletedSlide.detachTime and not topTexShown then
                    row.activeDepletedSlide.tex:SetAlpha(row.activeDepletedSlide.color[4] or GetCooldownColor(row)[4] or 0.5)
                    EHF.DetachPastSlide(row.activeDepletedSlide)
                    row.activeDepletedSlide = nil
                    row._depletedSpawnTime = nil
                end

                -- Bottom lane
                if bottomTexShown and not row.activeChargeSlide then
                    row.activeChargeSlide = EHF.SpawnPastSlide(row,
                        row.pastCdClip, GetCooldownColor(row),
                        laneH, -ChargeBottomY(row, laneH, row.maxCharges))
                    row._chargeSpawnTime = GetTime()
                elseif row.activeChargeSlide and not row.activeChargeSlide.detachTime and not bottomTexShown then
                    row.activeChargeSlide.tex:SetAlpha(row.activeChargeSlide.color[4] or GetCooldownColor(row)[4] or 0.5)
                    EHF.DetachPastSlide(row.activeChargeSlide)
                    row.activeChargeSlide = nil
                    row._chargeSpawnTime = nil
                end

                if ns.ChargePast_Update then
                    ns.ChargePast_Update(row, GetCooldownColor(row))
                end

                -- Safety timeout
                local safetyNow = GetTime()
                local maxSlideDur = (row.maxCharges or 2) * (row.chargeDurationConstant or 12) + 2
                if row._depletedSpawnTime and safetyNow - row._depletedSpawnTime > maxSlideDur then
                    if row.activeDepletedSlide then
                        row.activeDepletedSlide.tex:SetAlpha(row.activeDepletedSlide.color[4] or GetCooldownColor(row)[4] or 0.5)
                    end
                    EHF.DetachPastSlide(row.activeDepletedSlide)
                    row.activeDepletedSlide = nil
                    row._depletedSpawnTime = nil
                end
                if row._chargeSpawnTime and safetyNow - row._chargeSpawnTime > maxSlideDur then
                    if row.activeChargeSlide then
                        row.activeChargeSlide.tex:SetAlpha(row.activeChargeSlide.color[4] or GetCooldownColor(row)[4] or 0.5)
                    end
                    EHF.DetachPastSlide(row.activeChargeSlide)
                    row.activeChargeSlide = nil
                    row._chargeSpawnTime = nil
                end
                if row.middleLanes then
                    for j = 1, #row.middleLanes do
                        local ml = row.middleLanes[j]
                        if ml and ml.activeSlide and ml._slideSpawnTime and safetyNow - ml._slideSpawnTime > maxSlideDur then
                            ml.activeSlide.tex:SetAlpha(ml.activeSlide.color[4] or GetCooldownColor(row)[4] or 0.5)
                            EHF.DetachPastSlide(ml.activeSlide)
                            ml.activeSlide = nil
                            ml._slideSpawnTime = nil
                        end
                    end
                end


            end

            -- Buff, overlay, and third past slides
            UpdateBuffPastSlide(row, row.buffBar:IsShown(), "activeBuffSlide", "pastBuffClip", "resolvedBuffColor")
            UpdateBuffPastSlide(row, row.buffBarOverlay and row.buffBarOverlay:IsShown(), "activeOverlaySlide", "pastOverlayClip", "resolvedOverlayColor")
            UpdateBuffPastSlide(row, row.buffBarThird and row.buffBarThird:IsShown(), "activeThirdSlide", "pastThirdClip", "resolvedThirdColor")

            -- Pandemic polling. cachedPandemicIcon is the game's own PandemicIcon,
            -- which exists only during the window, so its shown state is the
            -- answer and involves no secret value.
            if row.cachedPandemicIcon and CONFIG.pandemicPulse then
                local panOk, panShown = pcall(row.cachedPandemicIcon.IsShown, row.cachedPandemicIcon)
                if panOk and panShown then
                    if not row.buffPandemicAnim:IsPlaying() then
                        row.buffPandemicAnim:Play()
                    end
                else
                    if row.buffPandemicAnim:IsPlaying() then
                        row.buffPandemicAnim:Stop()
                        row.buffBar:SetAlpha(1.0)
                    end
                    if not panOk then
                        row.cachedPandemicIcon = nil
                    end
                end
            end

            -- GCD rendering
            if gcdActive and cachedGcdDurObj then
                local gcdOk = pcall(GcdBarAndSpark, cachedGcdDurObj, row.gcdBar, row.gcdSpark, row, CONFIG.future, interp)
                if not gcdOk then
                    row.gcdSpark:Hide()
                    if row.queueSpark then row.queueSpark:Hide() end
                    if row.queueBar then row.queueBar:Hide() end
                end
                if not row.gcdBar:IsShown() then row.gcdBar:Show() end
            elseif row.gcdBar:IsShown() then
                row.gcdBar:Hide()
                row.gcdSpark:Hide()
                if row.queueSpark then row.queueSpark:Hide() end
                if row.queueBar then row.queueBar:Hide() end
            end

            if ns.UpdateDotTicks then ns.UpdateDotTicks(row) end

        end

        UpdateActiveCastBar()
        UpdateCastSpark()
        UpdatePastSlides()
        if ns.PressMarks_Update then ns.PressMarks_Update() end

        if not gcdActive then
            cachedGcdDurObj = nil
            lastFedGcdDurObj = nil
        end

        updateTimer = updateTimer - 0.033
    end
end)

local function ResetBarState(bar)
    HandleProcGlow(bar, false)
    bar.activeCooldown = nil
    bar.activeBuffDuration = nil
    bar._spellCategoryID = nil
    bar._potionWindowExpiry = nil
    -- Rows are pooled. A start time left on a recycled row belongs to whatever
    -- spell used to live here and would draw a phantom bar for the new one.
    bar._customTimerStart = nil
    bar._customTimerObj = nil
    bar._tickSpellResolved = nil
    bar._tickSpellID = nil
    bar._tickCastAt = nil
    bar._tickStart = nil
    bar._tickEnd = nil
    if type(bar.tickMarks) == "table" then
        for i = 1, #bar.tickMarks do
            if bar.tickMarks[i] then bar.tickMarks[i]:Hide() end
        end
    end
    bar.activeBuffOverlayDuration = nil
    bar.activeBuffThirdDuration = nil
    bar.resolvedBuffColor = nil
    bar.resolvedOverlayColor = nil
    bar.resolvedThirdColor = nil
    bar.cachedPandemicIcon = nil
    if bar.buffPandemicAnim and bar.buffPandemicAnim:IsPlaying() then
        bar.buffPandemicAnim:Stop()
        bar.buffBar:SetAlpha(1.0)
    end

    bar.lastChargeDurObj = nil
    bar.lastCdDurObj = nil
    
    bar.lastPtr_cd = nil
    bar.lastPtr_charge = nil
    bar.lastPtr_buff = nil
    bar.lastPtr_overlay = nil
    bar.lastPtr_third = nil
    if bar.hidden_cd then bar.hidden_cd:SetCooldown(0, 0) end
    if bar.hidden_charge then bar.hidden_charge:SetCooldown(0, 0) end
    if bar.hidden_buff then bar.hidden_buff:SetCooldown(0, 0) end
    if bar.hidden_overlay then bar.hidden_overlay:SetCooldown(0, 0) end
    if bar.hidden_third then bar.hidden_third:SetCooldown(0, 0) end

    bar._buffDirty = false
    bar.isExtras = nil
    bar.extrasType = nil
    bar.extrasKey = nil
    bar._extrasAuraInstanceID = nil
    bar._totemSlot = nil
    bar._totemCooldownFed = false
    bar._overlayTotemSlot = nil
    bar._overlayTotemFed = false
    bar._thirdTotemSlot = nil
    bar._thirdTotemFed = false
    bar.trackedBuffAuraInstanceID = nil
    bar.trackedOverlayAuraInstanceID = nil
    bar.trackedThirdAuraInstanceID = nil
    bar._auraMirrorCdID = nil
    bar._auraMirrorCdIDOverlay = nil
    bar._auraMirrorCdIDThird = nil
    bar.secretAuraSpellId = nil
    bar.icon:SetDesaturation(0)
    bar.cdBar:Hide()
    bar.buffBar:Hide()
    if bar.buffBarOverlay then bar.buffBarOverlay:Hide() end
    if bar.buffBarThird then bar.buffBarThird:Hide() end
    if bar.cooldownFrame then bar.cooldownFrame:Hide() end
    HideCastOverlays(bar)
    if bar.depletedWrapper then bar.depletedWrapper:Hide() end
    if bar.notDepletedWrapper then bar.notDepletedWrapper:Hide() end
    if ns.ChargePast_Reset then ns.ChargePast_Reset(bar) end
    if bar.middleLanes then
        for _, ml in ipairs(bar.middleLanes) do
            ml.depletedChargeBar:Hide()
            ml.depletedHelperBar:Hide()
            ml.activeSlide = nil
        end
    end
    if bar.notDepletedHelperBar then bar.notDepletedHelperBar:Hide() end
    if bar.ndHelperSpacer then bar.ndHelperSpacer:Hide() end
    if bar.pastSlides then
        for _, slide in ipairs(bar.pastSlides) do
            slide.tex:Hide()
            slide.active = false
        end
    end
    bar.activeCdSlide = nil
    bar.activeBuffSlide = nil
    bar.activeOverlaySlide = nil
    bar.activeThirdSlide = nil
    bar.activeDepletedSlide = nil
    bar.activeChargeSlide = nil
    bar.chargeText:Hide()
    bar.stackText:Hide()
    if bar.variantNameText then bar.variantNameText:Hide() end
    if bar.cdTextCooldown then
        bar.cdTextCooldown:SetCooldown(0, 0)
        pcall(bar.cdTextCooldown.SetHideCountdownNumbers, bar.cdTextCooldown, not CONFIG.showCooldownDuration)
        pcall(bar.cdTextCooldown.SetMinimumCountdownDuration, bar.cdTextCooldown, (CONFIG.cdTextMinDuration or 30) * 1000)
        bar._cdTextStyled = false
    end

    -- reused bars need font re-applied
    ApplyFont(bar.chargeText, CONFIG.fontSize)
    ApplyFont(bar.stackText, CONFIG.fontSize)
    if bar.variantNameText then
        ApplyFont(bar.variantNameText, CONFIG.variantTextSize or (CONFIG.fontSize - 2))
        bar.variantNameText:SetTextColor(unpack(CONFIG.variantTextColor))
        bar.variantNameText:ClearAllPoints()
        bar.variantNameText:SetPoint(CONFIG.variantTextAnchor, bar.barTextOverlay, CONFIG.variantTextRelPoint, CONFIG.variantTextOffsetX, CONFIG.variantTextOffsetY)
    end
    bar.chargeText:SetTextColor(unpack(CONFIG.chargeTextColor))
    bar.stackText:SetTextColor(unpack(CONFIG.stackTextColor))
    ApplyTextAnchors(bar)
end

-- Follows bar.spellID, the OVERRIDE when one exists, or a hero-talent form
-- shows its base spell's art. Item entries resolve from the category.
local function ApplyRowDisplay(bar, cooldownID)
    local customID = CONFIG.customIcons and CONFIG.customIcons[cooldownID]
    local customTex = customID and C_Spell.GetSpellTexture(customID)
    local info = bar.spellID and C_Spell.GetSpellInfo(bar.spellID) or nil
    if info then
        bar.spellName = info.name
        bar.icon:SetTexture(customTex or info.iconID)
    else
        local rName, rIcon = ns.ResolveCooldownDisplay(cooldownID)
        bar.spellName = rName or ("ID:" .. tostring(cooldownID))
        bar.icon:SetTexture(customTex or rIcon or 134400)
    end
end

local function ConfigureBarForSpell(bar, spellID, cooldownID, index)
    bar.spellID = spellID
    bar.baseSpellID = spellID
    bar.cooldownID = cooldownID

    -- Item category entries resolve their live spell per update.
    local ciOk, ciInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
    bar._spellCategoryID = (ciOk and ciInfo and not spellID) and ciInfo.spellCategoryID or nil
    -- The CDM carries no timing, so an equipped item's cooldown comes from its slot.
    bar._equipSlot = (ciOk and ciInfo) and ciInfo.equipSlot or nil

    -- Build set of all buff cooldownIDs that affect this row
    bar._buffCooldownIDs = nil
    bar._buffDirty = false
    local bMappings = CONFIG.buffMappings and (CONFIG.buffMappings[cooldownID] or CONFIG.buffMappings[spellID])
    if bMappings then
        for _, mapData in ipairs(bMappings) do
            if mapData.buffCooldownIDs then
                for _, mappedID in ipairs(mapData.buffCooldownIDs) do
                    bar._buffCooldownIDs = bar._buffCooldownIDs or {}
                    bar._buffCooldownIDs[mappedID] = true
                end
            end
        end
    end
    local sMapping = CONFIG.stackMappings and (CONFIG.stackMappings[cooldownID] or CONFIG.stackMappings[spellID])
    if sMapping and sMapping.buffCooldownID then
        bar._buffCooldownIDs = bar._buffCooldownIDs or {}
        bar._buffCooldownIDs[sMapping.buffCooldownID] = true
    end

    -- Detect multi-variant spell (for variant name display)
    local cdInfoOk, cdInfoData = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
    bar._isMultiVariant = cdInfoOk and cdInfoData and cdInfoData.linkedSpellIDs and #cdInfoData.linkedSpellIDs > 1 or false

    -- Resolve override spell
    local ovOk, ovID = pcall(C_Spell.GetOverrideSpell, spellID)
    if ovOk and ovID and ovID ~= spellID then
        bar.spellID = ovID
    end

    -- Glow belongs to the spell, not the frame. Rows are pooled, so resync
    -- through HandleProcGlow, which owns the art; a flag alone leaves it lit.
    if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
        local gOk, isOverlayed = pcall(C_SpellActivationOverlay.IsSpellOverlayed, bar.spellID)
        HandleProcGlow(bar, (gOk and isOverlayed) and true or false)
    else
        HandleProcGlow(bar, false)
    end

    local isChargeSpell = false
    local chargeInfo = GetChargesWithOverride(bar.spellID, spellID)
    local detectedMaxCharges
    local chargeOverride = CONFIG.chargeOverflow and CONFIG.chargeOverflow[bar.baseSpellID]
    local maxCap = chargeOverride and chargeOverride.trueMax or nil

    if chargeInfo and chargeInfo.maxCharges then
        -- maxCharges is NeverSecret so this should never fire. Fails safe rather
        -- than using a saved value: a stale max draws lanes the spell lacks.
        if issecretvalue(chargeInfo.maxCharges) then
            -- no usable count, leave it as a single bar
        else
            local effectiveMax = chargeInfo.maxCharges
            -- A proc can grant a temporary extra charge and strand a lane. Those spells
            -- declare their real base in ClassConfig.
            local declaredBase = chargeOverride and chargeOverride.base
            if declaredBase then effectiveMax = declaredBase end
            if maxCap and effectiveMax > maxCap then effectiveMax = maxCap end
            if effectiveMax > 1 then
                isChargeSpell = true
                detectedMaxCharges = effectiveMax
            end
            InfallDB.chargeSpells = InfallDB.chargeSpells or {}
            if effectiveMax > 1 then
                InfallDB.chargeSpells[cooldownID] = {
                    hasChargeMechanic = true,
                    maxCharges = effectiveMax
                }
            else
                InfallDB.chargeSpells[cooldownID] = nil
            end
        end
    end
    
    bar.hasCharges = isChargeSpell

    -- User toggle: single bar, but keep charge count text
    if isChargeSpell and CONFIG.chargesDisabled and CONFIG.chargesDisabled[cooldownID] then
        isChargeSpell = false
        detectedMaxCharges = nil
    end

    bar.isChargeSpell = isChargeSpell

    local prevMaxCharges = bar.maxCharges
    if isChargeSpell then
        bar.maxCharges = detectedMaxCharges or 2
    else
        bar.maxCharges = 1
    end

    if prevMaxCharges and prevMaxCharges ~= bar.maxCharges then
        local cdColor = GetCooldownColor(bar)
        if bar.activeChargeSlide then
            bar.activeChargeSlide.tex:SetAlpha(bar.activeChargeSlide.color[4] or cdColor[4] or 0.5)
            EHF.DetachPastSlide(bar.activeChargeSlide)
            bar.activeChargeSlide = nil
            bar._chargeSpawnTime = nil
        end
        if bar.activeDepletedSlide then
            bar.activeDepletedSlide.tex:SetAlpha(bar.activeDepletedSlide.color[4] or cdColor[4] or 0.5)
            EHF.DetachPastSlide(bar.activeDepletedSlide)
            bar.activeDepletedSlide = nil
            bar._depletedSpawnTime = nil
        end
        if bar.middleLanes then
            for _, ml in ipairs(bar.middleLanes) do
                if ml.activeSlide then
                    ml.activeSlide.tex:SetAlpha(ml.activeSlide.color[4] or cdColor[4] or 0.5)
                    EHF.DetachPastSlide(ml.activeSlide)
                    ml.activeSlide = nil
                    ml._slideSpawnTime = nil
                end
            end
        end
    end
    
    if isChargeSpell and chargeInfo then
        if not issecretvalue(chargeInfo.cooldownDuration) and chargeInfo.cooldownDuration > 0 then
            bar.chargeDurationConstant = chargeInfo.cooldownDuration
            InfallDB.chargeDurations = InfallDB.chargeDurations or {}
            InfallDB.chargeDurations[cooldownID] = chargeInfo.cooldownDuration
        else
            local saved = InfallDB.chargeDurations and InfallDB.chargeDurations[cooldownID]
            if saved then
                bar.chargeDurationConstant = saved
            end
        end
    elseif not isChargeSpell then
        bar.chargeDurationConstant = nil
    end
    
    ApplyRowDisplay(bar, cooldownID)

    bar.cdBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))

    if isChargeSpell then
        bar.cdBar:SetHeight(bar.cdBar.laneHeight)
    else
        bar.cdBar:SetHeight(bar.cdBar.fullHeight)
    end

    if isChargeSpell then
        local futureWidth = GetFutureWidth()
        local nowPx = GetNowPixelOffset()
        local nowOffset = EHF.GetBarOffset() + nowPx
        local maxC = bar.maxCharges or 2
        local barHeight = bar.cdBar.fullHeight or CONFIG.height
        local laneH = SetChargeLaneMetrics(bar, barHeight, maxC)

        -- slotPx: charge duration in pixels
        local slotPx = 0
        if bar.chargeDurationConstant then
            -- NEVER clamp. This width IS the charge duration on the timeline,
            -- which is what makes the fill read as seconds, and (maxC-1)*slotPx
            -- is how the lower lane shows cd+cd without touching a secret.
            slotPx = math.max(1, (bar.chargeDurationConstant / CONFIG.future) * futureWidth)
        elseif not chargeDurWarned[cooldownID] then
            -- Without it there is no width that reads as seconds, so the lane is
            -- left blank rather than filled with a percentage.
            chargeDurWarned[cooldownID] = true
            print("|cff00ff00[Infall]|r No charge duration for "
                .. (bar.spellName or ("cooldown " .. tostring(cooldownID)))
                .. ": charge lane will stay empty. Clear restrictions and /reload to fix.")
        end
        bar._chargeSlotPx = slotPx
        -- No duration means no width that reads as seconds: draw nothing
        -- rather than a percentage dressed up as time.
        bar._chargeDurUnknown = slotPx <= 0
        local chargeDurPx = slotPx > 0 and slotPx or futureWidth

        local fillW, fillMax = chargeDurPx, 1

        if not bar.depletedIndicator then
            bar.depletedIndicator = CreateFrame("StatusBar", nil, bar)
            bar.depletedIndicator:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
            bar.depletedIndicator:GetStatusBarTexture():SetAlpha(0)
            bar.depletedIndicator:SetOrientation("VERTICAL")
            bar.depletedIndicator:SetMinMaxValues(0, 1)
            CrispBar(bar.depletedIndicator)
        end
        if not bar.depletedWrapper then
            bar.depletedWrapper = CreateFrame("Frame", nil, bar)
            bar.depletedWrapper:SetFrameLevel(bar:GetFrameLevel() + 1)
            bar.depletedWrapper:SetClipsChildren(true)

            bar.depletedCdBar = CreateStatusBar(bar.depletedWrapper)
            bar.depletedCdBar:Show()

            bar.depletedHelperBar = CreateStatusBar(bar.depletedWrapper, 1)
            bar.depletedHelperBar:SetValue(1)
            bar.depletedHelperBar:Show()

            bar.depletedChargeBar = CreateStatusBar(bar.depletedWrapper)
            bar.depletedChargeBar:Show()

            bar.notDepletedWrapper = CreateFrame("Frame", nil, bar)
            bar.notDepletedWrapper:SetFrameLevel(bar:GetFrameLevel() + 1)
            bar.notDepletedWrapper:SetClipsChildren(true)

            bar.normalChargeBar = CreateStatusBar(bar.notDepletedWrapper)
            bar.normalChargeBar:Show()
        end

        bar.depletedIndicator:ClearAllPoints()
        bar.depletedIndicator:SetSize(futureWidth, CONFIG.height)
        bar.depletedIndicator:SetPoint("TOPLEFT", bar, "TOPLEFT", nowOffset, 0)
        bar.depletedIndicator:SetValue(0)
        bar.depletedIndicator:Show()

        -- depletedWrapper: visible at 0 charges, notDepletedWrapper: visible at 1+ charges
        bar.depletedWrapper:ClearAllPoints()
        bar.depletedWrapper:SetPoint("TOPLEFT", bar, "TOPLEFT", nowOffset, 0)
        bar.depletedWrapper:SetPoint("BOTTOMRIGHT", bar.depletedIndicator:GetStatusBarTexture(), "TOPRIGHT")
        bar.depletedWrapper:SetAlpha(1)
        bar.depletedWrapper:Show()

        bar.notDepletedWrapper:ClearAllPoints()
        bar.notDepletedWrapper:SetPoint("TOPLEFT", bar.depletedIndicator:GetStatusBarTexture(), "TOPLEFT")
        bar.notDepletedWrapper:SetPoint("BOTTOMRIGHT", bar, "TOPLEFT", nowOffset + futureWidth, -CONFIG.height)
        bar.notDepletedWrapper:SetAlpha(1)
        bar.notDepletedWrapper:Show()

        local bottomY = ChargeBottomY(bar, laneH, maxC)
        bar.depletedCdBar:SetParent(bar.depletedWrapper)
        bar.depletedCdBar:SetFrameLevel(bar:GetFrameLevel() + 1)
        bar.depletedCdBar:ClearAllPoints()
        bar.depletedCdBar:SetSize(futureWidth, laneH)
        bar.depletedCdBar:SetMinMaxValues(0, CONFIG.future)
        bar.depletedCdBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", 0, 0)
        bar.depletedCdBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))

        local bottomSlotPx = (maxC - 1) * slotPx
        bar.depletedHelperBar:ClearAllPoints()
        bar.depletedHelperBar:SetSize(math.max(1, bottomSlotPx), laneH)
        bar.depletedHelperBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", 0, bottomY)
        bar.depletedHelperBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))

        bar.depletedChargeBar:ClearAllPoints()
        bar.depletedChargeBar:SetSize(fillW, laneH)
        bar.depletedChargeBar:SetMinMaxValues(0, fillMax)
        bar.depletedChargeBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", bottomSlotPx, bottomY)
        bar.depletedChargeBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))

        bar.normalChargeBar:ClearAllPoints()
        bar.normalChargeBar:SetSize(fillW, laneH)
        bar.normalChargeBar:SetMinMaxValues(0, fillMax)
        bar.normalChargeBar:SetPoint("TOPLEFT", bar.notDepletedWrapper, "TOPLEFT", 0, bottomY)
        bar.normalChargeBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))

        -- 3+ charge bottom lane helper + spacer in notDepletedWrapper
        if maxC > 2 then
            if not bar.notDepletedHelperBar then
                bar.notDepletedHelperBar = CreateFrame("StatusBar", nil, bar.notDepletedWrapper)
                bar.notDepletedHelperBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                bar.notDepletedHelperBar:SetMinMaxValues(0, 1)
                bar.notDepletedHelperBar:SetValue(1)
                bar.notDepletedHelperBar:SetOrientation("HORIZONTAL")
                bar.notDepletedHelperBar:GetStatusBarTexture():SetHorizTile(false)
                bar.notDepletedHelperBar:GetStatusBarTexture():SetVertTile(false)
                CrispBar(bar.notDepletedHelperBar)
            end

            if not bar.ndHelperSpacer then
                bar.ndHelperSpacer = CreateFrame("StatusBar", nil, bar.notDepletedWrapper)
                bar.ndHelperSpacer:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                bar.ndHelperSpacer:SetReverseFill(true)
                bar.ndHelperSpacer:GetStatusBarTexture():SetAlpha(0)
            end
            bar.ndHelperSpacer:SetMinMaxValues(0, maxC - 1)
            bar.ndHelperSpacer:SetSize(math.max(1, bottomSlotPx), laneH)
            bar.ndHelperSpacer:ClearAllPoints()
            bar.ndHelperSpacer:SetPoint("TOPLEFT", bar.notDepletedWrapper, "TOPLEFT", 0, bottomY)
            bar.ndHelperSpacer:SetValue(0)
            bar.ndHelperSpacer:Show()

            bar.notDepletedHelperBar:ClearAllPoints()
            bar.notDepletedHelperBar:SetPoint("TOPLEFT", bar.notDepletedWrapper, "TOPLEFT", 0, bottomY)
            bar.notDepletedHelperBar:SetPoint("BOTTOMRIGHT", bar.ndHelperSpacer:GetStatusBarTexture(), "BOTTOMLEFT")
            bar.notDepletedHelperBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))
            bar.notDepletedHelperBar:SetAlpha(0)
            bar.notDepletedHelperBar:Show()

            bar.normalChargeBar:ClearAllPoints()
            bar.normalChargeBar:SetPoint("TOPLEFT", bar.ndHelperSpacer:GetStatusBarTexture(), "TOPLEFT")
        elseif bar.notDepletedHelperBar then
            bar.notDepletedHelperBar:Hide()
            if bar.ndHelperSpacer then bar.ndHelperSpacer:Hide() end
        end

        -- Middle lanes (3+ charges): clip indicator + wrapper per threshold
        bar.middleLanes = bar.middleLanes or {}
        bar.middleClipIndicators = bar.middleClipIndicators or {}
        bar.middleClipWrappers = bar.middleClipWrappers or {}
        if maxC > 2 then
            local wrapperLevel = bar:GetFrameLevel() + 1
            for j = 1, maxC - 2 do
                if not bar.middleClipIndicators[j] then
                    bar.middleClipIndicators[j] = CreateFrame("StatusBar", nil, bar)
                    bar.middleClipIndicators[j]:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
                    bar.middleClipIndicators[j]:GetStatusBarTexture():SetAlpha(0)
                    bar.middleClipIndicators[j]:SetOrientation("VERTICAL")
                    CrispBar(bar.middleClipIndicators[j])
                end
                bar.middleClipIndicators[j]:ClearAllPoints()
                bar.middleClipIndicators[j]:SetMinMaxValues(maxC - j - 1, maxC - j)
                bar.middleClipIndicators[j]:SetSize(futureWidth, CONFIG.height)
                bar.middleClipIndicators[j]:SetPoint("TOPLEFT", bar, "TOPLEFT", nowOffset, 0)
                bar.middleClipIndicators[j]:SetValue(0)
                bar.middleClipIndicators[j]:Show()

                if not bar.middleClipWrappers[j] then
                    bar.middleClipWrappers[j] = CreateFrame("Frame", nil, bar)
                    bar.middleClipWrappers[j]:SetClipsChildren(true)
                end
                if ns.ChargePast_Build then ns.ChargePast_Build(bar, maxC, laneH) end
                bar.middleClipWrappers[j]:SetFrameLevel(wrapperLevel)
                bar.middleClipWrappers[j]:ClearAllPoints()
                bar.middleClipWrappers[j]:SetPoint("TOPLEFT", bar, "TOPLEFT", nowOffset, 0)
                bar.middleClipWrappers[j]:SetPoint("BOTTOMRIGHT",
                    bar.middleClipIndicators[j]:GetStatusBarTexture(), "TOPRIGHT")
                bar.middleClipWrappers[j]:Show()

                if not bar.middleLanes[j] then
                    local ml = {}
                    ml.depletedChargeBar = CreateFrame("StatusBar", nil, bar.middleClipWrappers[j])
                    ml.depletedChargeBar:SetFrameLevel(wrapperLevel)
                    ml.depletedChargeBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                    ml.depletedChargeBar:SetMinMaxValues(0, 1)
                    ml.depletedChargeBar:SetOrientation("HORIZONTAL")
                    ml.depletedChargeBar:GetStatusBarTexture():SetHorizTile(false)
                    ml.depletedChargeBar:GetStatusBarTexture():SetVertTile(false)
                    CrispBar(ml.depletedChargeBar)

                    ml.depletedHelperBar = CreateFrame("StatusBar", nil, bar.depletedWrapper)
                    ml.depletedHelperBar:SetFrameLevel(wrapperLevel)
                    ml.depletedHelperBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                    ml.depletedHelperBar:SetMinMaxValues(0, 1)
                    ml.depletedHelperBar:SetValue(1)
                    ml.depletedHelperBar:SetOrientation("HORIZONTAL")
                    ml.depletedHelperBar:GetStatusBarTexture():SetHorizTile(false)
                    ml.depletedHelperBar:GetStatusBarTexture():SetVertTile(false)
                    CrispBar(ml.depletedHelperBar)

                    bar.middleLanes[j] = ml
                else
                    bar.middleLanes[j].depletedChargeBar:SetParent(bar.middleClipWrappers[j])
                    bar.middleLanes[j].depletedHelperBar:SetParent(bar.depletedWrapper)
                end
                local ml = bar.middleLanes[j]
                local laneY = -(j * ChargeLanePitch(bar, laneH))
                local mlSlotPx = j * slotPx

                ml.depletedHelperBar:ClearAllPoints()
                ml.depletedHelperBar:SetSize(math.max(1, mlSlotPx), laneH)
                ml.depletedHelperBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", 0, laneY)
                ml.depletedHelperBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))
                ml.depletedHelperBar:SetAlpha(0)
                ml.depletedHelperBar:Show()

                if not ml.helperSpacer then
                    ml.helperSpacer = CreateFrame("StatusBar", nil, bar.middleClipWrappers[j])
                    ml.helperSpacer:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                    ml.helperSpacer:SetReverseFill(true)
                    ml.helperSpacer:GetStatusBarTexture():SetAlpha(0)
                end
                ml.helperSpacer:SetMinMaxValues(0, 1)
                ml.helperSpacer:SetSize(math.max(1, mlSlotPx), laneH)
                ml.helperSpacer:ClearAllPoints()
                ml.helperSpacer:SetPoint("TOPLEFT", bar.middleClipWrappers[j], "TOPLEFT", 0, laneY)
                ml.helperSpacer:SetValue(0)
                ml.helperSpacer:Show()

                ml.depletedChargeBar:ClearAllPoints()
                ml.depletedChargeBar:SetSize(fillW, laneH)
                ml.depletedChargeBar:SetMinMaxValues(0, fillMax)
                ml.depletedChargeBar:SetPoint("TOPLEFT", ml.helperSpacer:GetStatusBarTexture(), "TOPLEFT")
                ml.depletedChargeBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))
                ml.depletedChargeBar:Show()
            end
        end
        for j = (maxC > 2 and maxC - 1 or 1), #bar.middleLanes do
            local ml = bar.middleLanes[j]
            if ml then
                ml.depletedChargeBar:Hide()
                ml.depletedHelperBar:Hide()
                if ml.activeSlide then
                    EHF.DetachPastSlide(ml.activeSlide)
                    ml.activeSlide = nil
                end
            end
            if bar.middleClipIndicators and bar.middleClipIndicators[j] then
                bar.middleClipIndicators[j]:Hide()
            end
            if bar.middleClipWrappers and bar.middleClipWrappers[j] then
                bar.middleClipWrappers[j]:Hide()
            end
        end

        bar.cdBar:Hide()

    else
        if bar.depletedWrapper then
            bar.depletedWrapper:Hide()
            bar.notDepletedWrapper:Hide()
        end
        if bar.notDepletedHelperBar then bar.notDepletedHelperBar:Hide() end
        if bar.middleLanes then
            for _, ml in ipairs(bar.middleLanes) do
                ml.depletedChargeBar:Hide()
                ml.depletedHelperBar:Hide()
            end
        end
    end

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - ((index - 1) * (CONFIG.height + CONFIG.spacing)))
end

-- EXTRAS: Auto-detect racials + potions

local function DetectExtras()
    local extras = CONFIG.extras or {}

    -- On 12.1 the Cooldown Manager carries potions and trinkets natively, so drop
    -- any a saved profile still holds. Custom and racial rows are untouched.
    local kept = {}
    for _, e in ipairs(extras) do
        if e.type == "custom" then
            kept[#kept + 1] = e
        end
    end
    extras = kept


    CONFIG.extras = extras
end

function EHF.LoadEssentialCooldowns()
    -- Nothing is torn down until the new set is known non-empty.
    DetectExtras()

    local sortedSpellIDs = {}
    local sortedCooldownIDs = {}
    -- Never the raw provider: its accessors build lazily and a build on our
    -- stack is created tainted. See ns.OrderedCooldownIDs in Core.lua.
    do
        local displayedCooldownIDs = ns.OrderedCooldownIDs and ns.OrderedCooldownIDs(0)
        do
            if displayedCooldownIDs and #displayedCooldownIDs > 0 then
                for _, cdID in ipairs(displayedCooldownIDs) do
                    local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if infoOk and info and (info.spellID or info.spellCategoryID or info.equipSlot) then
                        -- false, not nil: the arrays are index-parallel and
                        -- table.insert(t, nil) would not advance the index.
                        table.insert(sortedSpellIDs, info.spellID or false)
                        table.insert(sortedCooldownIDs, cdID)
                    end
                end
            end
        end
    end

    if #sortedSpellIDs == 0 then
        if C_CooldownViewer and C_CooldownViewer.IsCooldownViewerAvailable
           and C_CooldownViewer.IsCooldownViewerAvailable() then
            local success, cooldownIDs = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, 0, false)
            if success and cooldownIDs then
                for _, cooldownID in ipairs(cooldownIDs) do
                    local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                    if infoOk and info and (info.spellID or info.spellCategoryID or info.equipSlot) then
                        table.insert(sortedSpellIDs, info.spellID or false)
                        table.insert(sortedCooldownIDs, cooldownID)
                    end
                end
            end
        end
    end
    
    if #sortedSpellIDs == 0 then
        if not shownSetupHint then
            shownSetupHint = true
            print("|cff00ff00[Infall]|r No abilities found in the Cooldown Manager.")
            print("|cff00ff00[Infall]|r   Type |cffffff00/infall setup|r to open the Cooldown Manager settings,")
            print("|cff00ff00[Infall]|r   add your abilities, then |cffffff00/infall reload|r or |cffffff00/reload|r")
        end
        return
    end
    
    -- Filter out hidden cooldowns.
    local hiddenSet = {}
    if CONFIG.hiddenCooldownIDs then
        for id, v in pairs(CONFIG.hiddenCooldownIDs) do
            if v then hiddenSet[id] = true end
        end
    end
    
    if next(hiddenSet) then
        local filteredSpellIDs = {}
        local filteredCooldownIDs = {}
        for i, cdID in ipairs(sortedCooldownIDs) do
            if not hiddenSet[cdID] then
                table.insert(filteredSpellIDs, sortedSpellIDs[i])
                table.insert(filteredCooldownIDs, cdID)
            end
        end
        sortedSpellIDs = filteredSpellIDs
        sortedCooldownIDs = filteredCooldownIDs
    end

    if ns.AutoPopulateSelfBuffMappings then ns.AutoPopulateSelfBuffMappings() end
    if ns.RepairSelfBuffPairingsAuto then ns.RepairSelfBuffPairingsAuto() end

    if #sortedSpellIDs == 0 then return end

    -- Committed. The new set is known good, so tearing down is now safe.
    CleanupActiveCast()
    activeCast = nil
    for _, bar in ipairs(cooldownBars) do bar:Hide() end
    wipe(cooldownBars)

    for i, rawSpellID in ipairs(sortedSpellIDs) do
        local spellID = rawSpellID or nil
        local bar = barPool[i]
        
        if bar then
            ResetBarState(bar)
            ConfigureBarForSpell(bar, spellID, sortedCooldownIDs[i], i)
        else
            bar = CreateCooldownBar(spellID, i)
            ConfigureBarForSpell(bar, spellID, sortedCooldownIDs[i], i)
            table.insert(barPool, bar)
        end
        
        bar:Show()
        table.insert(cooldownBars, bar)
    end
    
    -- Extras bars, always at bottom. On 12.1 the Cooldown Manager carries racials,
    -- potions and trinkets natively, so this path holds only custom rows there,
    if CONFIG.extras then
        for _, extra in ipairs(CONFIG.extras) do
            if extra.enabled then
                local nextIdx = #cooldownBars + 1
                local bar = barPool[nextIdx]
                if bar then
                    ResetBarState(bar)
                else
                    bar = CreateCooldownBar(extra.spellID or extra.iconSpellID, nextIdx)
                    table.insert(barPool, bar)
                end

                local isCustom = extra.type == "custom"
                local iconSourceID = isCustom and extra.iconSpellID or extra.spellID

                bar.spellID = isCustom and nil or extra.spellID
                bar.baseSpellID = isCustom and nil or extra.spellID
                bar.cooldownID = isCustom and extra.key or (extra.cooldownID or extra.spellID)
                bar.isExtras = true
                bar.extrasType = extra.type
                bar.extrasKey = extra.key
                bar.isChargeSpell = false
                bar.maxCharges = 1
                bar.hasCharges = false
                bar._isMultiVariant = false
                bar._buffCooldownIDs = nil

                local spellInfo = iconSourceID and C_Spell.GetSpellInfo(iconSourceID)
                if spellInfo then
                    bar.spellName = isCustom and (extra.label or "Custom Row") or spellInfo.name
                    local lookupID = bar.cooldownID
                    local customID = CONFIG.customIcons and CONFIG.customIcons[lookupID]
                    local customTex = customID and C_Spell.GetSpellTexture(customID)
                    -- For custom rows, prefer the stored picker texture so spec overrides cannot remap the icon.
                    local resolvedIcon = (isCustom and extra.iconTexture) or customTex or spellInfo.iconID
                    bar.icon:SetTexture(resolvedIcon)
                elseif isCustom then
                    bar.spellName = extra.label or "Custom Row"
                    bar.icon:SetTexture(extra.iconTexture or 134400)
                end
                bar.cdBar:SetStatusBarColor(unpack(GetCooldownColor(bar)))
                local buffColor = extra.buffColor or CONFIG.buffColor
                bar.buffBar:SetStatusBarColor(buffColor[1], buffColor[2], buffColor[3], buffColor[4] or 1)
                bar.resolvedBuffColor = buffColor
                bar.cdBar:SetHeight(bar.cdBar.fullHeight or CONFIG.height)

                if isCustom then
                    bar.cdBar:Hide()
                    bar.activeCooldown = nil
                end

                bar:Show()
                table.insert(cooldownBars, bar)
            end
        end
    end

    -- Reorder extras to top if configured
    if CONFIG.extrasPosition == "TOP" then
        local extras = {}
        local cdm = {}
        for _, bar in ipairs(cooldownBars) do
            if bar.isExtras then extras[#extras + 1] = bar
            else cdm[#cdm + 1] = bar end
        end
        wipe(cooldownBars)
        for _, bar in ipairs(extras) do cooldownBars[#cooldownBars + 1] = bar end
        for _, bar in ipairs(cdm) do cooldownBars[#cooldownBars + 1] = bar end
    end

    -- cdTextCooldown needs CLEARING, not hiding: it hangs off barTextOverlay,
    -- which is parented to EH_Parent, so hiding the row leaves it drawing.
    for i = #cooldownBars + 1, #barPool do
        local bar = barPool[i]
        bar.chargeText:Hide()
        bar.stackText:Hide()
        if bar.variantNameText then bar.variantNameText:Hide() end
        HandleProcGlow(bar, false)
        -- Cleared, not hidden: nothing ever re-shows barTextOverlay.
        if bar.cdTextCooldown then bar.cdTextCooldown:SetCooldown(0, 0) end
    end


    ApplyLayoutToAllBars()

    C_Timer.After(0.5, UpdateBars)
end

-- Rebuilds only when the count moved. A live row cannot have its maxCharges
-- changed in place.
local function RedetectChargesAndRebuild()
    local oldCache = {}
    if InfallDB.chargeSpells then
        for k, v in pairs(InfallDB.chargeSpells) do
            oldCache[k] = type(v) == "table" and v.maxCharges or v
        end
    end
    PreCacheChargeSpells()
    local changed = false
    if InfallDB.chargeSpells then
        for k, v in pairs(InfallDB.chargeSpells) do
            local newMax = type(v) == "table" and v.maxCharges or v
            if oldCache[k] ~= newMax then changed = true; break end
        end
        if not changed then
            for k in pairs(oldCache) do
                if not InfallDB.chargeSpells[k] then changed = true; break end
            end
        end
    end
    if changed then EHF.LoadEssentialCooldowns() end
    return changed
end

local function ProcessSpecChange()
    local myToken = specChangeToken
    local specKey = ns.GetSpecKey and ns.GetSpecKey()
    -- Never clears specChangePending on a no-op. That flag means "a spec change is in
    -- flight, suppress other rebuilds", and only the timer that armed it may end it.
    if not specKey then return end

    -- The key is the evidence, not the event. PLAYER_SPECIALIZATION_CHANGED carries a
    -- unitTarget and fires for other units too, so it is not proof our spec moved.
    if specKey == ns.currentSpecKey then return end

    ns.currentSpecKey = specKey
    if InfallDB.profiles[specKey] and ns.ApplyProfile then
        ns.ApplyProfile(InfallDB.profiles[specKey])
    elseif ns.SeedProfileFromClassConfig then
        local profile = ns.SeedProfileFromClassConfig(specKey)
        if profile and ns.ApplyProfile then
            ns.ApplyProfile(profile)
        end
    end

    local ok, err = pcall(function()
        PreCacheChargeSpells()
        EHF.LoadEssentialCooldowns()
    end)
    if not ok then
        print("|cffff0000[Infall] Error during spec change rebuild:|r", tostring(err))
    end

    specChangePending = false
    if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end

    C_Timer.After(0, function()
        if myToken ~= specChangeToken then return end
        SmartReorder()
    end)

    -- Safety net: re-detect charges after spell data settles, rebuild only if changed
    C_Timer.After(3, function()
        if myToken ~= specChangeToken then return end
        RedetectChargesAndRebuild()
    end)
end

local function UpdateVisibility()
    if CONFIG.redshift then
        EH_Parent:SetShown(InCombatLockdown() or UnitExists("target"))
    else
        EH_Parent:Show()
    end

    -- Called from here, not the same events: two frames taking one event have
    -- no defined order and the strip would read a stale state.
    if CONFIG.iconsEnabled and ns.Icons then ns.Icons.Layout() end
end

-- Events

EH_Parent:RegisterEvent("ADDON_LOADED")
EH_Parent:RegisterEvent("PLAYER_ENTERING_WORLD")
EH_Parent:RegisterEvent("SPELL_UPDATE_COOLDOWN")
EH_Parent:RegisterEvent("SPELL_UPDATE_CHARGES")
EH_Parent:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
EH_Parent:RegisterEvent("TRAIT_CONFIG_UPDATED")
EH_Parent:RegisterEvent("SPELLS_CHANGED")
EH_Parent:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
EH_Parent:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
-- Every snapped measurement here divides by the effective scale, so all of
-- it goes stale when the scale or resolution changes.
EH_Parent:RegisterEvent("UI_SCALE_CHANGED")
EH_Parent:RegisterEvent("DISPLAY_SIZE_CHANGED")

EH_Parent:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
EH_Parent:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
EH_Parent:RegisterEvent("SPELL_UPDATE_USABLE")
EH_Parent:RegisterEvent("CURRENT_SPELL_CAST_CHANGED")
EH_Parent:RegisterEvent("SPELL_RANGE_CHECK_UPDATE")
EH_Parent:RegisterEvent("PLAYER_TOTEM_UPDATE")

EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")

EH_Parent:RegisterUnitEvent("UNIT_AURA", "player", "target")

EH_Parent:RegisterEvent("PLAYER_REGEN_DISABLED")
EH_Parent:RegisterEvent("PLAYER_REGEN_ENABLED")
EH_Parent:RegisterEvent("PLAYER_TARGET_CHANGED")

-- ECM visibility (per-viewer)
local ecmFrameNames = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

local ecmViewerKey = {
    EssentialCooldownViewer = "hideEssentialCD",
    UtilityCooldownViewer   = "hideUtilityCD",
    BuffIconCooldownViewer  = "hideBuffIconCD",
    BuffBarCooldownViewer   = "hideBuffBarCD",
}

local function AnyViewerHidden()
    return CONFIG.hideEssentialCD or CONFIG.hideUtilityCD or CONFIG.hideBuffIconCD or CONFIG.hideBuffBarCD
end

local ecmVisQueued = false
local ecmVisPending = false

-- Defers out of Blizzard's own call stack: touching CDM frames inside their
-- hooks taints the rest of that secure execution.
local function QueueECMVisibility()
    if ecmVisQueued then return end
    ecmVisQueued = true
    C_Timer.After(0, function()
        ecmVisQueued = false
        if InCombatLockdown() then
            ecmVisPending = true
            return
        end
        if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end
    end)
end
ns.QueueECMVisibility = QueueECMVisibility

local function ApplyECMVisibility()
    if InCombatLockdown() then return end
    for _, name in ipairs(ecmFrameNames) do
        local frame = _G[name]
        if frame then
            local key = ecmViewerKey[name]
            if key and CONFIG[key] then
                pcall(function() frame:SetAlpha(0) end)
                -- Disable mouse on main frame and all item frames
                pcall(function() frame:EnableMouse(false) end)
                pcall(function()
                    for itemFrame in frame.itemFramePool:EnumerateActive() do
                        itemFrame:SetMouseMotionEnabled(false)
                        itemFrame:SetMouseClickEnabled(false)
                    end
                end)
            else
                pcall(function() frame:UpdateSystemSettingOpacity() end)
                pcall(function() frame:EnableMouse(true) end)
                pcall(function()
                    for itemFrame in frame.itemFramePool:EnumerateActive() do
                        itemFrame:SetMouseMotionEnabled(true)
                        itemFrame:SetMouseClickEnabled(true)
                    end
                end)
            end
        end
    end
end
ns.ApplyECMVisibility = ApplyECMVisibility

local function ForceViewersAlways()
    -- Claim the single allowed save on the login pass, even if it returns
    -- early, so every later caller is a runtime caller by definition.
    local isFirstCall = not ns._editModeSeen
    ns._editModeSeen = true

    -- Fast path: check if VisibleSetting already correct via frame properties (read-only)
    local allCorrect = true
    for _, name in ipairs(ecmFrameNames) do
        local viewer = _G[name]
        if viewer then
            if viewer.visibleSetting == nil or viewer.visibleSetting ~= 0 then
                allCorrect = false
                break
            end
        end
    end
    if allCorrect then return false end

    -- Settings need fixing: modify saved layout data via C_EditMode (no frame interaction)
    if not C_EditMode or not C_EditMode.GetLayouts or not C_EditMode.SaveLayouts then
        return false
    end

    local ok, layoutInfo = pcall(C_EditMode.GetLayouts)
    if not ok or type(layoutInfo) ~= "table" then return false end

    local layouts = layoutInfo.layouts
    local activeIdx = layoutInfo.activeLayout
    if type(layouts) ~= "table" or type(activeIdx) ~= "number" then return false end

    -- Prepend preset layouts
    if EditModePresetLayoutManager and EditModePresetLayoutManager.GetCopyOfPresetLayouts then
        local presetOk, presets = pcall(EditModePresetLayoutManager.GetCopyOfPresetLayouts, EditModePresetLayoutManager)
        if presetOk and type(presets) == "table" then
            tAppendAll(presets, layouts)
            layoutInfo.layouts = presets
        end
    end

    local activeLayout = layoutInfo.layouts[activeIdx]
    if not activeLayout or type(activeLayout.systems) ~= "table" then return false end

    local isPreset = activeLayout.layoutType == (Enum.EditModeLayoutType and Enum.EditModeLayoutType.Preset)
    local CDM_SYSTEM = Enum.EditModeSystem and Enum.EditModeSystem.CooldownViewer
    if not CDM_SYSTEM then return false end

    -- Prefer Enum.* when present (Forever confirms VisibleSetting=6, Always=0);
    -- keep numeric fallbacks for older dumps / missing enum tables.
    local VIS_SETTING = (Enum.EditModeCooldownViewerSetting and Enum.EditModeCooldownViewerSetting.VisibleSetting) or 6
    local VIS_ALWAYS = (Enum.CooldownViewerVisibleSetting and Enum.CooldownViewerVisibleSetting.Always) or 0

    local changed = false
    for _, systemInfo in ipairs(activeLayout.systems) do
        if systemInfo.system == CDM_SYSTEM and type(systemInfo.settings) == "table" then
            local foundVis = false
            for _, s in ipairs(systemInfo.settings) do
                if s.setting == VIS_SETTING then
                    foundVis = true
                    if s.value ~= VIS_ALWAYS then
                        s.value = VIS_ALWAYS
                        changed = true
                    end
                end
            end
            if not foundVis then
                systemInfo.settings[#systemInfo.settings + 1] = { setting = VIS_SETTING, value = VIS_ALWAYS }
                changed = true
            end
        end
    end

    if not changed then return false end

    if isPreset and not ns._presetWarningShown then
        ns._presetWarningShown = true
        print("|cff00ff00[Infall]|r CDM viewers need to be set to Always. Open Edit Mode and change each viewer's visibility, or create a custom layout.")
    end

    -- SaveLayouts AT MOST ONCE, during init, NEVER at runtime: a runtime call
    -- reapplies the layout from addon code and taints isActive, read on every
    -- viewer child. Runtime callers get it in memory, written next login.
    if ns._editModeSaved or not isFirstCall then
        return true
    end
    ns._editModeSaved = true
    pcall(C_EditMode.SaveLayouts, layoutInfo)
    return true
end

local function GetCDMStatus()
    local cvarEnabled = C_CVar and C_CVar.GetCVarBool("cooldownViewerEnabled")
    local allAlways = true
    for _, name in ipairs(ecmFrameNames) do
        local viewer = _G[name]
        if viewer then
            if viewer.visibleSetting == nil or viewer.visibleSetting ~= 0 then
                allAlways = false
            end
        end
    end
    return cvarEnabled, allAlways
end
ns.GetCDMStatus = GetCDMStatus
ns.ForceViewersAlways = ForceViewersAlways

local function ApplyCastBarVisibility()
    if InCombatLockdown() then return end
    local bar = PlayerCastingBarFrame
    if not bar then return end
    if CONFIG.hideBlizzCastBar then
        bar:SetAlpha(0)
        pcall(function() bar:UnregisterAllEvents() end)
    else
        bar:SetAlpha(1)
        pcall(function()
            -- Blizzard's own list for this frame, unit filtered the way they register it.
            -- SUCCEEDED is not on it; the two interruptible events are.
            local unit = bar.unit or "player"
            for _, e in ipairs({
                "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
                "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
                "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
                "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP",
                "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_EMPOWER_START",
                "UNIT_SPELLCAST_EMPOWER_STOP", "UNIT_SPELLCAST_EMPOWER_UPDATE",
            }) do
                bar:RegisterUnitEvent(e, unit)
            end
            bar:RegisterEvent("PLAYER_ENTERING_WORLD")
        end)
    end
end
ns.ApplyCastBarVisibility = ApplyCastBarVisibility

local loginInitFrame = CreateFrame("Frame")
loginInitFrame:RegisterEvent("PLAYER_LOGIN")
loginInitFrame:SetScript("OnEvent", function()

    -- CDM is required; auto-enable if available but toggled off
    local cdmAvailable = C_CooldownViewer and C_CooldownViewer.IsCooldownViewerAvailable and C_CooldownViewer.IsCooldownViewerAvailable()
    if cdmAvailable and not C_CVar.GetCVarBool("cooldownViewerEnabled") then
        SetCVar("cooldownViewerEnabled", true)
        print("|cff00ff00[Infall]|r Enabled the Cooldown Manager. Infall requires it to function.")
    end

    -- Migrate old hideBlizzECM boolean → per-viewer keys
    if CONFIG.hideBlizzECM ~= nil then
        local v = CONFIG.hideBlizzECM and true or false
        if CONFIG.hideEssentialCD == nil then CONFIG.hideEssentialCD = v end
        if CONFIG.hideUtilityCD == nil then CONFIG.hideUtilityCD = v end
        if CONFIG.hideBuffIconCD == nil then CONFIG.hideBuffIconCD = v end
        if CONFIG.hideBuffBarCD == nil then CONFIG.hideBuffBarCD = v end
        CONFIG.hideBlizzECM = nil
    end

    -- Correct the CDM viewer settings to "Always" in layout data
    if CONFIG.forceViewersAlways ~= false then ForceViewersAlways() end

    PreCacheChargeSpells()
    if ns.AutoPopulateSelfBuffMappings then ns.AutoPopulateSelfBuffMappings() end

    local function NormalizeGrowAnchor()
        if not EH_Parent then return end
        local left = EH_Parent:GetLeft()
        local bottom = EH_Parent:GetBottom()
        local top = EH_Parent:GetTop()
        if not left or not bottom or not top then return end

        -- GetLeft/GetTop/GetBottom return in frame-scaled space
        local s = EH_Parent:GetScale() or 1
        left = left * s
        bottom = bottom * s
        top = top * s

        local halfW = UIParent:GetWidth() / 2
        local halfH = UIParent:GetHeight() / 2
        local xOff = (left - halfW) / s
        local yOff

        if CONFIG.growDirection == "UP" then
            yOff = (bottom - halfH) / s
            EH_Parent:ClearAllPoints()
            EH_Parent:SetPoint("BOTTOMLEFT", UIParent, "CENTER", xOff, yOff)
            InfallDB.position = { point = "BOTTOMLEFT", relPoint = "CENTER", x = xOff, y = yOff }
        else
            yOff = (top - halfH) / s
            EH_Parent:ClearAllPoints()
            EH_Parent:SetPoint("TOPLEFT", UIParent, "CENTER", xOff, yOff)
            InfallDB.position = { point = "TOPLEFT", relPoint = "CENTER", x = xOff, y = yOff }
        end
    end
    ns.NormalizeGrowAnchor = NormalizeGrowAnchor

    EH_Parent:SetMovable(true)
    EH_Parent:EnableMouse(true)
    EH_Parent:RegisterForDrag("LeftButton")
    EH_Parent:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or CONFIG.locked then return end
        self:StartMoving()
    end)
    EH_Parent:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        NormalizeGrowAnchor()
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
    end)

    if InfallDB.position then
        local pos = InfallDB.position
        EH_Parent:ClearAllPoints()
        EH_Parent:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end

    for _, name in ipairs(ecmFrameNames) do
        local frame = _G[name]
        if frame then
            local key = ecmViewerKey[name]
            -- Queue only. Writing to a CDM frame inside its own hook taints
            -- the rest of that secure execution.
            hooksecurefunc(frame, "SetAlpha", function(self, alpha)
                if issecretvalue(alpha) then return end
                if key and CONFIG[key] and alpha > 0 then
                    QueueECMVisibility()
                end
            end)
            -- Re-disable mouse after CDM layout rebuilds (login, spec swap, zone transition)
            if frame.RefreshLayout then
                hooksecurefunc(frame, "RefreshLayout", function(self)
                    if key and CONFIG[key] then QueueECMVisibility() end
                end)
            end
        end
    end

    -- Mixin hooks: maintain persistent CDM frame maps reactively
    if CooldownViewerItemDataMixin then
        if CooldownViewerItemDataMixin.SetCooldownID then
            hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(frame, cdID)
                if not cdID then return end
                local oldCdID = cdmFrameToCdID[frame]
                if oldCdID then
                    if persistentCooldownMap[oldCdID] == frame then persistentCooldownMap[oldCdID] = nil end
                    if persistentBuffMap[oldCdID] == frame then
                        persistentBuffMap[oldCdID] = nil
                        persistentBuffFallback[oldCdID] = nil
                        buffPromoteNext[oldCdID] = nil
                    end
                end
                cdmFrameToCdID[frame] = cdID

                local viewer = frame.viewerFrame
                if not viewer then return end
                local isBuff = (viewer == _G["BuffIconCooldownViewer"] or viewer == _G["BuffBarCooldownViewer"])
                local isCooldown = (viewer == _G["EssentialCooldownViewer"] or viewer == _G["UtilityCooldownViewer"])

                if isCooldown then
                    persistentCooldownMap[cdID] = frame
                    if not persistentBuffMap[cdID] then
                        persistentBuffMap[cdID] = frame
                        persistentBuffFallback[cdID] = true
                    end
                end
                if isBuff then
                    persistentBuffMap[cdID] = frame
                    persistentBuffFallback[cdID] = nil
                    buffPromoteNext[cdID] = nil
                end
                EHF.InstallBuffFrameHooks(frame)
                MarkBuffDirtyForCdID(cdID)
                viewerScanDirty = true

                -- Disable mouse on item frames assigned to hidden viewers
                local viewerName = viewer:GetName()
                if viewerName then
                    local hideKey = ecmViewerKey[viewerName]
                    if hideKey and CONFIG[hideKey] then QueueECMVisibility() end
                end
            end)
        end
        if CooldownViewerItemDataMixin.ClearCooldownID then
            hooksecurefunc(CooldownViewerItemDataMixin, "ClearCooldownID", function(frame)
                local cdID = cdmFrameToCdID[frame]
                if cdID then
                    if persistentCooldownMap[cdID] == frame then persistentCooldownMap[cdID] = nil end
                    if persistentBuffMap[cdID] == frame then
                        persistentBuffMap[cdID] = nil
                        persistentBuffFallback[cdID] = nil
                        buffPromoteNext[cdID] = nil
                    end
                    cdmFrameToCdID[frame] = nil
                    MarkBuffDirtyForCdID(cdID)
                    viewerScanDirty = true
                end
            end)
        end
    end

    EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
        viewerScanDirty = true
        if InCombatLockdown() then return end
        C_Timer.After(0, function()
            if InCombatLockdown() then return end
            if #cooldownBars > 0 then
                SmartReorder()
            else
                EHF.LoadEssentialCooldowns()
            end
        end)

        -- Second pass in case the data provider hasn't committed the new order yet
        C_Timer.After(1.0, function()
            if InCombatLockdown() then return end
            if #cooldownBars > 0 then
                SmartReorder()
            else
                EHF.LoadEssentialCooldowns()
            end
        end)
    end, EH_Parent)

    local specKey = ns.GetSpecKey and ns.GetSpecKey()
    -- Unresolved here is NORMAL and SPELLS_CHANGED fixes it, so the warning waits.
    -- Only a spec still unreadable after that is worth telling anyone about.
    if not specKey then
        C_Timer.After(10, function()
            if ns.currentSpecKey then return end
            print("|cffff0000[Infall]|r Could not read your specialization, so no profile "
                .. "loaded and the bars will stay empty. Please report this.")
        end)
    end
    if specKey then
        ns.currentSpecKey = specKey
        if InfallDB.profiles[specKey] then
            if ns.ApplyProfile then
                ns.ApplyProfile(InfallDB.profiles[specKey])
            end
        else
            -- first time for this spec
            if ns.SeedProfileFromClassConfig then
                local profile = ns.SeedProfileFromClassConfig(specKey)
                if profile and ns.ApplyProfile then
                    ns.ApplyProfile(profile)
                end
            end
        end
        if InfallDB.pendingMigration then
            local profile = InfallDB.profiles[specKey]
            if profile and profile.toggles then
                for k, v in pairs(InfallDB.pendingMigration) do
                    profile.toggles[k] = v
                end
            end
            InfallDB.pendingMigration = nil
        end
    end

    -- must be after profile loading sets CONFIG
    NormalizeGrowAnchor()
    ApplyCastBarVisibility()
    if CONFIG.clickthrough then
        EH_Parent:EnableMouse(false)
        CONFIG.locked = true
    end

    -- Register settings panel in the ESC menu at load time
    if ns.InitSettings then ns.InitSettings() end

    if ns.RefreshIcons then ns.RefreshIcons() end
end)

local lastUnitAuraUpdate = 0
local UNIT_AURA_THROTTLE = 0.1

EH_Parent:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == ADDON_NAME then
            -- Migrate old flat InfallDB to profile structure
            if InfallDB and not InfallDB.profiles then
                local oldToggles = {}
                for _, key in ipairs({"reactiveIcons", "desaturateOnCooldown", "redshift",
                    "pandemicPulse", "locked", "hideBlizzCastBar", "hideBlizzECM",
                    "buffLayerAbove", "hideIcons", "clickthrough"}) do
                    if InfallDB[key] ~= nil then
                        oldToggles[key] = InfallDB[key]
                        InfallDB[key] = nil
                    end
                end
                -- Migrate autohide -> redshift
                if InfallDB.autohide ~= nil then
                    oldToggles.redshift = InfallDB.autohide
                    InfallDB.autohide = nil
                end
                -- Preserve global fields
                local pos = InfallDB.position
                local cs = InfallDB.chargeSpells
                local cd = InfallDB.chargeDurations
                local hidden = InfallDB.hiddenCooldownIDs

                InfallDB = {
                    profiles = {},
                    position = pos,
                    chargeSpells = cs or {},
                    chargeDurations = cd or {},
                    hiddenCooldownIDs = hidden or {},
                    pendingMigration = oldToggles,
                }
            end
            InfallDB.profiles = InfallDB.profiles or {}
            InfallDB.namedProfiles = InfallDB.namedProfiles or {}
            InfallDB.chargeSpells = InfallDB.chargeSpells or {}
            InfallDB.chargeDurations = InfallDB.chargeDurations or {}
            AC.LoadDB()

            -- Drop recorded charge bases: a reading taken during a loading screen
            -- or a different talent build can pin a spell below its real count.
            InfallDB.chargeObserved = nil

            if not InfallDB.seenWelcome then
                InfallDB.seenWelcome = true
                print("|cff00ff00[Infall]|r Loaded. Type |cffffff00/infall setup|r for settings or |cffffff00/infall|r for commands.")
            end
        end
        
    elseif event == "UNIT_SPELLCAST_SENT" then
        -- The spell just went out, so the newest press is the one that won.
        if ns.PressMarks_MarkWinner then ns.PressMarks_MarkWinner() end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if ns.PressMarks_Reset then ns.PressMarks_Reset() end
        ns._pmLastPress, ns._pmSeamUntil, ns._pmMissed = nil, nil, nil
        local isInitialLogin, isReloadingUi = ...
        viewerScanDirty = true
        -- Recovers a spec key PLAYER_LOGIN could not read. Deferred: it runs
        -- PreCacheChargeSpells, which persists a charge count.
        C_Timer.After(2, function() pcall(ProcessSpecChange) end)
        C_Timer.After(2, function()
            viewerScanDirty = true
            if #cooldownBars == 0 then EHF.LoadEssentialCooldowns() end
        end)
        -- 12.1 tracked buff notice, once the CDM has repopulated.
        if isInitialLogin or isReloadingUi then
            C_Timer.After(5, function()
                if ns.Migrate121 then ns.Migrate121.CheckOnLogin() end
            end)
        end
        C_Timer.After(2.5, UpdateVisibility)
        -- Viewers may recreate after zone transitions; re-force Always + re-hide
        C_Timer.After(2.5, function()
            if InCombatLockdown() then
                ns._pendingECMReapply = true
                return
            end
            if CONFIG.forceViewersAlways ~= false then ForceViewersAlways() end
            ApplyECMVisibility()
        end)

    elseif event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" then
        -- If bars haven't been loaded yet (first GCD before 2s timer), load now
        if #cooldownBars == 0 then
            EHF.LoadEssentialCooldowns()
            -- Recover any cast already in progress (UNIT_SPELLCAST_START fired before bars existed)
            if #cooldownBars > 0 and not activeCast then
                UpdateCastBar(event)
            end
        end

        local gcdSuccess, gcdObj = pcall(C_Spell.GetSpellCooldownDuration, 61304)
        if gcdSuccess and gcdObj and gcdObj.GetRemainingDuration then
            cachedGcdDurObj = gcdObj
            if gcdObj ~= lastFedGcdDurObj then
                gcdActive = true
                lastFedGcdDurObj = gcdObj
                pcall(hiddenGcdCooldown.SetCooldownFromDurationObject, hiddenGcdCooldown, gcdObj, true)
            end
        end


        UpdateBars()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...

        if ns.NoteRuneCast then ns.NoteRuneCast(spellID) end

        for _, row in ipairs(cooldownBars) do
            local isMatch = (row.spellID == spellID or row.baseSpellID == spellID)
            if not isMatch then
                local ok, overrideID = pcall(C_Spell.GetOverrideSpell, row.baseSpellID)
                if ok and overrideID and overrideID == spellID then
                    isMatch = true
                end
            end
            if not isMatch and CONFIG.extraCasts then
                local extras = CONFIG.extraCasts[row.cooldownID] or CONFIG.extraCasts[row.baseSpellID] or CONFIG.extraCasts[row.spellID]
                if extras then
                    for _, extraID in ipairs(extras) do
                        if extraID == spellID then isMatch = true; break end
                    end
                end
            end

            if isMatch then
                if row.isChargeSpell then
                    UpdateBars()
                    ScheduleDeferredUpdate(0)
                end
                break
            end
        end


        -- Custom timers and tick marks are armed by the row's own cast.
        for _, row in ipairs(cooldownBars) do
            if row.cooldownID and RowMatchesCastSpell(row, spellID) then
                row._tickCastAt = GetTime()
                local m = CONFIG.buffMappings and CONFIG.buffMappings[row.cooldownID]
                if m then
                    local now = GetTime()
                    for mapIdx, mapData in ipairs(m) do
                        if mapIdx <= 3 and mapData.customDuration then
                            row._customTimerStart = row._customTimerStart or {}
                            row._customTimerStart[mapIdx] = now
                            -- In combat only dirty rows update, and nothing else
                            -- dirties a row whose buff the game does not track.
                            row._buffDirty = true
                            ScheduleDeferredUpdate(mapData.customDuration)
                        end
                    end
                end
            end
        end

        -- Combat potion. Only a fresh cast arms the window, so a reload mid-buff
        -- shows nothing until the next use.
        local potionWindow = (not issecretvalue(spellID)) and K.POTION_BUFF_DURATIONS[spellID]
        if potionWindow then
            for _, row in ipairs(cooldownBars) do
                if not row.isExtras and row.cooldownID
                    and CombatPotionRowInfo(row.cooldownID) then
                    EHF.ArmPotionWindow(row, potionWindow)
                end
            end
        end

    elseif event == "TRAIT_CONFIG_UPDATED" then
        -- A talent can change max charges, and a live row cannot change lane count
        -- in place. Let the API settle before re-reading.
        if not specChangePending then
            local myToken = specChangeToken
            C_Timer.After(2, function()
                if myToken ~= specChangeToken or specChangePending then return end
                if InCombatLockdown() then return end
                RedetectChargesAndRebuild()
                -- Re-evaluates which configs still resolve to a real ability.
                if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
            end)
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        specChangeToken = specChangeToken + 1
        specChangePending = true
        -- Re-disable mouse on hidden viewers while CDM rebuilds
        if AnyViewerHidden() and ns.ApplyECMVisibility then
            ns.ApplyECMVisibility()
            C_Timer.After(0.5, function() if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end end)
            C_Timer.After(1.0, function() if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end end)
            C_Timer.After(1.5, function() if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end end)
        end
        local myToken = specChangeToken
        -- The timer that armed the flag is the only thing that ends it, whatever the
        -- outcome. ProcessSpecChange gates itself on the key, so calling it is cheap.
        C_Timer.After(2, function()
            if myToken ~= specChangeToken then return end
            -- pcall'd: a throw would leave specChangePending set for the session.
            pcall(ProcessSpecChange)
            specChangePending = false
        end)

    elseif event == "SPELLS_CHANGED" then
        -- Checked every time; ProcessSpecChange gates itself on the key.
        ProcessSpecChange()

    elseif event == "COOLDOWN_VIEWER_DATA_LOADED" then
        if specChangePending then return end
        -- Deferred out of combat, like the other two reorder paths. Rows moving
        -- under the player mid-pull is worse than an order that settles late.
        if InCombatLockdown() then
            ns._pendingReorder = true
            return
        end
        if #cooldownBars > 0 then
            C_Timer.After(0, function()
                -- The category set moved, so a pairing may now point at the wrong entry.
                if ns.RepairSelfBuffPairingsAuto then ns.RepairSelfBuffPairingsAuto() end
                SmartReorder()
            end)
        else
            C_Timer.After(0, EHF.LoadEssentialCooldowns)
        end
        
    elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        -- Deferred: the new scale is not readable from inside the event.
        C_Timer.After(0, function()
            if InCombatLockdown() then return end
            ApplyLayoutToAllBars()
        end)

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        local spellID = ...
        for _, row in ipairs(cooldownBars) do
            if RowMatchesCastSpell(row, spellID) then
                HandleProcGlow(row, true)
            end
        end
        UpdateBars()
        ScheduleDeferredUpdate(0)

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local spellID = ...
        for _, row in ipairs(cooldownBars) do
            if RowMatchesCastSpell(row, spellID) then
                HandleProcGlow(row, false)
            end
        end
        
    elseif event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
        -- An override can change at runtime, notably on a zone transition. Re-resolve
        -- display only; timing is re-read every pass anyway.
        local baseSpellID, overrideSpellID = ...
        if baseSpellID and not issecretvalue(baseSpellID) then
            for _, row in ipairs(cooldownBars) do
                if row.baseSpellID == baseSpellID then
                    if overrideSpellID and not issecretvalue(overrideSpellID)
                        and overrideSpellID ~= 0 then
                        row.spellID = overrideSpellID
                    else
                        row.spellID = baseSpellID
                    end
                    ApplyRowDisplay(row, row.cooldownID)
                end
            end
        end

    elseif event == "SPELL_UPDATE_USABLE" then
        UpdateAllIconStates()

    elseif event == "CURRENT_SPELL_CAST_CHANGED" then
        -- The queued spell changed, which is the only thing that moves the tint.
        UpdateAllIconStates()
        
    elseif event == "SPELL_RANGE_CHECK_UPDATE" then
        local spellID = ...
        for _, row in ipairs(cooldownBars) do
            if RowMatchesCastSpell(row, spellID) then
                UpdateIconState(row)
            end
        end

    elseif event == "PLAYER_TOTEM_UPDATE" then
        for _, row in ipairs(cooldownBars) do
            row._totemCooldownFed = false
            row._overlayTotemFed = false
            row._thirdTotemFed = false
        end
        UpdateBars()

    elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
           or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" or event == "UNIT_SPELLCAST_DELAYED"
           or event == "UNIT_SPELLCAST_EMPOWER_START" or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        if #cooldownBars == 0 then
            EHF.LoadEssentialCooldowns()
        end
        UpdateCastBar(event)
        
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or
           event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
           or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        local _, castGUID, spellID = ...

        -- The spark tracks casts with no row, so it cannot ride on activeCast's
        -- guards. A stop is a stop; the interrupted cast is not finishing.
        if sparkCast and (not spellID or spellID == sparkCast.spellID) then
            sparkCast = nil
            EHF.HideCastSpark()
        end

        -- A cast GUID identifies one cast; a spell id does not. Only when both are
        -- present, so a missing id still reaches the guards below.
        if activeCast and castGUID and activeCast.castID and castGUID ~= activeCast.castID then
            return
        end
        if activeCast and activeCast.row then
            -- Type guard: cast stops only affect casts, channel stops only affect channels.
            local isCastStop = (event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED")
            local isChannelStop = (event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP")
            
            local typeMatch = true
            if activeCast.isChannel and isCastStop then
                typeMatch = false
            elseif not activeCast.isChannel and isChannelStop then
                typeMatch = false
            end
            
            if typeMatch and (not spellID or spellID == activeCast.spellID) then
                -- Detach the cast's past slide (successful or not)
                if activeCast.pastSlide then
                    if event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
                        EHF.DetachPastSlide(activeCast.pastSlide)
                    else
                        -- Failed/interrupted: just kill the slide immediately
                        activeCast.pastSlide.tex:Hide()
                        activeCast.pastSlide.active = false
                    end
                end
                HideCastOverlays(activeCast.row)
                activeCast = nil
            end
        end

    elseif event == "UNIT_AURA" then
        local unit, updateInfo = ...

        -- Aura removal is handled by the ClearAuraInstanceInfo hook. Do not read
        -- removedAuraInstanceIDs here: the ids can be secret and comparing one throws.

        local now = GetTime()
        if now - lastUnitAuraUpdate >= UNIT_AURA_THROTTLE then
            lastUnitAuraUpdate = now
            UpdateBars()
            ScheduleDeferredUpdate(0)
            if unit == "target" then
                ScheduleDeferredUpdate(0.05)
                ScheduleDeferredUpdate(0.1)
            end
        end
        
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateVisibility()
        
        if event == "PLAYER_REGEN_ENABLED" then
            if ecmVisPending then
                ecmVisPending = false
                QueueECMVisibility()
            end
            viewerScanDirty = true
            for _, row in ipairs(cooldownBars) do
                row.cachedPandemicIcon = nil
                -- Detach active slides so they drift off naturally
                for _, key in ipairs(K.SLIDE_KEYS) do
                    if row[key] then EHF.DetachPastSlide(row[key]) end
                    row[key] = nil
                end
                row._depletedSpawnTime = nil
                row._chargeSpawnTime = nil
                if row.middleLanes then
                    for _, ml in ipairs(row.middleLanes) do
                        if ml.activeSlide then EHF.DetachPastSlide(ml.activeSlide) end
                        ml.activeSlide = nil
                    end
                end
                for _, key in ipairs(K.PTR_KEYS) do
                    row[key] = nil
                end
                for _, key in ipairs(K.HIDDEN_KEYS) do
                    if row[key] then row[key]:SetCooldown(0, 0) end
                end

                -- readable out of combat
                if row.isChargeSpell then
                    local cInfo = GetChargesWithOverride(row.spellID, row.baseSpellID)
                    if cInfo and cInfo.currentCharges then
                        if not issecretvalue(cInfo.maxCharges) then
                            local override = CONFIG.chargeOverflow and CONFIG.chargeOverflow[row.baseSpellID]
                            local effectiveMax = cInfo.maxCharges
                            if override and override.trueMax and effectiveMax > override.trueMax then
                                effectiveMax = override.trueMax
                            end
                            row.maxCharges = effectiveMax
                            local bH = row.cdBar.fullHeight or CONFIG.height
                            SetChargeLaneMetrics(row, bH, effectiveMax)
                        end
                    end
                    EHF.FeedChargeBarTimers(row)
                end


            end

            if ns._pendingReorder then
                ns._pendingReorder = nil
                if #cooldownBars > 0 then
                    C_Timer.After(0, function()
                        if ns.RepairSelfBuffPairingsAuto then ns.RepairSelfBuffPairingsAuto() end
                        SmartReorder()
                    end)
                else
                    C_Timer.After(0, EHF.LoadEssentialCooldowns)
                end
            end

            -- Re-apply ECM visibility after combat
            if ns._pendingECMReapply then
                ns._pendingECMReapply = nil
                if CONFIG.forceViewersAlways ~= false then ForceViewersAlways() end
            end
            if AnyViewerHidden() then
                ApplyECMVisibility()
            end
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Clear pandemic icon refs so OnUpdate doesn't poll stale target frames
        for _, row in ipairs(cooldownBars) do
            row.cachedPandemicIcon = nil
        end
        lastUnitAuraUpdate = 0
        UpdateBars()
        UpdateVisibility()
        -- Deferred(0) = next frame, guarantees CDM has processed UNIT_TARGET by then
        ScheduleDeferredUpdate(0)
        ScheduleDeferredUpdate(0.05)
        ScheduleDeferredUpdate(0.1)
        ScheduleDeferredUpdate(0.2)

    end
end)

-- Slash commands

SLASH_INFALLSETUP1 = "/ehz"
SlashCmdList["INFALLSETUP"] = function()
    if InCombatLockdown() then
        print("|cff00ff00[Infall]|r Cannot open settings in combat.")
        return
    end
    if ns.OpenSettings then
        ns.OpenSettings()
    else
        print("|cff00ff00[Infall]|r Settings not loaded yet.")
    end
end

SLASH_INFALL1 = "/infall"
SlashCmdList["INFALL"] = function(msg)
    msg = msg:lower():trim()

    if msg == "runecd" then
        if not CONFIG.runeBaseCooldowns then
            print("|cff00ff00[Infall]|r No rune abilities on this class.")
            return
        end
        CONFIG.estimateRuneCooldowns = not CONFIG.estimateRuneCooldowns
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        if CONFIG.estimateRuneCooldowns then
            print("|cff00ff00[Infall]|r Estimated rune cooldowns: |cff00ff00ON|r")
            print("|cff00ff00[Infall]|r Bars show the ability's own cooldown. Rune waits are not drawn.")
            print("|cff00ff00[Infall]|r Estimated: a cooldown reduction proc makes a bar run long.")
        else
            print("|cff00ff00[Infall]|r Estimated rune cooldowns: |cffff0000OFF|r (Blizzard behaviour)")
        end
        EHF.LoadEssentialCooldowns()

    elseif msg == "perf" then
        if ns.Perf then ns.Perf.Report() end

    elseif msg == "perf on" then
        if ns.Perf then ns.Perf.SetEnabled(true) end

    elseif msg == "perf off" then
        if ns.Perf then ns.Perf.SetEnabled(false) end

    elseif msg == "perf reset" then
        if ns.Perf then ns.Perf.Reset() print("|cff00ff00[Infall]|r Section totals cleared.") end

    elseif msg == "reload" or msg == "r" then
        EHF.LoadEssentialCooldowns()
        print("|cff00ff00[Infall]|r Cooldowns reloaded")


    elseif msg == "reactive" then
        CONFIG.reactiveIcons = not CONFIG.reactiveIcons
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.reactiveIcons then
            print("|cff00ff00[Infall]|r Reactive icons: |cff00ff00ENABLED|r (icons change colour)")
        else
            print("|cff00ff00[Infall]|r Reactive icons: |cffff0000DISABLED|r (icons stay coloured)")
            for _, row in ipairs(cooldownBars) do
                if row.cooldownFrame then row.cooldownFrame:Hide() end
                if row.innerGlowAnim then row.innerGlowAnim:Stop() end
                if row.glowAnim then row.glowAnim:Stop() end
                if row.iconGlow then row.iconGlow:Hide() end
                if row.innerGlow then row.innerGlow:SetAlpha(0) end
                if row.iconBorder then row.iconBorder:SetColorTexture(0, 0, 0, 1) end
                row.lastCdDurObj = nil
                row.lastChargeDurObj = nil
            end
        end
        UpdateAllIconStates()
        
    elseif msg == "desat" or msg == "desaturate" then
        CONFIG.desaturateOnCooldown = not CONFIG.desaturateOnCooldown
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.desaturateOnCooldown then
            print("|cff00ff00[Infall]|r Cooldown desaturation: |cff00ff00ENABLED|r (icons grey out on cooldown)")
        else
            print("|cff00ff00[Infall]|r Cooldown desaturation: |cffff0000DISABLED|r (icons stay coloured on cooldown)")
        end
        if not CONFIG.desaturateOnCooldown then
            for _, row in ipairs(cooldownBars) do
                row.icon:SetDesaturation(0)
            end
        end
        UpdateBars()
        
    elseif msg == "redshift" or msg == "rs" then
        CONFIG.redshift = not CONFIG.redshift
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.redshift then
            print("|cff00ff00[Infall]|r Redshift: |cff00ff00ENABLED|r (hides when out of combat with no target)")
        else
            print("|cff00ff00[Infall]|r Redshift: |cffff0000DISABLED|r (always visible)")
        end
        UpdateVisibility()
        
    elseif msg == "pandemic" or msg == "pan" then
        CONFIG.pandemicPulse = not CONFIG.pandemicPulse
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.pandemicPulse then
            print("|cff00ff00[Infall]|r Pandemic pulse: |cff00ff00ENABLED|r (target debuffs pulse in refresh window)")
        else
            print("|cff00ff00[Infall]|r Pandemic pulse: |cffff0000DISABLED|r (no pandemic indicator)")
            for _, row in ipairs(cooldownBars) do
                if row.buffPandemicAnim and row.buffPandemicAnim:IsPlaying() then
                    row.buffPandemicAnim:Stop()
                    row.buffBar:SetAlpha(1.0)
                end
            end
        end
        
    elseif msg == "castbar" or msg == "cast" then
        if InCombatLockdown() then
            print("|cffff0000[Infall]|r Cannot toggle cast bar during combat.")
            return
        end

        CONFIG.hideBlizzCastBar = not CONFIG.hideBlizzCastBar
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        ApplyCastBarVisibility()

        if CONFIG.hideBlizzCastBar then
            print("|cff00ff00[Infall]|r Blizzard cast bar: |cffff0000HIDDEN|r")
        else
            print("|cff00ff00[Infall]|r Blizzard cast bar: |cff00ff00VISIBLE|r")
        end
        
    elseif msg == "ecm" then
        if InCombatLockdown() then
            print("|cff00ff00[Infall]|r Cannot toggle cooldown viewer in combat. Use /infall ecm after combat.")
            return
        end
        local allHidden = CONFIG.hideEssentialCD and CONFIG.hideUtilityCD and CONFIG.hideBuffIconCD and CONFIG.hideBuffBarCD
        local newVal = not allHidden
        CONFIG.hideEssentialCD = newVal
        CONFIG.hideUtilityCD = newVal
        CONFIG.hideBuffIconCD = newVal
        CONFIG.hideBuffBarCD = newVal
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end

        if ns.ApplyECMVisibility then
            ns.ApplyECMVisibility()
        end

        if newVal then
            print("|cff00ff00[Infall]|r Blizzard cooldown viewers: |cffff0000ALL HIDDEN|r")
        else
            print("|cff00ff00[Infall]|r Blizzard cooldown viewers: |cff00ff00ALL VISIBLE|r")
        end
        
    elseif msg == "setup" then
        if InCombatLockdown() then
            print("|cff00ff00[Infall]|r Cannot open settings in combat.")
            return
        end
        if ns.OpenSettings then
            ns.OpenSettings()
        else
            print("|cff00ff00[Infall]|r Settings not loaded yet.")
        end
        
    elseif msg == "lock" then
        if CONFIG.clickthrough then
            print("|cff00ff00[Infall]|r Cannot unlock while clickthrough is enabled. Use /infall clickthrough first.")
            return
        end

        CONFIG.locked = not CONFIG.locked
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.locked then
            print("|cff00ff00[Infall]|r Frame: |cff00ff00LOCKED|r (cannot drag)")
        else
            print("|cff00ff00[Infall]|r Frame: |cffff0000UNLOCKED|r (drag to reposition)")
        end
        
    elseif msg == "reset" then
        if InCombatLockdown() then
            print("|cffff0000[Infall]|r Cannot reset position during combat.")
            return
        end
        
        EH_Parent:ClearAllPoints()
        EH_Parent:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        InfallDB.position = nil
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        print("|cff00ff00[Infall]|r Position reset to centre")
        
    elseif msg:match("^hide") then
        local val = msg:match("^hide%s+(.+)")
        if val then
            local cdID = tonumber(val)
            if cdID then
                CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
                if CONFIG.hiddenCooldownIDs[cdID] then
                    CONFIG.hiddenCooldownIDs[cdID] = nil
                    print("|cff00ff00[Infall]|r Cooldown ID " .. cdID .. ": |cff00ff00VISIBLE|r")
                    print("|cff00ff00[Infall]|r Saved with your next profile save, or |cffffff00/infall setup|r now")
                else
                    CONFIG.hiddenCooldownIDs[cdID] = true
                    print("|cff00ff00[Infall]|r Cooldown ID " .. cdID .. ": |cffff0000HIDDEN|r")
                    print("|cff00ff00[Infall]|r Saved with your next profile save, or |cffffff00/infall setup|r now")
                end
                EHF.LoadEssentialCooldowns()
            else
                print("|cff00ff00[Infall]|r Usage: /infall hide <cooldownID>  (toggles visibility)")
            end
        else
            print("|cff00ff00[Infall]|r Current bars (cooldownID → spell):")
            for _, row in ipairs(cooldownBars) do
                print("  " .. (row.cooldownID or "?") .. " → " .. (row.spellName or "Unknown") .. " (spellID " .. (row.spellID or "?") .. ")")
            end
            local hiddenList = CONFIG.hiddenCooldownIDs
            if hiddenList and next(hiddenList) then
                print("|cff00ff00[Infall]|r Hidden cooldown IDs:")
                for id, v in pairs(hiddenList) do
                    if v then print("  " .. id) end
                end
            end
            print("|cff00ff00[Infall]|r Usage: /infall hide <cooldownID> to toggle")
        end
        
    elseif msg:match("^pos") then
        local val = msg:match("^pos%s+(.+)")
        if val then
            if InCombatLockdown() then
                print("|cffff0000[Infall]|r Cannot reposition during combat.")
                return
            end
            local parts = {}
            for num in val:gmatch("[%-]?[%d%.]+") do
                table.insert(parts, tonumber(num))
            end
            if parts[1] and parts[2] then
                EH_Parent:ClearAllPoints()
                EH_Parent:SetPoint("CENTER", UIParent, "CENTER", parts[1], parts[2])
                InfallDB.position = { point = "CENTER", relPoint = "CENTER", x = parts[1], y = parts[2] }
                if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                print("|cff00ff00[Infall]|r Position set to " .. parts[1] .. ", " .. parts[2])
            else
                print("|cff00ff00[Infall]|r Usage: /infall pos <x> <y>  (offset from centre)")
            end
        else
            local point, _, relPoint, x, y = EH_Parent:GetPoint()
            print("|cff00ff00[Infall]|r Current position: " .. (point or "?") .. " " .. string.format("%.1f", x or 0) .. ", " .. string.format("%.1f", y or 0) .. " (usage: /infall pos 200 -300)")
        end
        
    elseif msg == "clickthrough" or msg == "ct" then
        CONFIG.clickthrough = not CONFIG.clickthrough

        if CONFIG.clickthrough then
            EH_Parent:EnableMouse(false)
            CONFIG.locked = true
            print("|cff00ff00[Infall]|r Clickthrough: |cff00ff00ENABLED|r (frame is click through and locked)")
        else
            EH_Parent:EnableMouse(true)
            print("|cff00ff00[Infall]|r Clickthrough: |cffff0000DISABLED|r (frame is interactive)")
        end
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
    elseif msg:match("^gap") then
        local val = msg:match("^gap%s+(.+)")
        if val then
            local n = tonumber(val)
            if n and n >= 0 and n <= 30 then
                CONFIG.iconGap = n
                ApplyLayoutToAllBars()
                if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                print("|cff00ff00[Infall]|r Icon gap set to " .. n .. "px")
            else
                print("|cff00ff00[Infall]|r Gap must be between 0 and 30. Usage: /infall gap 0")
            end
        else
            print("|cff00ff00[Infall]|r Icon gap: " .. (CONFIG.iconGap or 10) .. "px (usage: /infall gap 0)")
        end
        
    elseif msg == "bufflayer" or msg == "bl" then
        CONFIG.buffLayerAbove = not CONFIG.buffLayerAbove
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.buffLayerAbove then
            print("|cff00ff00[Infall]|r Buff fill: drawn |cff00ff00ON TOP OF|r cooldown fill")
        else
            print("|cff00ff00[Infall]|r Buff fill: drawn |cffff9900BEHIND|r cooldown fill")
        end
        
        for _, row in ipairs(cooldownBars) do
            ApplyBuffLayer(row)
        end
        
    elseif msg == "repair" then
        if ns.RepairSelfBuffPairings then ns.RepairSelfBuffPairings(true) end

    elseif msg == "forgetauras" then
        local AC = ns.AuraCompat
        if AC and AC.ForgetLearned then
            local n = AC.ForgetLearned()
            print("|cff88e05cInfall|r forgot " .. n .. " learned aura entries. They relearn as you play.")
        end

    elseif msg == "icons" then
        CONFIG.hideIcons = not CONFIG.hideIcons
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.hideIcons then
            print("|cff00ff00[Infall]|r Icons: |cffff0000HIDDEN|r (text only strip for charges/stacks)")
        else
            print("|cff00ff00[Infall]|r Icons: |cff00ff00VISIBLE|r")
        end
        
        ApplyLayoutToAllBars()
        UpdateBars()
        
    elseif msg:match("^scale") then
        local val = msg:match("^scale%s+(.+)")
        if val then
            local n = tonumber(val)
            if n and n >= 0.5 and n <= 3.0 then
                CONFIG.scale = n
                EH_Parent:SetScale(n)
                if ns.SyncStackContainerLayout then ns.SyncStackContainerLayout() end
                if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                print("|cff00ff00[Infall]|r Scale set to " .. n)
            else
                print("|cff00ff00[Infall]|r Scale must be between 0.5 and 3.0")
            end
        else
            print("|cff00ff00[Infall]|r Current scale: " .. CONFIG.scale .. " (usage: /infall scale 1.2)")
        end
        
    elseif msg:match("^lines") then
        local val = msg:match("^lines%s+(.+)")
        if val then
            if val == "off" or val == "none" or val == "0" then
                CONFIG.lines = nil
                EHF.CreateTimeLines()
                if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                print("|cff00ff00[Infall]|r Time markers: |cffff0000DISABLED|r")
            else
                local newLines = {}
                for num in val:gmatch("[%d%.]+") do
                    local n = tonumber(num)
                    if n and n > 0 then
                        table.insert(newLines, n)
                    end
                end
                if #newLines > 0 then
                    CONFIG.lines = newLines
                    EHF.CreateTimeLines()
                    if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                    local str = table.concat(newLines, ", ")
                    print("|cff00ff00[Infall]|r Time markers at: " .. str .. "s")
                else
                    print("|cff00ff00[Infall]|r Invalid input. Usage: /infall lines 1 3 7")
                end
            end
        else
            if CONFIG.lines then
                local t = type(CONFIG.lines) == "table" and CONFIG.lines or {CONFIG.lines}
                print("|cff00ff00[Infall]|r Time markers at: " .. table.concat(t, ", ") .. "s (usage: /infall lines 1 3 7 or /infall lines off)")
            else
                print("|cff00ff00[Infall]|r Time markers: disabled (usage: /infall lines 1 3 7)")
            end
        end
        
    elseif msg:match("^static") then
        local val = msg:match("^static%s+(.+)")
        if val then
            if val == "off" or val == "none" or val == "0" then
                CONFIG.staticHeight = nil
                ApplyLayoutToAllBars()
                if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                print("|cff00ff00[Infall]|r Static height: |cffff0000DISABLED|r")
            else
                local parts = {}
                for num in val:gmatch("[%d%.]+") do
                    table.insert(parts, tonumber(num))
                end
                if parts[1] and parts[1] >= 40 then
                    CONFIG.staticHeight = parts[1]
                    if parts[2] then
                        CONFIG.staticFrames = math.floor(parts[2])
                    end
                    ApplyLayoutToAllBars()
                    if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                    local msg_out = "|cff00ff00[Infall]|r Static height: |cff00ff00" .. CONFIG.staticHeight .. "px|r"
                    if (CONFIG.staticFrames or 0) > 0 then
                        msg_out = msg_out .. " (min " .. CONFIG.staticFrames .. " bars)"
                    end
                    print(msg_out)
                else
                    print("|cff00ff00[Infall]|r Height must be at least 40. Usage: /infall static 150 or /infall static 150 4")
                end
            end
        else
            if CONFIG.staticHeight then
                print("|cff00ff00[Infall]|r Static height: " .. CONFIG.staticHeight .. "px, min frames: " .. (CONFIG.staticFrames or 0) .. " (usage: /infall static 150 or /infall static off)")
            else
                print("|cff00ff00[Infall]|r Static height: disabled (usage: /infall static 150 or /infall static 150 4)")
            end
        end
        
    elseif msg:match("^past") then
        local val = msg:match("^past%s+(.+)")
        if val then
            if val == "off" or val == "none" or val == "0" then
                CONFIG.past = 0
                ApplyLayoutToAllBars()
                if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                print("|cff00ff00[Infall]|r Past region: |cffff0000DISABLED|r")
            else
                local n = tonumber(val)
                if n and n >= 0 and n <= 10 then
                    CONFIG.past = n
                    ApplyLayoutToAllBars()
                    if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                    print("|cff00ff00[Infall]|r Past region: |cff00ff00" .. n .. "s|r")
                else
                    print("|cff00ff00[Infall]|r Past must be between 0 and 10. Usage: /infall past 2.5")
                end
            end
        else
            print("|cff00ff00[Infall]|r Past region: " .. CONFIG.past .. "s (usage: /infall past 2.5 or /infall past off)")
        end
        
    elseif msg:match("^nowline") then
        local val = msg:match("^nowline%s+(.+)")
        if val then
            -- Parse: "nowline 2" (width) or "nowline 2 1 1 1 0.7" (width + r g b a)
            local parts = {}
            for num in val:gmatch("[%d%.]+") do
                table.insert(parts, tonumber(num))
            end
            if parts[1] then
                CONFIG.nowLineWidth = math.max(1, math.min(parts[1], 6))
                if parts[2] and parts[3] and parts[4] then
                    CONFIG.nowLineColor = {parts[2], parts[3], parts[4], parts[5] or 0.7}
                end
                ApplyLayoutToAllBars()
                if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                print("|cff00ff00[Infall]|r Now line: width=" .. CONFIG.nowLineWidth .. "px")
            else
                print("|cff00ff00[Infall]|r Usage: /infall nowline 2 or /infall nowline 2 1 1 1 0.7")
            end
        else
            print("|cff00ff00[Infall]|r Now line: width=" .. CONFIG.nowLineWidth .. "px (usage: /infall nowline 2 or /infall nowline 2 r g b a)")
        end
        
    else
        print("|cff00ff00[Infall]|r Commands:")
        print("  |cffffff00/infall setup|r - Open the settings panel (all settings, profiles, buff pairing)")
        print("")
        print("|cff00ff00  Feature toggles|r (saved to your profile):")
        print("  /infall reactive - Toggle reactive icon colouring")
        print("  /infall desat - Toggle cooldown desaturation")
        print("  /infall redshift - Toggle Redshift (hide when out of combat with no target)")
        print("  /infall pandemic - Toggle pandemic pulse (target debuffs pulse in refresh window)")
        print("  /infall castbar - Toggle Blizzard cast bar visibility")
        print("  /infall ecm - Toggle Blizzard cooldown viewer visibility")
        print("  /infall bufflayer - Toggle buff bars above/below cooldown bars")
        print("  /infall icons - Toggle icon visibility (collapse to text only strip)")
        print("  /infall lock - Toggle frame lock (prevents dragging)")
        print("  /infall clickthrough - Toggle click through mode (autolocks frame)")
        print("|cff00ff00  Layout|r (saved to your profile as soon as you set them):")
        print("  /infall scale [0.5-3.0] - Set frame scale")
        print("  /infall gap [0-30] - Set icon-to-bar gap")
        print("  /infall lines [s1 s2 ...] - Set time markers (ie /infall lines 1 3 7)")
        print("  /infall static [height] [minBars] - Set fixed frame height")
        print("  /infall past [0-10] - Set past timeline duration")
        print("  /infall nowline [width] [r g b a] - Set now line appearance")
        print("  /infall hide [cooldownID] - Hide a bar, saved with your next profile save")
        print("|cff00ff00  Position|r (saved per character):")
        print("  /infall pos [x] [y] - Set exact position (offset from centre)")
        print("  /infall reset - Reset position to centre")
        print("  /infall reload - Reload cooldowns")
    end
end

-- Expose for Settings.lua
ns.LoadEssentialCooldowns = EHF.LoadEssentialCooldowns
ns.ApplyLayoutToAllBars = ApplyLayoutToAllBars
ns.cooldownBars = cooldownBars

ns.ShowVariantPreview = function()
    for _, row in ipairs(cooldownBars) do
        if row.variantNameText and row.barTextOverlay then
            ApplyFont(row.variantNameText, CONFIG.variantTextSize or (CONFIG.fontSize - 2))
            row.variantNameText:SetTextColor(unpack(CONFIG.variantTextColor))
            row.variantNameText:ClearAllPoints()
            row.variantNameText:SetPoint(CONFIG.variantTextAnchor, row.barTextOverlay, CONFIG.variantTextRelPoint, CONFIG.variantTextOffsetX, CONFIG.variantTextOffsetY)
            row.variantNameText:SetText("Variant Name Anchor")
            row.variantNameText:Show()
        end
    end
end

ns.HideVariantPreview = function()
    for _, row in ipairs(cooldownBars) do
        if row.variantNameText then
            row.variantNameText:Hide()
        end
    end
end

ns.ShowDurationPreview = function()
    for _, row in ipairs(cooldownBars) do
        if row.cdTextCooldown then
            -- Feed first so engine creates the font string
            row.cdTextCooldown:SetHideCountdownNumbers(false)
            row.cdTextCooldown:SetMinimumCountdownDuration(0)
            row.cdTextCooldown:SetCooldown(GetTime(), 105)
            -- Now style it
            local fsOk, fs = pcall(row.cdTextCooldown.GetCountdownFontString, row.cdTextCooldown)
            if fsOk and fs then
                ApplyFont(fs, CONFIG.cdDurationTextSize or CONFIG.fontSize)
                fs:SetTextColor(unpack(CONFIG.cdDurationTextColor))
                fs:ClearAllPoints()
                fs:SetPoint(CONFIG.cdDurationTextAnchor, row.barTextOverlay, CONFIG.cdDurationTextRelPoint, CONFIG.cdDurationTextOffsetX, CONFIG.cdDurationTextOffsetY)
            end
        end
    end
end

ns.HideDurationPreview = function()
    for _, row in ipairs(cooldownBars) do
        if row.cdTextCooldown then
            row.cdTextCooldown:SetCooldown(0, 0)
            row.cdTextCooldown:SetHideCountdownNumbers(not CONFIG.showCooldownDuration)
            row.cdTextCooldown:SetMinimumCountdownDuration((CONFIG.cdTextMinDuration or 30) * 1000)
            local fsOk, fs = pcall(row.cdTextCooldown.GetCountdownFontString, row.cdTextCooldown)
            if fsOk and fs then fs:SetText("") end
        end
    end
end

ns.UpdateDurationTextSettings = function()
    for _, row in ipairs(cooldownBars) do
        if row.cdTextCooldown then
            row.cdTextCooldown:SetHideCountdownNumbers(not CONFIG.showCooldownDuration)
            row.cdTextCooldown:SetMinimumCountdownDuration((CONFIG.cdTextMinDuration or 30) * 1000)
        end
    end
end

-- STACK INDICATORS

-- do...end so its locals stay off the main chunk's 200 limit. Exports are on ns.
do

local SI_DEFAULTS = {
    position = "TOP",
    gap = 2,
    pipHeight = 6,
    pipSpacing = 1,
    rowSpacing = 1,
    borderSize = 1,
    emptyColor = {0.12, 0.12, 0.12, 0.6},
    glowAtMax = true,
    glowColor = {1, 1, 1, 0.6},
}

local function GetSISettings()
    if not CONFIG.stackIndicatorSettings then
        CONFIG.stackIndicatorSettings = {}
    end
    local s = CONFIG.stackIndicatorSettings
    for k, v in pairs(SI_DEFAULTS) do
        if s[k] == nil then
            if type(v) == "table" then
                s[k] = {unpack(v)}
            else
                s[k] = v
            end
        end
    end
    return s
end

local function GetSIList()
    if not CONFIG.stackIndicatorList then
        CONFIG.stackIndicatorList = {}
    end
    return CONFIG.stackIndicatorList
end

local stackContainerTop
local stackContainerBottom
local siHooksInstalled = false
local indicatorRows = {}
siIsBuilt = false
local siRowPool = {}

local siPipPool = {}

-- Pooled: frames and textures are never freed, and pips rebuild on every zone
-- change, spec change and reorder. Children are cached and reconfigured.
local function CreateSIPip(parent, index, indicatorConfig, settings)
    local maxStacks = indicatorConfig.maxStacks or 3
    local hasOverflow = indicatorConfig.overflowMax and indicatorConfig.overflowMax > maxStacks

    local pip = table.remove(siPipPool)
    if pip then
        pip:SetParent(parent)
        pip:ClearAllPoints()
        pip:Show()
    else
        pip = CreateFrame("Frame", nil, parent)
    end

    -- Real pixels, not UI units. Matches the timeline markers, which were the same
    -- bug: a UI unit is wider than a pixel on any high resolution display.
    local bs = (settings.borderSize or 0) * ns.OnePxForFrame(pip)

    local bc = settings.borderColor or CONFIG.bordercolor or {0, 0, 0, 1}
    local br, bg2, bb, ba = bc[1], bc[2], bc[3], bc[4] or 1
    if bs > 0 then
        if not pip.bTop then
            pip.bTop = pip:CreateTexture(nil, "BACKGROUND")
            pip.bBot = pip:CreateTexture(nil, "BACKGROUND")
            pip.bLeft = pip:CreateTexture(nil, "BACKGROUND")
            pip.bRight = pip:CreateTexture(nil, "BACKGROUND")
        end

        local bTop = pip.bTop
        bTop:ClearAllPoints()
        bTop:SetPoint("TOPLEFT") bTop:SetPoint("TOPRIGHT")
        bTop:SetHeight(bs)
        bTop:SetColorTexture(br, bg2, bb, ba)
        bTop:Show()

        local bBot = pip.bBot
        bBot:ClearAllPoints()
        bBot:SetPoint("BOTTOMLEFT") bBot:SetPoint("BOTTOMRIGHT")
        bBot:SetHeight(bs)
        bBot:SetColorTexture(br, bg2, bb, ba)
        bBot:Show()

        local bLeft = pip.bLeft
        bLeft:ClearAllPoints()
        bLeft:SetPoint("TOPLEFT", 0, -bs) bLeft:SetPoint("BOTTOMLEFT", 0, bs)
        bLeft:SetWidth(bs)
        bLeft:SetColorTexture(br, bg2, bb, ba)
        bLeft:Show()

        local bRight = pip.bRight
        bRight:ClearAllPoints()
        bRight:SetPoint("TOPRIGHT", 0, -bs) bRight:SetPoint("BOTTOMRIGHT", 0, bs)
        bRight:SetWidth(bs)
        bRight:SetColorTexture(br, bg2, bb, ba)
        bRight:Show()
    elseif pip.bTop then
        -- Border turned off on a pip that had one.
        pip.bTop:Hide() pip.bBot:Hide() pip.bLeft:Hide() pip.bRight:Hide()
    end

    local ec = settings.emptyColor
    local emptyTex = pip.emptyTex
    if not emptyTex then
        emptyTex = pip:CreateTexture(nil, "BORDER")
        pip.emptyTex = emptyTex
    end
    emptyTex:ClearAllPoints()
    emptyTex:SetPoint("TOPLEFT", bs, -bs)
    emptyTex:SetPoint("BOTTOMRIGHT", -bs, bs)
    emptyTex:SetColorTexture(ec[1], ec[2], ec[3], ec[4] or 0.6)
    emptyTex:Show()

    local baseBar = pip.baseBar or CreateFrame("StatusBar", nil, pip)
    baseBar:ClearAllPoints()
    baseBar:SetPoint("TOPLEFT", pip, "TOPLEFT", bs, -bs)
    baseBar:SetPoint("BOTTOMRIGHT", pip, "BOTTOMRIGHT", -bs, bs)
    baseBar:SetMinMaxValues(index - 1, index)
    baseBar:SetValue(0)
    baseBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")

    local color = indicatorConfig.stackColors and indicatorConfig.stackColors[index]
    if not color then color = indicatorConfig.color or {0.8, 0.2, 0.1, 1} end
    baseBar:SetStatusBarColor(color[1], color[2], color[3], color[4] or 1)
    CrispBar(baseBar)

    pip.baseBar = baseBar
    baseBar:Show()

    if hasOverflow then
        local overflowBar = pip.overflowBar or CreateFrame("StatusBar", nil, pip)
        overflowBar:ClearAllPoints()
        overflowBar:SetPoint("TOPLEFT", pip, "TOPLEFT", bs, -bs)
        overflowBar:SetPoint("BOTTOMRIGHT", pip, "BOTTOMRIGHT", -bs, bs)
        overflowBar:SetMinMaxValues(maxStacks + index - 1, maxStacks + index)
        overflowBar:SetValue(0)
        overflowBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
        overflowBar:SetFrameLevel(baseBar:GetFrameLevel() + 1)

        local oc = indicatorConfig.overflowColor or {1, 0.8, 0.2, 1}
        overflowBar:SetStatusBarColor(oc[1], oc[2], oc[3], oc[4] or 1)
        CrispBar(overflowBar)

        pip.overflowBar = overflowBar
        overflowBar:Show()
    elseif pip.overflowBar then
        pip.overflowBar:Hide()
    end

    return pip
end

local siGlowPool = {}

local function CreateSIGlowOverlay(parent, settings, totalMax)
    -- StatusBar glow: fills to 100% at totalMax via SetValue.
    -- Pooled with its animation group; a dropped one keeps looping.
    local glowBar = table.remove(siGlowPool)
    if glowBar then
        glowBar:SetParent(parent)
        glowBar:ClearAllPoints()
        glowBar:SetAllPoints()
        glowBar:SetFrameLevel(parent:GetFrameLevel() + 10)
        glowBar:SetMinMaxValues(totalMax - 0.5, totalMax)
        glowBar:SetValue(0)
        local gc = settings.glowColor or {1, 1, 1, 0.6}
        glowBar:GetStatusBarTexture():SetVertexColor(gc[1], gc[2], gc[3], gc[4] or 0.6)
        -- Shown with a zero value, matching a freshly created glow. The fill only
        -- appears at max stacks; Hide here left every rebuilt glow dark for good.
        glowBar:Show()
        if glowBar.anim and not glowBar.anim:IsPlaying() then glowBar.anim:Play() end
        return glowBar
    end

    glowBar = CreateFrame("StatusBar", nil, parent)
    glowBar:SetAllPoints()
    glowBar:SetFrameLevel(parent:GetFrameLevel() + 10)
    glowBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    glowBar:SetMinMaxValues(totalMax - 0.5, totalMax)
    glowBar:SetValue(0)

    local gc = settings.glowColor or {1, 1, 1, 0.6}
    glowBar:GetStatusBarTexture():SetVertexColor(gc[1], gc[2], gc[3], gc[4] or 0.6)

    local ag = glowBar:CreateAnimationGroup()
    ag:SetLooping("REPEAT")

    local fadeIn = ag:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.65)
    fadeIn:SetOrder(1)

    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.65)
    fadeOut:SetOrder(2)

    glowBar.anim = ag
    ag:Play()

    return glowBar
end

local function SyncStackLayout()
    if not EH_Parent then return end
    if not stackContainerTop and not stackContainerBottom then return end
    local settings = GetSISettings()
    local gap = settings.gap or 2
    local pipHeight = settings.pipHeight or 6
    local pipSpacing = settings.pipSpacing or 1
    local rowSpacing = settings.rowSpacing or 1

    local function LayoutContainer(container, rows, isBottom)
        if not container then return end
        -- The icon strip can be set to sit between the frame and the pips, in
        -- which case the pips start beyond it instead of at the frame edge.
        local edge = gap
        if ns.Icons and ns.Icons.GetEdgeHeight then
            edge = edge + ns.Icons.GetEdgeHeight(isBottom and "BOTTOM" or "TOP")
        end
        container:ClearAllPoints()
        if isBottom then
            container:SetPoint("TOPLEFT", EH_Parent, "BOTTOMLEFT", 0, -edge)
            container:SetPoint("TOPRIGHT", EH_Parent, "BOTTOMRIGHT", 0, -edge)
        else
            container:SetPoint("BOTTOMLEFT", EH_Parent, "TOPLEFT", 0, edge)
            container:SetPoint("BOTTOMRIGHT", EH_Parent, "TOPRIGHT", 0, edge)
        end

        local containerWidth = container:GetWidth()
        if not containerWidth or containerWidth <= 0 then
            local ehScale = EH_Parent:GetScale() or 1
            local cScale = container:GetScale() or 1
            containerWidth = EH_Parent:GetWidth() * ehScale / cScale
        end

        local totalHeight = 0
        local layoutOrder = rows
        if not isBottom then
            layoutOrder = {}
            for ri = #rows, 1, -1 do layoutOrder[#layoutOrder + 1] = rows[ri] end
        end
        for _, rowData in ipairs(layoutOrder) do
            local numPips = #rowData.pips
            if numPips > 0 and rowData.frame:IsShown() then
                totalHeight = totalHeight + (rowData.gap or 0)
                local rowFrame = rowData.frame
                rowFrame:ClearAllPoints()
                if isBottom then
                    rowFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -totalHeight)
                    rowFrame:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -totalHeight)
                else
                    rowFrame:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, totalHeight)
                    rowFrame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, totalHeight)
                end
                local rowH = rowData.height or pipHeight
                rowFrame:SetHeight(rowH)

                local onePx = ns.OnePxForFrame(rowFrame)
                local snap = ns.SnapPx
                local snappedSpacing = snap(pipSpacing, onePx)
                local snappedContainerW = snap(containerWidth, onePx)

                -- Snap the cut points and add whole gaps. Rounding each pip's start and end
                -- separately let neighbours land a pixel apart or touching.
                local usableW = snappedContainerW - (numPips - 1) * snappedSpacing
                for j, pip in ipairs(rowData.pips) do
                    local idx = j - 1
                    local startX = snap(idx * usableW / numPips, onePx) + idx * snappedSpacing
                    local endX = (j == numPips) and snappedContainerW
                        or (snap(j * usableW / numPips, onePx) + idx * snappedSpacing)
                    pip:ClearAllPoints()
                    pip:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", startX, 0)
                    pip:SetSize(math.max(onePx, endX - startX), rowH)
                end

                if rowData.glow then
                    rowData.glow:ClearAllPoints()
                    rowData.glow:SetAllPoints(rowFrame)
                end

                totalHeight = totalHeight + rowH + rowSpacing
            end
        end
        if totalHeight > 0 then totalHeight = totalHeight - rowSpacing end
        container:SetHeight(math.max(totalHeight, 1))
        local parentVisible = EH_Parent and EH_Parent:IsShown()
        if totalHeight == 0 or not parentVisible then container:Hide() else container:Show() end
    end

    local topRows, bottomRows = {}, {}
    for _, rowData in ipairs(indicatorRows) do
        if rowData.position == "BOTTOM" then
            bottomRows[#bottomRows + 1] = rowData
        else
            topRows[#topRows + 1] = rowData
        end
    end

    local rbRow = ns.GetResourceBarRow and ns.GetResourceBarRow()
    if rbRow then
        local rbContainer = (rbRow.position == "BOTTOM") and stackContainerBottom or stackContainerTop
        if rbContainer then rbRow.frame:SetParent(rbContainer) end
        local targetRows = rbRow.position == "BOTTOM" and bottomRows or topRows
        local insertAt = math.max(1, math.min(rbRow.order or (#targetRows + 1), #targetRows + 1))
        table.insert(targetRows, insertAt, rbRow)
    end

    LayoutContainer(stackContainerTop, topRows, false)
    LayoutContainer(stackContainerBottom, bottomRows, true)
end

-- EDGE ORDER. One reading of pips, resource bar and strip on a shared edge,
-- ordered OUTWARD from the frame. The top container lays its rows out in
-- reverse; that flip is handled here and never reaches a caller.

local function EdgeItemLabel(entry)
    if entry.indicatorType == "power" then
        local info = ns.POWER_TYPE_INFO and ns.POWER_TYPE_INFO[entry.powerType]
        return (info and info.name) or ("Power " .. tostring(entry.powerType or "?"))
    end
    local spellID = entry.auraSpellID
    if (not spellID or spellID == 0) and entry.cooldownID then
        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, entry.cooldownID)
        if ok and info then spellID = info.spellID end
    end
    return (spellID and C_Spell.GetSpellName(spellID)) or "Stack row"
end

local function Reversed(t)
    local out = {}
    for i = #t, 1, -1 do out[#out + 1] = t[i] end
    return out
end

ns.EdgeOrder = {}

function ns.EdgeOrder.Items(position)
    local rows = {}
    if CONFIG.stackIndicators then
        for i, entry in ipairs(GetSIList()) do
            if (entry.position or "TOP") == position then
                rows[#rows + 1] = { kind = "pip", listIndex = i, label = EdgeItemLabel(entry) }
            end
        end
    end

    local rb = CONFIG.resourceBar
    if rb and rb.enabled and (rb.position or "BOTTOM") == position then
        local at = math.max(1, math.min(rb.order or (#rows + 1), #rows + 1))
        table.insert(rows, at, { kind = "resource", label = "Resource bar" })
    end

    if position == "TOP" then rows = Reversed(rows) end

    -- Strips sit outside the shared container, at one end of it or the other.
    local items = {}
    if CONFIG.iconsEnabled then
        for _, cfg in ipairs(CONFIG.iconContainers or {}) do
            if cfg.anchor == position then
                local entry = { kind = "strip", key = cfg.key, label = "Icon strip" }
                if (cfg.edgeOrder or "outside") == "inside" then
                    items[#items + 1] = entry
                else
                    rows[#rows + 1] = entry
                end
            end
        end
    end
    for _, r in ipairs(rows) do items[#items + 1] = r end
    return items
end

local function SameItem(a, b)
    if a.kind ~= b.kind then return false end
    if a.kind == "pip" then return a.listIndex == b.listIndex end
    if a.kind == "strip" then return a.key == b.key end
    return true
end

-- delta -1 moves toward the frame, +1 away from it.
function ns.EdgeOrder.CanMove(position, item, delta)
    local items = ns.EdgeOrder.Items(position)
    for i, it in ipairs(items) do
        if SameItem(it, item) then
            local j = i + delta
            return j >= 1 and j <= #items
        end
    end
    return false
end

function ns.EdgeOrder.Move(position, item, delta)
    local items = ns.EdgeOrder.Items(position)
    local idx
    for i, it in ipairs(items) do
        if SameItem(it, item) then
            idx = i
            break
        end
    end
    if not idx then return false end
    local other = items[idx + delta]
    if not other then return false end

    -- A pip trading places with the resource bar is the resource bar moving the
    -- other way, so there is only ever one rule per pair.
    if item.kind == "pip" and other.kind == "resource" then
        return ns.EdgeOrder.Move(position, other, -delta)
    end
    if item.kind == "resource" and other.kind == "strip" then
        return ns.EdgeOrder.Move(position, other, -delta)
    end
    if item.kind == "pip" and other.kind == "strip" then
        return ns.EdgeOrder.Move(position, other, -delta)
    end

    if item.kind == "strip" then
        for _, cfg in ipairs(CONFIG.iconContainers or {}) do
            if cfg.key == item.key then
                cfg.edgeOrder = (delta < 0) and "inside" or "outside"
            end
        end

    elseif item.kind == "resource" then
        local rb = CONFIG.resourceBar
        if not rb then return false end
        local pipCount = 0
        if CONFIG.stackIndicators then
            for _, entry in ipairs(GetSIList()) do
                if (entry.position or "TOP") == position then pipCount = pipCount + 1 end
            end
        end
        -- Stored as an insert index among the pip rows, which runs the other way
        -- on top.
        local step = (position == "TOP") and -delta or delta
        local cur = math.max(1, math.min(rb.order or (pipCount + 1), pipCount + 1))
        local nextAt = math.max(1, math.min(cur + step, pipCount + 1))
        rb.order = (nextAt > pipCount) and nil or nextAt

    elseif item.kind == "pip" then
        if other.kind ~= "pip" then return false end
        local list = GetSIList()
        local a, b = item.listIndex, other.listIndex
        list[a], list[b] = list[b], list[a]
    end

    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
    if ns.SyncStackContainerLayout then ns.SyncStackContainerLayout() end
    return true
end

-- Pip rows and the resource bar share one container per edge. Only while shown:
-- an empty one keeps a 1px height and offsetting past it would be a dead gap.
function ns.GetStackEdgeFrame(position)
    local c = (position == "BOTTOM") and stackContainerBottom or stackContainerTop
    if c and c:IsShown() then return c end
    return nil
end

function EHF.SyncStackContainerLayout()
    if siIsBuilt then
        SyncStackLayout()
    end
    -- The strip anchors off that container.
    if CONFIG.iconsEnabled and ns.Icons then ns.Icons.Layout() end
end
ns.SyncStackContainerLayout = EHF.SyncStackContainerLayout

function EHF.UpdateAllSIPips()
    local list = GetSIList()
    local settings = GetSISettings()
    local layoutDirty = false

    for _, rowData in ipairs(indicatorRows) do
        local config = list[rowData.configIndex]
        if config then
            -- Resolved on its own: the count comparison below throws while it is secret.
            local gated = config.requireTalent ~= nil
                and not ns.IsTalentKnown(config.requireTalent)
            local applications = 0

            if gated then
                -- Nothing to read: the row is not drawing.
            elseif config.indicatorType == "power" and config.powerType then
                local ok, power = pcall(UnitPower, "player", config.powerType)
                -- Forever: do not feed secret power into pip SetValue; keep prior count.
                if ok and power ~= nil and not (issecretvalue and issecretvalue(power)) then
                    applications = power
                    rowData._lastPowerApps = power
                else
                    applications = rowData._lastPowerApps or 0
                end
            elseif config.cooldownID then
                local buffFrame = ResolveBuffFrame(config.cooldownID)
                if buffFrame and buffFrame.auraInstanceID ~= nil then
                    local appVal = AC.ReadApplications(buffFrame)
                    if appVal ~= nil then
                        applications = appVal
                    end
                end
            end

            -- Hide when empty
            local wasShown = rowData.frame:IsShown()
            if gated then
                rowData.frame:Hide()
            elseif config.hideWhenEmpty then
                local hideOk, isEmpty = pcall(IsZero, applications)
                if hideOk and isEmpty then
                    rowData.frame:Hide()
                else
                    rowData.frame:Show()
                end
            else
                rowData.frame:Show()
            end
            if rowData.frame:IsShown() ~= wasShown then
                layoutDirty = true
            end

            for _, pip in ipairs(rowData.pips) do
                pip.baseBar:SetValue(applications)
                if pip.overflowBar then
                    pip.overflowBar:SetValue(applications)
                end
            end

            if settings.glowAtMax and rowData.glow then
                rowData.glow:SetValue(applications)
            end
        end
    end

    if layoutDirty then
        SyncStackLayout()
    end
end

-- Talents changed, so re-evaluate the gates now rather than waiting for the
-- next poll, and repaint the panel so its live tint follows.
ns.RefreshStackIndicatorGates = function()
    if siIsBuilt and CONFIG.stackIndicators then EHF.UpdateAllSIPips() end
    if ns.RefreshStacksTab then ns.RefreshStacksTab() end
end

local function WipeSIIndicators()
    for _, rowData in ipairs(indicatorRows) do
        if rowData.glow then
            if rowData.glow.anim and rowData.glow.anim:IsPlaying() then
                rowData.glow.anim:Stop()
            end
            rowData.glow:SetValue(0)
            rowData.glow:Hide()
            rowData.glow:SetParent(UIParent)
            siGlowPool[#siGlowPool + 1] = rowData.glow
        end
        for _, pip in ipairs(rowData.pips) do
            pip:Hide()
            pip:SetParent(UIParent)
            siPipPool[#siPipPool + 1] = pip
        end
        rowData.frame:Hide()
        siRowPool[#siRowPool + 1] = rowData.frame
    end
    wipe(indicatorRows)
    if stackContainerTop then stackContainerTop:Hide() end
    if stackContainerBottom then stackContainerBottom:Hide() end
end

local function AcquireSIRow(parent)
    local frame = table.remove(siRowPool)
    if frame then
        frame:SetParent(parent)
        frame:ClearAllPoints()
        for _, region in pairs({frame:GetRegions()}) do
            region:Hide()
            region:SetParent(nil)
        end
        for _, child in pairs({frame:GetChildren()}) do
            child:Hide()
            child:SetParent(nil)
        end
        return frame
    end
    return CreateFrame("Frame", nil, parent)
end

local function BuildSIIndicators()
    WipeSIIndicators()

    local hasRB = CONFIG.resourceBar and CONFIG.resourceBar.enabled
    if not CONFIG.stackIndicators and not hasRB then
        siIsBuilt = false
        return
    end

    local list = CONFIG.stackIndicators and GetSIList() or {}
    if #list == 0 and not hasRB then
        siIsBuilt = false
        return
    end

    local settings = GetSISettings()

    if not stackContainerTop then
        stackContainerTop = CreateFrame("Frame", "EH_StackIndicatorTop", UIParent)
        stackContainerTop:SetFrameStrata("MEDIUM")
        stackContainerBottom = CreateFrame("Frame", "EH_StackIndicatorBottom", UIParent)
        stackContainerBottom:SetFrameStrata("MEDIUM")
    end

    if not siHooksInstalled and EH_Parent then
        EH_Parent:HookScript("OnShow", function()
            if siIsBuilt then
                if stackContainerTop then stackContainerTop:Show() end
                if stackContainerBottom then stackContainerBottom:Show() end
                SyncStackLayout()
            end
        end)
        EH_Parent:HookScript("OnHide", function()
            if stackContainerTop then stackContainerTop:Hide() end
            if stackContainerBottom then stackContainerBottom:Hide() end
        end)
        EH_Parent:HookScript("OnSizeChanged", function()
            if siIsBuilt then SyncStackLayout() end
        end)
        siHooksInstalled = true
    end

    for i, config in ipairs(list) do
        local skipRow = false
        if config.cooldownID then
            local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, config.cooldownID)
            if not ok or not info then skipRow = true end
        end

        if not skipRow then
        local pos = config.position or settings.position or "TOP"
        local parentContainer = (pos == "BOTTOM") and stackContainerBottom or stackContainerTop
        local rowFrame = AcquireSIRow(parentContainer)
        local pips = {}
        local numPips = config.maxStacks or 3

        -- Resolve colorZones into stackColors for CreateSIPip
        local resolvedConfig = config
        if config.colorZones and #config.colorZones > 0 then
            resolvedConfig = {
                maxStacks = config.maxStacks,
                overflowMax = config.overflowMax,
                overflowColor = config.overflowColor,
                color = config.color,
            }
            local zones = {}
            for _, z in ipairs(config.colorZones) do zones[#zones + 1] = z end
            table.sort(zones, function(a, b) return a.fromStack < b.fromStack end)
            local stackColors = {}
            local zIdx = 1
            for p = 1, numPips do
                while zIdx < #zones and zones[zIdx + 1].fromStack <= p do
                    zIdx = zIdx + 1
                end
                stackColors[p] = zones[zIdx].color
            end
            resolvedConfig.stackColors = stackColors
        end

        for j = 1, numPips do
            local pip = CreateSIPip(rowFrame, j, resolvedConfig, settings)
            pips[j] = pip
        end

        local glow = nil
        if settings.glowAtMax then
            local totalMax = config.overflowMax or config.maxStacks or 3
            glow = CreateSIGlowOverlay(rowFrame, settings, totalMax)
        end

        indicatorRows[#indicatorRows + 1] = {
            frame = rowFrame,
            pips = pips,
            glow = glow,
            position = pos,
            configIndex = i,
        }
        end -- skipRow
    end

    -- Expose row counts for resource bar ordering
    local topCount, bottomCount = 0, 0
    for _, rd in ipairs(indicatorRows) do
        if rd.position == "BOTTOM" then bottomCount = bottomCount + 1
        else topCount = topCount + 1 end
    end
    ns.siRowCounts = {top = topCount, bottom = bottomCount}

    SyncStackLayout()
    siIsBuilt = true
    if not EH_Parent or not EH_Parent:IsShown() then
        if stackContainerTop then stackContainerTop:Hide() end
        if stackContainerBottom then stackContainerBottom:Hide() end
    end
end

function ns.RebuildStackIndicators()
    BuildSIIndicators()
    if siIsBuilt then
        EHF.UpdateAllSIPips()
    end
end

local siEventFrame = CreateFrame("Frame")
siEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
siEventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

siEventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(2.5, function()
            if CONFIG.stackIndicators or (CONFIG.resourceBar and CONFIG.resourceBar.enabled) then
                BuildSIIndicators()
                EHF.UpdateAllSIPips()
            end
        end)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        C_Timer.After(1, function()
            BuildSIIndicators()
            if siIsBuilt then EHF.UpdateAllSIPips() end
        end)
    end
end)
end
