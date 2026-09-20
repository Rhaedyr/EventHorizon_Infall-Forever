-- EventHorizon Infall: Resource Bar
local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG

local resourceRowFrame, resourcePipFrame, resourceBar
local gainOverlay, costOverlay, predictionRefBar
local tickTextures = {}
local valueText, predText

local currentPowerType, currentPowerToken
local currentPowerMax = 0
local maxPowerByType = {}
local eventFrame

local RebuildResourceBar, UpdateTickPositions, UpdateResourceBar, UpdatePrediction

local function CrispBar(bar)
    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
    end
end

local function GetRB()
    return CONFIG.resourceBar or {}
end

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local copy = {}
    for k, val in pairs(v) do copy[k] = DeepCopy(val) end
    return copy
end

-- Observed regen rate, in resource per second. GetPowerRegenForPowerType is secret
-- in combat, so the rate is measured from the player's own power ticks. Only a rise
-- from below the cap measures regen; a secret UnitPower skips that frame.
local observedRegen = 0
local regenPrev, regenPrevAt

local function ResetRegenObservation()
    observedRegen = 0
    regenPrev, regenPrevAt = nil, nil
end
ns.ResetRegenObservation = ResetRegenObservation

-- Last non-secret UnitPower per type. Display sinks (SetValue/SetText) keep this
-- when Forever/Midnight secrets the live reading, matching ObservePowerTick.
local lastPowerByType = {}

local function ReadableUnitPower(powerType)
    if powerType == nil then return nil end
    local ok, value = pcall(UnitPower, "player", powerType)
    if not ok or type(value) ~= "number" or issecretvalue(value) then
        return lastPowerByType[powerType]
    end
    lastPowerByType[powerType] = value
    return value
end

local function ObservePowerTick()
    if not currentPowerType then return end
    local ok, value = pcall(UnitPower, "player", currentPowerType)
    if not ok or type(value) ~= "number" or issecretvalue(value) then return end

    local now = GetTime()
    local prev, prevAt = regenPrev, regenPrevAt
    regenPrev, regenPrevAt = value, now

    if prev == nil or prevAt == nil then return end
    -- Only a rise measures regen, and only from below the cap.
    if value <= prev then return end
    if currentPowerMax > 0 and prev >= currentPowerMax then return end

    local elapsed = now - prevAt
    if elapsed <= 0 or elapsed > 5 then return end

    local rate = (value - prev) / elapsed
    if rate <= 0 or rate > 1000 then return end
    -- Smoothed so one ragged interval cannot swing the prediction.
    observedRegen = (observedRegen > 0) and (observedRegen * 0.7 + rate * 0.3) or rate
end
ns.ObservePowerTick = ObservePowerTick

local function GetRegenRate()
    -- Prefer the API whenever it is readable: a genuine zero, classes that do not regen
    -- while casting, must not be overridden. Fall back only when it is actually secret.
    if GetPowerRegenForPowerType and currentPowerType then
        local ok, _, casting = pcall(GetPowerRegenForPowerType, currentPowerType)
        if ok and type(casting) == "number" and not issecretvalue(casting) then
            return casting
        end
    end
    return observedRegen
end

local function IsTalentKnown(talentSpellID)
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, talentSpellID)
        if ok and known then return true end
    end
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, talentSpellID)
        if ok and known then return true end
    end
    return false
end

local function IsCdmBuffActive(cdID)
    if not cdID then return true end
    if ns.GetPersistentBuffFrame then
        local frame = ns.GetPersistentBuffFrame(cdID)
        if frame and frame.auraInstanceID ~= nil then return true end
    end
    return false
end

local function GetSpellGeneration(spellID)
    if not spellID or issecretvalue(spellID) then return 0 end
    local rb = CONFIG.resourceBar
    if rb and rb.generationOverrides and rb.generationOverrides[spellID] then
        return rb.generationOverrides[spellID]
    end
    local genTable = CONFIG.spellGeneration
    if not genTable or not genTable[spellID] then return 0 end
    local entry = genTable[spellID]
    local total = entry.base or 0
    if entry.talents then
        for _, talent in ipairs(entry.talents) do
            if IsTalentKnown(talent.spellID) and IsCdmBuffActive(talent.requiresCdmBuff) then
                total = total + (talent.bonus or 0)
            end
        end
    end
    return total
end

local function GetCastSpellCost(spellID)
    if not spellID then return 0 end
    local fn = (C_Spell and C_Spell.GetSpellPowerCost) or GetSpellPowerCost
    if not fn then return 0 end
    local ok, costs = pcall(fn, spellID)
    if not ok or not costs then return 0 end
    for _, info in ipairs(costs) do
        local pType = info.type
        if pType and not issecretvalue(pType) and pType == currentPowerType then
            local c = info.cost or info.minCost
            if not c or issecretvalue(c) then return 0 end
            return c
        end
    end
    return 0
end

-- FRAME CREATION

local function CreateResourceBarFrames()
    if resourceRowFrame then return end

    resourceRowFrame = CreateFrame("Frame", nil, UIParent)
    resourceRowFrame:Hide()

    resourcePipFrame = CreateFrame("Frame", nil, resourceRowFrame)

    -- Placeholder only: the rebuild below re-derives this in real pixels.
    local bs = ns.OnePxForFrame(resourcePipFrame)
    local bTop = resourcePipFrame:CreateTexture(nil, "BACKGROUND")
    bTop:SetPoint("TOPLEFT") bTop:SetPoint("TOPRIGHT")
    bTop:SetHeight(bs)

    local bBot = resourcePipFrame:CreateTexture(nil, "BACKGROUND")
    bBot:SetPoint("BOTTOMLEFT") bBot:SetPoint("BOTTOMRIGHT")
    bBot:SetHeight(bs)

    local bLeft = resourcePipFrame:CreateTexture(nil, "BACKGROUND")
    bLeft:SetPoint("TOPLEFT", 0, -bs) bLeft:SetPoint("BOTTOMLEFT", 0, bs)
    bLeft:SetWidth(bs)

    local bRight = resourcePipFrame:CreateTexture(nil, "BACKGROUND")
    bRight:SetPoint("TOPRIGHT", 0, -bs) bRight:SetPoint("BOTTOMRIGHT", 0, bs)
    bRight:SetWidth(bs)

    resourcePipFrame._borders = {bTop, bBot, bLeft, bRight}

    local bg = resourcePipFrame:CreateTexture(nil, "BORDER")
    bg:SetPoint("TOPLEFT", bs, -bs)
    bg:SetPoint("BOTTOMRIGHT", -bs, bs)
    bg:SetColorTexture(0.08, 0.08, 0.08, 0.8)
    resourcePipFrame._bg = bg

    resourceBar = CreateFrame("StatusBar", nil, resourcePipFrame)
    resourceBar:SetPoint("TOPLEFT", bs, -bs)
    resourceBar:SetPoint("BOTTOMRIGHT", -bs, bs)
    resourceBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    resourceBar:SetMinMaxValues(0, 1)
    resourceBar:SetValue(0)
    resourceBar:SetClipsChildren(true)
    CrispBar(resourceBar)

    gainOverlay = resourceBar:CreateTexture(nil, "OVERLAY")
    gainOverlay:SetDrawLayer("OVERLAY", 1)
    gainOverlay:SetSnapToPixelGrid(false)
    gainOverlay:SetTexelSnappingBias(0)
    gainOverlay:Hide()

    costOverlay = resourceBar:CreateTexture(nil, "OVERLAY")
    costOverlay:SetDrawLayer("OVERLAY", 2)
    costOverlay:SetSnapToPixelGrid(false)
    costOverlay:SetTexelSnappingBias(0)
    costOverlay:Hide()

    predictionRefBar = CreateFrame("StatusBar", nil, resourcePipFrame)
    predictionRefBar:SetAllPoints(resourceBar)
    predictionRefBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    predictionRefBar:GetStatusBarTexture():SetAlpha(0)
    predictionRefBar:SetMinMaxValues(0, 1)
    predictionRefBar:SetValue(0)

    local textFrame = CreateFrame("Frame", nil, resourcePipFrame)
    textFrame:SetAllPoints(resourceBar)
    textFrame:SetFrameLevel(resourceBar:GetFrameLevel() + 2)
    valueText = textFrame:CreateFontString(nil, "OVERLAY")
    valueText:SetPoint("CENTER")
    valueText:Hide()

    predText = textFrame:CreateFontString(nil, "OVERLAY")
    predText:SetPoint("LEFT", resourceBar, "RIGHT", 4, 0)
    predText:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    predText:Hide()

    resourcePipFrame:SetScript("OnSizeChanged", function()
        UpdateTickPositions()
    end)
end

-- POWER DETECTION

local function DetectPowerType()
    local pType, pToken = UnitPowerType("player")
    if issecretvalue(pType) then return end
    currentPowerType = pType
    currentPowerToken = pToken
    local maxP = UnitPowerMax("player", pType)
    if issecretvalue(maxP) then return end
    currentPowerMax = maxP
end

local function GetAutoColor()
    if currentPowerType ~= nil then
        local info = PowerBarColor[currentPowerType]
        if info then return {info.r, info.g, info.b, 1} end
        if currentPowerToken and PowerBarColor[currentPowerToken] then
            info = PowerBarColor[currentPowerToken]
            return {info.r, info.g, info.b, 1}
        end
    end
    return {0.8, 0.8, 0.2, 1}
end

-- TICK MARKS

UpdateTickPositions = function()
    for _, t in ipairs(tickTextures) do t:Hide() end

    local rb = GetRB()
    if not rb.tickMarks or #rb.tickMarks == 0 then return end
    if currentPowerMax <= 0 or not resourceBar then return end

    local barWidth = resourceBar:GetWidth()
    if barWidth <= 0 then return end

    local defaultTc = rb.tickColor or {1, 1, 1, 0.8}
    local tickPx = rb.tickWidth or 1
    local es = resourceBar:GetEffectiveScale()
    if not es or es == 0 then return end
    local onePx = ns.OnePx(es)

    for i, tickData in ipairs(rb.tickMarks) do
        local val, tc
        if type(tickData) == "table" then
            val = tickData.value
            tc = tickData.color or defaultTc
        else
            val = tickData
            tc = defaultTc
        end
        if val and val > 0 and val <= currentPowerMax then
            local tick = tickTextures[i]
            if not tick then
                tick = resourceBar:CreateTexture(nil, "OVERLAY")
                tick:SetSnapToPixelGrid(false)
                tick:SetTexelSnappingBias(0)
                tickTextures[i] = tick
            end
            local xPos = (val / currentPowerMax) * barWidth
            xPos = math.floor(xPos / onePx + 0.5) * onePx
            local w = math.max(onePx * tickPx, onePx)

            tick:ClearAllPoints()
            tick:SetPoint("TOP", resourceBar, "TOPLEFT", xPos, 0)
            tick:SetPoint("BOTTOM", resourceBar, "BOTTOMLEFT", xPos, 0)
            tick:SetWidth(w)
            tick:SetColorTexture(tc[1], tc[2], tc[3], tc[4] or 0.8)
            tick:Show()
        end
    end
end

-- POWER UPDATES

local channelPredActive = false

UpdateResourceBar = function()
    if not resourceBar or currentPowerType == nil then return end
    resourceBar:SetMinMaxValues(0, currentPowerMax)
    -- Forever: secret UnitPower must not reach SetValue/SetText; keep last readable.
    local power = ReadableUnitPower(currentPowerType)
    if power == nil then return end
    resourceBar:SetValue(power)

    -- Sync frozen ref bar when not channeling
    if predictionRefBar and not channelPredActive then
        predictionRefBar:SetMinMaxValues(0, currentPowerMax)
        predictionRefBar:SetValue(power)
    end

    if valueText and valueText:IsShown() then
        valueText:SetText(power)
    end

end

local function UpdateMaxPower()
    if currentPowerType == nil then return end
    local okMax, maxP = pcall(UnitPowerMax, "player", currentPowerType)
    if not okMax or maxP == nil or issecretvalue(maxP) then
        -- Keyed by type, so a form swap cannot leave the new power reading
        -- against the old one's max. Forever: pcall + secret skip like power display.
        maxP = maxPowerByType[currentPowerType]
        if maxP == nil then return end
    else
        maxPowerByType[currentPowerType] = maxP
    end
    currentPowerMax = maxP
    if currentPowerMax == 0 then
        if resourceRowFrame then resourceRowFrame:Hide() end
        return
    end
    -- A zero max earlier in the session hid this, and only a full rebuild
    -- brought it back.
    if resourceRowFrame and GetRB().enabled and not resourceRowFrame:IsShown() then
        resourceRowFrame:Show()
    end
    resourceBar:SetMinMaxValues(0, currentPowerMax)
    UpdateTickPositions()
    UpdateResourceBar()
end

-- PREDICTIVE POWER

local smoothDeltaPx = 0
local lastPredSign = 0

local function HidePredictionVisuals()
    if gainOverlay then gainOverlay:Hide() end
    if costOverlay then costOverlay:Hide() end
    if predText then predText:Hide() end
end

-- Full stop: visuals off AND smoothing forgotten. The per-tick path must use
-- HidePredictionVisuals instead, or the lerp below can never run.
local function ClearPrediction()
    HidePredictionVisuals()
    channelPredActive = false
    smoothDeltaPx = 0
    lastPredSign = 0
end

UpdatePrediction = function()
    local rb = GetRB()
    if not rb.ghostEnabled or not gainOverlay or not resourceBar or currentPowerMax <= 0 then
        ClearPrediction()
        return
    end

    local spellID, totalDurS, isChannel, remainingDurS
    local ok1, cName, _, _, cStartMS, cEndMS, _, _, _, cSpellID = pcall(UnitCastingInfo, "player")
    if ok1 and cName and cStartMS and cEndMS then
        local tok, durOk = pcall(function() return cEndMS > cStartMS end)
        if tok and durOk then
            spellID = cSpellID
            local dok, ds = pcall(function() return (cEndMS - cStartMS) / 1000 end)
            totalDurS = dok and ds or nil
        end
    end

    if not spellID then
        local ok2, chName, _, _, chStartMS, chEndMS, _, _, chSpellID = pcall(UnitChannelInfo, "player")
        if ok2 and chName and chStartMS and chEndMS then
            local tok, durOk = pcall(function() return chEndMS > chStartMS end)
            if tok and durOk then
                spellID = chSpellID
                local dok, ds = pcall(function() return (chEndMS - chStartMS) / 1000 end)
                totalDurS = dok and ds or nil
                isChannel = true
                local nowMS = GetTime() * 1000
                local rok, rs = pcall(function() return math.max(0, chEndMS - nowMS) / 1000 end)
                if rok and rs and rs > 0 then
                    remainingDurS = rs
                end
            end
        end
    end

    if isChannel and not remainingDurS then
        ClearPrediction()
        return
    end

    if not spellID or not totalDurS or totalDurS <= 0 then
        ClearPrediction()
        return
    end

    local barWidth = resourceBar:GetWidth()
    local fillTex = resourceBar:GetStatusBarTexture()
    if barWidth <= 0 or not fillTex then
        ClearPrediction()
        return
    end

    local cost = GetCastSpellCost(spellID)
    local generation = GetSpellGeneration(spellID)

    -- Channel generation: frozen reference bar, engine-driven
    if isChannel and generation > 0 and cost == 0 and predictionRefBar then
        if not channelPredActive then
            predictionRefBar:SetMinMaxValues(0, currentPowerMax)
            local power = ReadableUnitPower(currentPowerType)
            if power == nil then
                ClearPrediction()
                return
            end
            predictionRefBar:SetValue(power)
            local totalGen = generation + GetRegenRate() * totalDurS
            local totalGenPx = totalGen / currentPowerMax * barWidth
            local predRefFillTex = predictionRefBar:GetStatusBarTexture()
            gainOverlay:ClearAllPoints()
            gainOverlay:SetPoint("TOPLEFT", fillTex, "TOPRIGHT", 0, 0)
            gainOverlay:SetPoint("BOTTOMRIGHT", predRefFillTex, "BOTTOMRIGHT", totalGenPx, 0)
            local gc = rb.ghostColor or {1, 1, 1, 0.3}
            gainOverlay:SetColorTexture(gc[1], gc[2], gc[3], gc[4] or 0.3)
            gainOverlay:Show()
            costOverlay:Hide()
            channelPredActive = true
            lastPredSign = 1
            if predText and rb.showPredText then
                local deltaStr = "+" .. string.format("%.0f", totalGen)
                predText:SetText(rb.predTextParens ~= false and ("(" .. deltaStr .. ")") or deltaStr)
                predText:Show()
            end
        end
        return
    end

    HidePredictionVisuals()
    channelPredActive = false

    -- Hardcasts and costs: per-frame smoothed width
    local netDelta
    if cost > 0 then
        netDelta = -cost
    else
        local regen = GetRegenRate() * totalDurS
        netDelta = generation + regen
    end
    if predText and netDelta ~= 0 and rb.showPredText then
        local s = netDelta > 0 and "+" or ""
        local deltaStr = s .. string.format("%.0f", netDelta)
        predText:SetText(rb.predTextParens ~= false and ("(" .. deltaStr .. ")") or deltaStr)
        predText:Show()
    elseif predText then
        predText:Hide()
    end

    local targetPx = math.abs(netDelta) / currentPowerMax * barWidth
    local sign = netDelta > 0 and 1 or (netDelta < 0 and -1 or 0)

    if sign ~= lastPredSign then
        smoothDeltaPx = targetPx
    else
        smoothDeltaPx = smoothDeltaPx + (targetPx - smoothDeltaPx) * 0.15
    end
    lastPredSign = sign

    if smoothDeltaPx < 1 then
        gainOverlay:Hide()
        costOverlay:Hide()
        return
    end

    if sign > 0 then
        gainOverlay:ClearAllPoints()
        gainOverlay:SetPoint("TOPLEFT", fillTex, "TOPRIGHT", 0, 0)
        gainOverlay:SetPoint("BOTTOMLEFT", fillTex, "BOTTOMRIGHT", 0, 0)
        gainOverlay:SetWidth(smoothDeltaPx)
        local gc = rb.ghostColor or {1, 1, 1, 0.3}
        gainOverlay:SetColorTexture(gc[1], gc[2], gc[3], gc[4] or 0.3)
        gainOverlay:Show()
        costOverlay:Hide()
    elseif sign < 0 then
        costOverlay:ClearAllPoints()
        costOverlay:SetPoint("TOPRIGHT", fillTex, "TOPRIGHT", 0, 0)
        costOverlay:SetPoint("BOTTOMRIGHT", fillTex, "BOTTOMRIGHT", 0, 0)
        costOverlay:SetWidth(smoothDeltaPx)
        local cc = rb.costColor or {0.8, 0.2, 0.2, 0.5}
        costOverlay:SetColorTexture(cc[1], cc[2], cc[3], cc[4] or 0.5)
        costOverlay:Show()
        gainOverlay:Hide()
    else
        gainOverlay:Hide()
        costOverlay:Hide()
    end
end

-- EVENT HANDLING

local predElapsed = 0
local function OnPredictionUpdate(self, dt)
    predElapsed = predElapsed + dt
    if predElapsed < 0.033 then return end
    predElapsed = 0
    UpdatePrediction()
end

local function OnEvent(self, event, ...)
    if not GetRB().enabled then return end

    if event == "UNIT_POWER_FREQUENT" then
        if (...) == "player" then
            ObservePowerTick()
            UpdateResourceBar()
        end

    elseif event == "UNIT_MAXPOWER" then
        if (...) == "player" then UpdateMaxPower() end

    elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        -- Deferred: the new scale is not readable from inside the event.
        C_Timer.After(0, function()
            if UpdateTickPositions then UpdateTickPositions() end
        end)

    elseif event == "UNIT_DISPLAYPOWER" then
        DetectPowerType()
        ResetRegenObservation()
        ClearPrediction()
        UpdateMaxPower()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UPDATE_SHAPESHIFT_FORM" then
        ResetRegenObservation()
        ClearPrediction()
        C_Timer.After(0.1, function()
            DetectPowerType()
            local rb = GetRB()
            if rb.enabled and resourceBar then
                local barColor = rb.barColor or GetAutoColor()
                resourceBar:SetStatusBarColor(barColor[1], barColor[2], barColor[3], barColor[4] or 1)
            end
            UpdateMaxPower()
            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
        end)

    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        if (...) == "player" then
            ClearPrediction()
        end

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if (...) == "player" and channelPredActive then
            local ok, name = pcall(UnitChannelInfo, "player")
            if not ok or not name then
                ClearPrediction()
            end
        end

    elseif event == "UNIT_SPELLCAST_STOP" then
        if (...) == "player" then ClearPrediction() end

    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0.5, function()
            DetectPowerType()
            UpdateMaxPower()
        end)
    end
end

-- PUBLIC API

RebuildResourceBar = function()
    CreateResourceBarFrames()

    local rb = GetRB()
    if not rb.enabled then
        if resourceRowFrame then resourceRowFrame:Hide() end
        if eventFrame then
            eventFrame:UnregisterAllEvents()
            eventFrame:SetScript("OnUpdate", nil)
        end
        return
    end

    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end

    if rb.ghostEnabled then
        eventFrame:SetScript("OnUpdate", OnPredictionUpdate)
    else
        eventFrame:SetScript("OnUpdate", nil)
    end
    eventFrame:UnregisterAllEvents()
    eventFrame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
    eventFrame:RegisterUnitEvent("UNIT_MAXPOWER", "player")
    eventFrame:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- The tick marks are snapped to physical pixels, so they go stale when the
    -- scale or the resolution changes. Bars and the icon strip take these too.
    eventFrame:RegisterEvent("UI_SCALE_CHANGED")
    eventFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")

    DetectPowerType()

    local barColor = rb.barColor or GetAutoColor()
    resourceBar:SetStatusBarColor(barColor[1], barColor[2], barColor[3], barColor[4] or 1)

    -- Border thickness counts real pixels, not UI units. A UI unit is bigger than
    -- a pixel on any high resolution display, so the bar inside sat short of its
    -- own frame by the difference on every edge.
    local bs = (rb.borderSize or 1) * ns.OnePxForFrame(resourcePipFrame)
    local bc = rb.borderColor or CONFIG.bordercolor or {0, 0, 0, 1}
    local bTop, bBot, bLeft, bRight = unpack(resourcePipFrame._borders)
    for _, border in ipairs(resourcePipFrame._borders) do
        border:SetColorTexture(bc[1], bc[2], bc[3], bc[4] or 1)
    end
    bTop:SetHeight(bs)
    bBot:SetHeight(bs)
    bLeft:ClearAllPoints()
    bLeft:SetPoint("TOPLEFT", 0, -bs) bLeft:SetPoint("BOTTOMLEFT", 0, bs)
    bLeft:SetWidth(bs)
    bRight:ClearAllPoints()
    bRight:SetPoint("TOPRIGHT", 0, -bs) bRight:SetPoint("BOTTOMRIGHT", 0, bs)
    bRight:SetWidth(bs)

    local bgc = rb.bgColor or {0.08, 0.08, 0.08, 0.8}
    resourcePipFrame._bg:ClearAllPoints()
    resourcePipFrame._bg:SetPoint("TOPLEFT", bs, -bs)
    resourcePipFrame._bg:SetPoint("BOTTOMRIGHT", -bs, bs)
    resourcePipFrame._bg:SetColorTexture(bgc[1], bgc[2], bgc[3], bgc[4] or 0.8)

    resourceBar:ClearAllPoints()
    resourceBar:SetPoint("TOPLEFT", bs, -bs)
    resourceBar:SetPoint("BOTTOMRIGHT", -bs, bs)

    local fontPath = rb.font or CONFIG.font or "Fonts\\FRIZQT__.TTF"
    local fontSize = rb.fontSize or CONFIG.fontSize or 14
    local fontFlags = rb.fontFlags
    if fontFlags == nil then fontFlags = CONFIG.fontFlags or "OUTLINE" end

    if rb.showText then
        valueText:SetFont(fontPath, fontSize, fontFlags)
        local tc = rb.textColor or {1, 1, 1, 1}
        valueText:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)

        valueText:ClearAllPoints()
        local anchor = rb.textAnchor or "CENTER"
        local relPoint = rb.textRelPoint or anchor
        local offX = rb.textOffsetX or 0
        local offY = rb.textOffsetY or 0
        valueText:SetPoint(anchor, resourceBar, relPoint, offX, offY)
        valueText:Show()
    else
        valueText:Hide()
    end

    if rb.showPredText then
        local pFont = rb.predFont or fontPath
        local pSize = rb.predFontSize or fontSize
        local pFlags = rb.predFontFlags
        if pFlags == nil then pFlags = fontFlags end
        predText:SetFont(pFont, pSize, pFlags)

        local pc = rb.predTextColor or {1, 1, 1, 1}
        predText:SetTextColor(pc[1], pc[2], pc[3], pc[4] or 1)

        predText:ClearAllPoints()
        local pAnchor = rb.predTextAnchor or "LEFT"
        local pRelPoint = rb.predTextRelPoint or "RIGHT"
        local pOffX = rb.predTextOffsetX or 2
        local pOffY = rb.predTextOffsetY or 0
        local relFrame
        if rb.predTextRelFrame == "resourceBar" or not rb.showText then
            relFrame = resourceBar
        else
            relFrame = valueText
        end
        predText:SetPoint(pAnchor, relFrame, pRelPoint, pOffX, pOffY)
    else
        predText:Hide()
    end

    UpdateMaxPower()

    if currentPowerMax > 0 then
        resourceRowFrame:Show()
    else
        resourceRowFrame:Hide()
    end
end

function ns.RebuildResourceBar()
    RebuildResourceBar()
end

function ns.GetResourceBarRow()
    local rb = GetRB()
    if not rb.enabled then return nil end
    if not resourceRowFrame or not resourceRowFrame:IsShown() then return nil end

    return {
        frame = resourceRowFrame,
        pips = {resourcePipFrame},
        height = rb.height or 4,
        position = rb.position or "BOTTOM",
        order = rb.order,
        gap = rb.gap or 0,
    }
end


-- SETTINGS TAB BUILDER

function ns.BuildResourceBarTab(contentArea, tabFrames, helpers)
    local CreateCheckbox = helpers.CreateCheckbox
    local CreateSlider = helpers.CreateSlider
    local CreateColorSwatch = helpers.CreateColorSwatch
    local CreateSectionHeader = helpers.CreateSectionHeader
    local CreateScrollableContent = helpers.CreateScrollableContent
    local CreateDropdown = helpers.CreateDropdown
    local GetFontOptions = helpers.GetFontOptions
    local FONT_FLAG_OPTIONS = helpers.FONT_FLAG_OPTIONS
    local ANCHOR_POINTS = helpers.ANCHOR_POINTS

    local tab = CreateFrame("Frame", nil, contentArea)
    tab:SetAllPoints()
    tab:Hide()
    tabFrames[6] = tab

    local _, content = CreateScrollableContent(tab)

    local yOff = 10
    local function AddWidget(widget, gap)
        widget:SetParent(content)
        widget:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -yOff)
        widget:Show()
        yOff = yOff + (widget:GetHeight() or 30) + (gap or 6)
    end

    local function AddHeader(text)
        local h = CreateSectionHeader(content, text)
        h:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -yOff)
        yOff = yOff + 24
    end

    local function AddDescription(text)
        local d = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        d:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -yOff)
        d:SetWidth(500)
        d:SetJustifyH("LEFT")
        d:SetSpacing(2)
        d:SetText(text)
        yOff = yOff + d:GetStringHeight() + 8
    end

    local function AddSpacer(px)
        yOff = yOff + (px or 10)
    end

    if not CONFIG.resourceBar then CONFIG.resourceBar = {} end
    local rb = CONFIG.resourceBar

    local function SaveAndRebuild()
        ns.RebuildResourceBar()
        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
    end

    local enableCB = CreateCheckbox(content, "Enable Resource Bar",
        "Shows a power bar (focus, energy, mana, rage, etc) above or below the timeline frame",
        rb.enabled or false, function(v)
        rb.enabled = v
        SaveAndRebuild()
    end)
    AddWidget(enableCB)

    AddHeader("Appearance")

    local posFrame = CreateFrame("Frame", nil, content)
    posFrame:SetSize(300, 26)
    local posLabel = posFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    posLabel:SetPoint("LEFT", 0, 0)
    posLabel:SetText("Position")

    local posTop = CreateFrame("Button", nil, posFrame, "UIPanelButtonTemplate")
    posTop:SetSize(60, 22)
    posTop:SetPoint("LEFT", posLabel, "RIGHT", 10, 0)
    posTop:SetText("Top")

    local posBot = CreateFrame("Button", nil, posFrame, "UIPanelButtonTemplate")
    posBot:SetSize(60, 22)
    posBot:SetPoint("LEFT", posTop, "RIGHT", 4, 0)
    posBot:SetText("Bottom")

    local function UpdatePosHighlight()
        local pos = rb.position or "BOTTOM"
        posTop:SetEnabled(pos ~= "TOP")
        posBot:SetEnabled(pos ~= "BOTTOM")
    end
    posTop:SetScript("OnClick", function() rb.position = "TOP"; UpdatePosHighlight(); SaveAndRebuild() end)
    posBot:SetScript("OnClick", function() rb.position = "BOTTOM"; UpdatePosHighlight(); SaveAndRebuild() end)
    UpdatePosHighlight()
    AddWidget(posFrame)

    local heightSlider = CreateSlider(content, "Bar Height (px)", 2, 20, 1, rb.height or 4, function(v)
        rb.height = v
        SaveAndRebuild()
    end)
    AddWidget(heightSlider)

    local gapSlider = CreateSlider(content, "Gap From Frame (px)", 0, 10, 1, rb.gap or 0, function(v)
        rb.gap = v
        SaveAndRebuild()
    end)
    AddWidget(gapSlider)

    AddDescription("Everything sharing this edge, drawn nearest the frame first. Stack pips and the icon strip show the same list from their own tabs.")

    local orderCtl
    if ns.CreateEdgeOrderControl then
        orderCtl = ns.CreateEdgeOrderControl(content,
            function() return rb.position or "BOTTOM" end,
            function() return rb.enabled and { kind = "resource" } or nil end,
            SaveAndRebuild)
        AddWidget(orderCtl)
    end
    local function UpdateOrderText()
        if orderCtl then orderCtl.Refresh() end
    end

    DetectPowerType()
    local autoClr = GetAutoColor()
    local barSwatch = CreateColorSwatch(content, "Bar Colour",
        rb.barColor and DeepCopy(rb.barColor) or DeepCopy(autoClr), function(c)
        rb.barColor = {c[1], c[2], c[3], c[4] or 1}
        SaveAndRebuild()
    end)
    AddWidget(barSwatch)

    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(140, 22)
    resetBtn:SetText("Reset to Auto Colour")
    resetBtn:SetScript("OnClick", function()
        rb.barColor = nil
        DetectPowerType()
        barSwatch:SetColor(GetAutoColor())
        SaveAndRebuild()
    end)
    AddWidget(resetBtn)

    local bgSwatch = CreateColorSwatch(content, "Background Colour",
        rb.bgColor and DeepCopy(rb.bgColor) or {0.08, 0.08, 0.08, 0.8}, function(c)
        rb.bgColor = {c[1], c[2], c[3], c[4]}
        SaveAndRebuild()
    end)
    AddWidget(bgSwatch)

    local borderSwatch = CreateColorSwatch(content, "Border Colour",
        rb.borderColor and DeepCopy(rb.borderColor) or DeepCopy(CONFIG.bordercolor or {0, 0, 0, 1}), function(c)
        rb.borderColor = {c[1], c[2], c[3], c[4]}
        SaveAndRebuild()
    end)
    AddWidget(borderSwatch)

    local borderSlider = CreateSlider(content, "Border Size (px)", 0, 4, 1, rb.borderSize or 1, function(v)
        rb.borderSize = v
        SaveAndRebuild()
    end)
    AddWidget(borderSlider)

    AddSpacer(10)
    AddHeader("Predictive Power")
    AddDescription("Shows the cost or gain of your current cast as an overlay on the resource bar.")

    local predCB = CreateCheckbox(content, "Enable Predictive Power", nil,
        rb.ghostEnabled or false, function(v)
        rb.ghostEnabled = v
        SaveAndRebuild()
    end)
    AddWidget(predCB)

    local gainSwatch = CreateColorSwatch(content, "Gain Colour",
        rb.ghostColor and DeepCopy(rb.ghostColor) or {1, 1, 1, 0.3}, function(c)
        rb.ghostColor = {c[1], c[2], c[3], c[4]}
        SaveAndRebuild()
    end)
    AddWidget(gainSwatch)

    local costSwatchWidget = CreateColorSwatch(content, "Cost Colour",
        rb.costColor and DeepCopy(rb.costColor) or {0.8, 0.2, 0.2, 0.5}, function(c)
        rb.costColor = {c[1], c[2], c[3], c[4]}
        SaveAndRebuild()
    end)
    AddWidget(costSwatchWidget)

    if CONFIG.spellGeneration then
        AddSpacer(6)
        local genLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        genLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -yOff)
        genLabel:SetText("Power Generators")
        genLabel:SetTextColor(0.7, 0.7, 0.7)
        yOff = yOff + 16

        AddDescription("Click a value to override it. These are defined in your class config.")
        if not rb.generationOverrides then rb.generationOverrides = {} end

        for spellID, entry in pairs(CONFIG.spellGeneration) do
            local isKnown = IsPlayerSpell and IsPlayerSpell(spellID)
            if isKnown then
            local spellName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) or ("#" .. spellID)
            local total = entry.base or 0
            local parts = {}

            if entry.talents then
                for _, talent in ipairs(entry.talents) do
                    local tName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(talent.spellID) or ("#" .. talent.spellID)
                    local known = IsTalentKnown(talent.spellID)
                    if known then
                        local suffix = ""
                        if talent.requiresAura then
                            local auraName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(talent.requiresAura) or ""
                            suffix = auraName ~= "" and (" during " .. auraName) or ""
                        end
                        total = total + (talent.bonus or 0)
                        parts[#parts + 1] = "|cff55dd55+" .. talent.bonus .. " " .. tName .. suffix .. "|r"
                    else
                        parts[#parts + 1] = "|cff888888+" .. talent.bonus .. " " .. tName .. "|r"
                    end
                end
            end

            local overridden = rb.generationOverrides[spellID]

            local rowFrame = CreateFrame("Frame", nil, content)
            rowFrame:SetSize(490, 18)
            rowFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -yOff)

            local rowText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            rowText:SetPoint("LEFT", 0, 0)
            rowText:SetJustifyH("LEFT")

            local valBtn = CreateFrame("Button", nil, rowFrame)
            valBtn:SetSize(30, 16)
            valBtn:SetPoint("LEFT", rowText, "RIGHT", 4, 0)
            local valText = valBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            valText:SetAllPoints()
            valText:SetJustifyH("LEFT")

            local talentText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            talentText:SetPoint("LEFT", valBtn, "RIGHT", 4, 0)
            talentText:SetJustifyH("LEFT")

            local function UpdateRowText()
                local ov = rb.generationOverrides[spellID]
                local dt = ov or total
                local valColor = ov and "ff88ccff" or "ffffcc00"
                rowText:SetText("|cffffffffo|r  " .. spellName)
                local valStr = "|c" .. valColor .. dt .. "|r"
                if ov then valStr = valStr .. " |cff666666(default " .. total .. ")|r" end
                valText:SetText(valStr)
                if #parts > 0 then
                    talentText:SetText(table.concat(parts, " "))
                    talentText:Show()
                else
                    talentText:Hide()
                end
            end
            UpdateRowText()

            local editBox
            valBtn:SetScript("OnClick", function()
                if editBox then return end
                editBox = CreateFrame("EditBox", nil, rowFrame, "InputBoxTemplate")
                editBox:SetSize(45, 18)
                editBox:SetPoint("LEFT", rowText, "RIGHT", 4, 0)
                editBox:SetAutoFocus(true)
                editBox:SetFontObject("GameFontHighlightSmall")
                editBox:SetText(tostring(rb.generationOverrides[spellID] or total))
                valBtn:Hide()
                talentText:SetPoint("LEFT", editBox, "RIGHT", 4, 0)

                local function Commit()
                    local val = tonumber(editBox:GetText())
                    if val and val ~= total then
                        rb.generationOverrides[spellID] = val
                    else
                        rb.generationOverrides[spellID] = nil
                    end
                    editBox:Hide()
                    editBox = nil
                    valBtn:Show()
                    talentText:SetPoint("LEFT", valBtn, "RIGHT", 4, 0)
                    UpdateRowText()
                    SaveAndRebuild()
                end
                editBox:SetScript("OnEnterPressed", Commit)
                editBox:SetScript("OnEscapePressed", function()
                    editBox:Hide()
                    editBox = nil
                    valBtn:Show()
                    talentText:SetPoint("LEFT", valBtn, "RIGHT", 4, 0)
                end)
            end)

            rowFrame:Show()
            yOff = yOff + 20
        end -- if isKnown
        end -- for spellID
    end

    AddSpacer(10)
    AddHeader("Current Value Text")

    local textCB = CreateCheckbox(content, "Show Current Value",
        "Displays the current power value as text on the resource bar",
        rb.showText or false, function(v)
        rb.showText = v
        SaveAndRebuild()
    end)
    AddWidget(textCB)

    local fontDropdown = CreateDropdown(content, "Font", GetFontOptions(), rb.font, function(v)
        rb.font = v
        SaveAndRebuild()
    end, true, true)
    AddWidget(fontDropdown)

    local fontSizeSlider = CreateSlider(content, "Font Size", 6, 24, 1, rb.fontSize or 14, function(v)
        rb.fontSize = v
        SaveAndRebuild()
    end)
    AddWidget(fontSizeSlider)

    local fontFlagsDropdown = CreateDropdown(content, "Font Flags", FONT_FLAG_OPTIONS, rb.fontFlags, function(v)
        rb.fontFlags = v
        SaveAndRebuild()
    end)
    AddWidget(fontFlagsDropdown)

    local textColorSwatch = CreateColorSwatch(content, "Colour",
        rb.textColor and DeepCopy(rb.textColor) or {1, 1, 1, 1}, function(c)
        rb.textColor = {c[1], c[2], c[3], c[4] or 1}
        SaveAndRebuild()
    end)
    AddWidget(textColorSwatch)

    local anchorDropdown = CreateDropdown(content, "Text Anchor", ANCHOR_POINTS, rb.textAnchor or "CENTER", function(v)
        rb.textAnchor = v
        rb.textRelPoint = v
        SaveAndRebuild()
    end)
    AddWidget(anchorDropdown)

    local offXSlider = CreateSlider(content, "Text Offset X", -50, 50, 1, rb.textOffsetX or 0, function(v)
        rb.textOffsetX = v
        SaveAndRebuild()
    end)
    AddWidget(offXSlider)

    local offYSlider = CreateSlider(content, "Text Offset Y", -50, 50, 1, rb.textOffsetY or 0, function(v)
        rb.textOffsetY = v
        SaveAndRebuild()
    end)
    AddWidget(offYSlider)

    AddSpacer(10)
    AddHeader("Predictive Value Text")
    AddDescription("Shows the predicted power change during casts and channels, IE (+18) or (-35).")

    local predTextCB = CreateCheckbox(content, "Show Predictive Value", nil,
        rb.showPredText or false, function(v)
        rb.showPredText = v
        SaveAndRebuild()
    end)
    AddWidget(predTextCB)

    local predParensCB = CreateCheckbox(content, "Show Parentheses",
        "Wrap the value in parentheses, IE (+18) vs +18",
        rb.predTextParens ~= false, function(v)
        rb.predTextParens = v
        SaveAndRebuild()
    end)
    AddWidget(predParensCB)

    local predFontDropdown = CreateDropdown(content, "Font", GetFontOptions(), rb.predFont, function(v)
        rb.predFont = v
        SaveAndRebuild()
    end, true, true)
    AddWidget(predFontDropdown)

    local predFontSizeSlider = CreateSlider(content, "Font Size", 6, 24, 1, rb.predFontSize or rb.fontSize or 14, function(v)
        rb.predFontSize = v
        SaveAndRebuild()
    end)
    AddWidget(predFontSizeSlider)

    local predFontFlagsDropdown = CreateDropdown(content, "Font Flags", FONT_FLAG_OPTIONS, rb.predFontFlags, function(v)
        rb.predFontFlags = v
        SaveAndRebuild()
    end)
    AddWidget(predFontFlagsDropdown)

    local predColorSwatch = CreateColorSwatch(content, "Colour",
        rb.predTextColor and DeepCopy(rb.predTextColor) or {1, 1, 1, 1}, function(c)
        rb.predTextColor = {c[1], c[2], c[3], c[4] or 1}
        SaveAndRebuild()
    end)
    AddWidget(predColorSwatch)

    local PRED_ANCHOR_TO = {
        {value = "valueText", text = "Current Value Text"},
        {value = "resourceBar", text = "Resource Bar"},
    }
    local predAnchorToDropdown = CreateDropdown(content, "Anchor To", PRED_ANCHOR_TO, rb.predTextRelFrame or "valueText", function(v)
        rb.predTextRelFrame = v
        SaveAndRebuild()
    end)
    AddWidget(predAnchorToDropdown)

    local predRelPointDropdown = CreateDropdown(content, "Relative Point", ANCHOR_POINTS, rb.predTextRelPoint or "RIGHT", function(v)
        rb.predTextRelPoint = v
        SaveAndRebuild()
    end)
    AddWidget(predRelPointDropdown)

    local predAnchorDropdown = CreateDropdown(content, "Text Anchor", ANCHOR_POINTS, rb.predTextAnchor or "LEFT", function(v)
        rb.predTextAnchor = v
        SaveAndRebuild()
    end)
    AddWidget(predAnchorDropdown)

    local predOffXSlider = CreateSlider(content, "Offset X", -50, 50, 1, rb.predTextOffsetX or 2, function(v)
        rb.predTextOffsetX = v
        SaveAndRebuild()
    end)
    AddWidget(predOffXSlider)

    local predOffYSlider = CreateSlider(content, "Offset Y", -50, 50, 1, rb.predTextOffsetY or 0, function(v)
        rb.predTextOffsetY = v
        SaveAndRebuild()
    end)
    AddWidget(predOffYSlider)

    AddSpacer(10)
    AddHeader("Tick Marks")
    AddDescription("Vertical markers at specific power values, IE 35 for Kill Command cost.")

    local tickWidthSlider = CreateSlider(content, "Tick Width (px)", 1, 4, 1, rb.tickWidth or 1, function(v)
        rb.tickWidth = v
        SaveAndRebuild()
    end)
    AddWidget(tickWidthSlider)

    local defaultTickSwatch = CreateColorSwatch(content, "Default Tick Colour",
        rb.tickColor and DeepCopy(rb.tickColor) or {1, 1, 1, 0.8}, function(c)
        rb.tickColor = {c[1], c[2], c[3], c[4]}
        SaveAndRebuild()
    end)
    AddWidget(defaultTickSwatch)

    rb.tickMarks = rb.tickMarks or {}

    local addFrame = CreateFrame("Frame", nil, content)
    addFrame:SetSize(300, 28)
    addFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -yOff)

    local addValueBox = CreateFrame("EditBox", nil, addFrame, "InputBoxTemplate")
    addValueBox:SetSize(55, 20)
    addValueBox:SetPoint("LEFT", 0, 0)
    addValueBox:SetAutoFocus(false)
    addValueBox:SetFontObject("GameFontHighlightSmall")
    addValueBox:SetNumeric(true)

    local addBtn = CreateFrame("Button", nil, addFrame, "UIPanelButtonTemplate")
    addBtn:SetSize(50, 22)
    addBtn:SetPoint("LEFT", addValueBox, "RIGHT", 6, 0)
    addBtn:SetText("Add")

    addFrame:Show()
    yOff = yOff + 32

    local tickListArea = CreateFrame("Frame", nil, content)
    tickListArea:SetSize(500, 1)
    tickListArea:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -yOff)
    local tickListYStart = yOff

    local tickWidgets = {}

    local function RebuildTickList()
        for _, w in ipairs(tickWidgets) do w:Hide() end
        wipe(tickWidgets)
        local ly = 0
        for idx, tickData in ipairs(rb.tickMarks or {}) do
            local val, tc
            if type(tickData) == "table" then
                val = tickData.value
                tc = tickData.color or DeepCopy(rb.tickColor or {1, 1, 1, 0.8})
            else
                val = tickData
                tc = DeepCopy(rb.tickColor or {1, 1, 1, 0.8})
                rb.tickMarks[idx] = {value = val, color = tc}
                tickData = rb.tickMarks[idx]
            end

            local row = CreateFrame("Frame", nil, tickListArea)
            row:SetSize(200, 22)
            row:SetPoint("TOPLEFT", 0, -ly)

            local valStr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            valStr:SetPoint("LEFT", 0, 0)
            valStr:SetText(tostring(val))

            local swatch = CreateFrame("Button", nil, row)
            swatch:SetSize(16, 16)
            swatch:SetPoint("LEFT", 50, 0)
            local swBg = swatch:CreateTexture(nil, "BACKGROUND")
            swBg:SetAllPoints()
            swBg:SetColorTexture(0, 0, 0, 1)
            local swTex = swatch:CreateTexture(nil, "OVERLAY")
            swTex:SetPoint("TOPLEFT", 1, -1)
            swTex:SetPoint("BOTTOMRIGHT", -1, 1)
            swTex:SetColorTexture(tc[1], tc[2], tc[3], tc[4] or 0.8)

            local capturedData = tickData
            swatch:SetScript("OnClick", function()
                local c = capturedData.color or DeepCopy(rb.tickColor or {1, 1, 1, 0.8})
                local prevR, prevG, prevB, prevA = c[1], c[2], c[3], c[4] or 0.8
                ColorPickerFrame:Hide()
                ColorPickerFrame:SetupColorPickerAndShow({
                    r = c[1], g = c[2], b = c[3],
                    opacity = c[4] or 0.8,
                    hasOpacity = true,
                    swatchFunc = function()
                        local r, g, b = ColorPickerFrame:GetColorRGB()
                        c[1], c[2], c[3] = r, g, b
                        capturedData.color = c
                        swTex:SetColorTexture(r, g, b, c[4] or 0.8)
                        SaveAndRebuild()
                    end,
                    opacityFunc = function()
                        c[4] = ColorPickerFrame:GetColorAlpha()
                        capturedData.color = c
                        swTex:SetColorTexture(c[1], c[2], c[3], c[4])
                        SaveAndRebuild()
                    end,
                    cancelFunc = function()
                        c[1], c[2], c[3], c[4] = prevR, prevG, prevB, prevA
                        capturedData.color = c
                        swTex:SetColorTexture(prevR, prevG, prevB, prevA)
                        SaveAndRebuild()
                    end,
                })
            end)

            local capturedIdx = idx
            local removeBtn = ns.CreateRemoveButton(row, "Remove Tick", function()
                table.remove(rb.tickMarks, capturedIdx)
                RebuildTickList()
                SaveAndRebuild()
            end, 18)
            removeBtn:SetPoint("LEFT", 74, 0)

            row:Show()
            tickWidgets[#tickWidgets + 1] = row
            ly = ly + 24
        end
        tickListArea:SetHeight(math.max(ly, 1))
        yOff = tickListYStart + math.max(ly, 1) + 6
        content:SetHeight(yOff + 20)
    end

    addBtn:SetScript("OnClick", function()
        local val = tonumber(addValueBox:GetText())
        if val and val > 0 then
            rb.tickMarks[#rb.tickMarks + 1] = {value = val, color = DeepCopy(rb.tickColor or {1, 1, 1, 0.8})}
            addValueBox:SetText("")
            RebuildTickList()
            SaveAndRebuild()
        end
    end)
    addValueBox:SetScript("OnEnterPressed", function(self)
        addBtn:Click()
    end)

    RebuildTickList()

    local refreshing = false
    local origSaveAndRebuild = SaveAndRebuild
    SaveAndRebuild = function()
        if refreshing then return end
        origSaveAndRebuild()
    end

    -- Restored through a pcall. Every setter in this tab is gated on this flag, so a
    -- throw used to leave it stuck true and the whole tab read only until a reload.
    local function RefreshResourceTabInner()
        rb = CONFIG.resourceBar or {}
        enableCB:SetChecked(rb.enabled or false)
        UpdatePosHighlight()
        heightSlider:SetValue(rb.height or 4)
        gapSlider:SetValue(rb.gap or 0)
        UpdateOrderText()
        DetectPowerType()
        barSwatch:SetColor(rb.barColor and DeepCopy(rb.barColor) or DeepCopy(GetAutoColor()))
        bgSwatch:SetColor(rb.bgColor and DeepCopy(rb.bgColor) or {0.08, 0.08, 0.08, 0.8})
        borderSwatch:SetColor(rb.borderColor and DeepCopy(rb.borderColor) or DeepCopy(CONFIG.bordercolor or {0, 0, 0, 1}))
        borderSlider:SetValue(rb.borderSize or 1)
        predCB:SetChecked(rb.ghostEnabled or false)
        gainSwatch:SetColor(rb.ghostColor and DeepCopy(rb.ghostColor) or {1, 1, 1, 0.3})
        costSwatchWidget:SetColor(rb.costColor and DeepCopy(rb.costColor) or {0.8, 0.2, 0.2, 0.5})
        textCB:SetChecked(rb.showText or false)
        fontDropdown:SetValue(rb.font)
        fontSizeSlider:SetValue(rb.fontSize or 14)
        fontFlagsDropdown:SetValue(rb.fontFlags)
        textColorSwatch:SetColor(rb.textColor and DeepCopy(rb.textColor) or {1, 1, 1, 1})
        anchorDropdown:SetValue(rb.textAnchor or "CENTER")
        offXSlider:SetValue(rb.textOffsetX or 0)
        offYSlider:SetValue(rb.textOffsetY or 0)
        predTextCB:SetChecked(rb.showPredText or false)
        predParensCB:SetChecked(rb.predTextParens ~= false)
        predFontDropdown:SetValue(rb.predFont)
        predFontSizeSlider:SetValue(rb.predFontSize or rb.fontSize or 14)
        predFontFlagsDropdown:SetValue(rb.predFontFlags)
        predColorSwatch:SetColor(rb.predTextColor and DeepCopy(rb.predTextColor) or {1, 1, 1, 1})
        predAnchorToDropdown:SetValue(rb.predTextRelFrame or "valueText")
        predRelPointDropdown:SetValue(rb.predTextRelPoint or "RIGHT")
        predAnchorDropdown:SetValue(rb.predTextAnchor or "LEFT")
        predOffXSlider:SetValue(rb.predTextOffsetX or 2)
        predOffYSlider:SetValue(rb.predTextOffsetY or 0)
        tickWidthSlider:SetValue(rb.tickWidth or 1)
        defaultTickSwatch:SetColor(rb.tickColor and DeepCopy(rb.tickColor) or {1, 1, 1, 0.8})
        RebuildTickList()
    end

    local function RefreshResourceTab()
        local was = refreshing
        refreshing = true
        local ok, err = pcall(RefreshResourceTabInner)
        refreshing = was
        if not ok then
            print("|cff00ff00[Infall]|r The resource settings could not be refreshed. Reload if it looks wrong: " .. tostring(err))
        end
    end

    tab:SetScript("OnShow", RefreshResourceTab)
    ns.RefreshResourceTab = RefreshResourceTab
end
