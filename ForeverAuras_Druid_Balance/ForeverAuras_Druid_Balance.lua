local ADDON_NAME = ...

local _, PLAYER_CLASS = UnitClass("player")
if PLAYER_CLASS ~= "DRUID" then
    return
end

local FA = CreateFrame("Frame")

-- ==========================================================================
-- Forever Auras: Druid - Balance
--
-- Fixed row:
--   Faerie Fire | Moonfire | Insect Swarm
--
-- Rules:
--   * Hostile living target/focus only.
--   * Moonfire / Insect Swarm:
--       > 3 sec remaining = hidden
--       <= 3 sec remaining = icon + decimal countdown
--       missing = icon + native action-button glow
--   * Faerie Fire:
--       hidden until YOU have applied it to that mob
--       duration = 40 sec
--       <= 10 sec remaining = icon + countdown
--       missing after being armed = icon + glow
--       tracking memory = 50 sec from cast (10 sec missing grace)
--   * Nature's Splendor is detected and adds +3 sec Moonfire / +2 sec Insect.
--   * In restricted combat, per-mob state uses nameplate frame identity when
--     UnitGUID becomes secret.
-- ==========================================================================

local ICON_SIZE = 35
local ICON_SPACING = 5
local NORMAL_WARNING = 3.0
local FAERIE_WARNING = 10.0
local FAERIE_MEMORY = 50.0
local UPDATE_RATE = 0.05
local TARGET_MEMORY_TTL = 15 * 60

local NATURES_SPLENDOR_ID = 1223083

local SPELLS = {
    FAERIE_FIRE = {
        name = "Faerie Fire",
        iconID = 770,
        ranks = {
            [770] = 40,
            [778] = 40,
            [9749] = 40,
            [9907] = 40,
        },
    },

    MOONFIRE = {
        name = "Moonfire",
        iconID = 8921,
        ranks = {
            [8921] = 9,
            [8924] = 12,
            [8925] = 12,
            [8926] = 12,
            [8927] = 12,
            [8928] = 12,
            [8929] = 12,
            [9833] = 12,
            [9834] = 12,
            [9835] = 12,
            [26987] = 12,
            [26988] = 12,
        },
    },

    INSECT_SWARM = {
        name = "Insect Swarm",
        iconID = 5570,
        ranks = {
            [5570] = 12,
            [24974] = 12,
            [24975] = 12,
            [24976] = 12,
            [24977] = 12,
        },
    },
}

local SPELL_BY_ID = {}
for key, info in pairs(SPELLS) do
    for spellID, duration in pairs(info.ranks) do
        SPELL_BY_ID[spellID] = {
            key = key,
            duration = duration,
            info = info,
        }
    end
end

local db
local elapsed = 0
local testMode = false
local testUntil = 0
local pendingUnitKey = nil
local targets = {}
local plateKeysByUnit = {}
local warnedNameplates = false

local SECRET_TARGET_KEY = "__FA_DRUID_BALANCE_SECRET_TARGET__"
local SECRET_FOCUS_KEY = "__FA_DRUID_BALANCE_SECRET_FOCUS__"

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff55ffffForever Auras:|r " .. msg)
end

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function GetSpellTextureSafe(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and texture and not IsSecret(texture) then
            return texture
        end
    end
    return 134400
end

local function KnowsSpell(spellID)
    return (IsPlayerSpell and IsPlayerSpell(spellID))
        or (IsSpellKnown and IsSpellKnown(spellID))
end

local function KnowsAny(info)
    for spellID in pairs(info.ranks) do
        if KnowsSpell(spellID) then
            return true
        end
    end
    return false
end

local function HasNaturesSplendor()
    return KnowsSpell(NATURES_SPLENDOR_ID)
end

local function AdjustDuration(key, baseDuration)
    if not HasNaturesSplendor() then
        return baseDuration
    end

    if key == "MOONFIRE" then
        return baseDuration + 3
    elseif key == "INSECT_SWARM" then
        return baseDuration + 2
    end

    return baseDuration
end

local function HostileUnit(unit)
    return UnitExists(unit)
        and UnitCanAttack("player", unit)
        and not UnitIsDeadOrGhost(unit)
end

local function CurrentUnitKey(unit, fallbackKey)
    if not HostileUnit(unit) then
        return nil
    end

    local guid = UnitGUID(unit)

    if guid and not IsSecret(guid) then
        return guid
    end

    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
        if ok and plate then
            return plate
        end
    end

    return fallbackKey
end

local function CurrentTargetKey()
    return CurrentUnitKey("target", SECRET_TARGET_KEY)
end

local function CurrentFocusKey()
    return CurrentUnitKey("focus", SECRET_FOCUS_KEY)
end

local function NameMatchesUnit(name, unit)
    if not name or IsSecret(name) or not UnitExists(unit) then
        return false
    end

    local shortName = UnitName(unit)
    if shortName and not IsSecret(shortName) and name == shortName then
        return true
    end

    if GetUnitName then
        local fullName = GetUnitName(unit, true)
        if fullName and not IsSecret(fullName) and name == fullName then
            return true
        end
    end

    return false
end

local function NewTargetState(key)
    return {
        key = key,
        touched = GetTime(),

        faerie = {
            spellID = nil,
            expiration = nil,
            armedUntil = nil,
        },

        moonfire = {
            spellID = nil,
            expiration = nil,
        },

        insect = {
            spellID = nil,
            expiration = nil,
        },
    }
end

local function StateFor(key, create)
    if not key or IsSecret(key) then
        return nil
    end

    local state = targets[key]

    if not state and create then
        state = NewTargetState(key)
        targets[key] = state
    end

    if state then
        state.touched = GetTime()
    end

    return state
end

-- ==========================================================================
-- UI
-- ==========================================================================

local SLOT_ORDER = { "faerie", "moonfire", "insect" }

local function StartGlow(button)
    if button.faGlowActive then
        return
    end

    button.faGlowActive = true
    if ActionButtonSpellAlertManager then
        ActionButtonSpellAlertManager:ShowAlert(button)
    end
end

local function StopGlow(button)
    if not button.faGlowActive then
        return
    end

    button.faGlowActive = false
    if ActionButtonSpellAlertManager then
        ActionButtonSpellAlertManager:HideAlert(button)
    end
end

local function CreateRow(frameName, labelText, defaultY)
    local row = {}

    row.holder = CreateFrame("Frame", frameName, UIParent)
    row.holder:SetSize((ICON_SIZE * #SLOT_ORDER) + (ICON_SPACING * (#SLOT_ORDER - 1)), ICON_SIZE)
    row.holder:SetFrameStrata("HIGH")
    row.holder:SetMovable(true)
    row.holder:SetClampedToScreen(true)
    row.holder:RegisterForDrag("LeftButton")

    row.moveBG = row.holder:CreateTexture(nil, "BACKGROUND")
    row.moveBG:SetPoint("TOPLEFT", -5, 5)
    row.moveBG:SetPoint("BOTTOMRIGHT", 5, -5)
    row.moveBG:SetColorTexture(0, 0, 0, 0.45)
    row.moveBG:Hide()

    row.moveLabel = row.holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.moveLabel:SetPoint("BOTTOM", row.holder, "TOP", 0, 7)
    row.moveLabel:SetText(labelText)
    row.moveLabel:SetTextColor(1, 0.82, 0)
    row.moveLabel:Hide()

    row.buttons = {}

    for index, key in ipairs(SLOT_ORDER) do
        local button = CreateFrame("Button", nil, row.holder)
        button:SetSize(ICON_SIZE, ICON_SIZE)
        button:EnableMouse(false)

        if index == 1 then
            button:SetPoint("LEFT", row.holder, "LEFT", 0, 0)
        else
            button:SetPoint("LEFT", row.buttons[SLOT_ORDER[index - 1]], "RIGHT", ICON_SPACING, 0)
        end

        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetAllPoints()
        button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        button.time = button:CreateFontString(nil, "OVERLAY")
        local font = GameFontNormal and select(1, GameFontNormal:GetFont())
        button.time:SetFont(font or "Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
        button.time:SetPoint("CENTER", button.icon, "CENTER", 0, 0)
        button.time:SetTextColor(1, 1, 1, 1)

        button:Hide()
        row.buttons[key] = button
    end

    row.defaultY = defaultY
    return row
end

local targetRow = CreateRow("ForeverAurasDruidBalanceTargetFrame", "DRAG: BALANCE TARGET", -80)
local focusRow = CreateRow("ForeverAurasDruidBalanceFocusFrame", "DRAG: BALANCE FOCUS", -125)

local function SaveRowPosition(row, dbKey)
    if not db then return end

    local point, _, relativePoint, x, y = row.holder:GetPoint(1)
    db[dbKey] = {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    }
end

local function RestoreRowPosition(row, dbKey)
    row.holder:ClearAllPoints()

    local pos = db and db[dbKey]
    if pos then
        row.holder:SetPoint(
            pos.point or "CENTER",
            UIParent,
            pos.relativePoint or pos.point or "CENTER",
            pos.x or 0,
            pos.y or row.defaultY
        )
    else
        row.holder:SetPoint("CENTER", UIParent, "CENTER", 0, row.defaultY)
    end
end

local function WireDragging(row, dbKey)
    row.holder:SetScript("OnDragStart", function(self)
        if db and not db.locked then
            self:StartMoving()
        end
    end)

    row.holder:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveRowPosition(row, dbKey)
    end)
end

WireDragging(targetRow, "targetPosition")
WireDragging(focusRow, "focusPosition")

local function ApplyLockState()
    local unlocked = db and not db.locked

    for _, row in ipairs({ targetRow, focusRow }) do
        row.holder:EnableMouse(unlocked)
        row.moveBG:SetShown(unlocked)
        row.moveLabel:SetShown(unlocked)
    end
end

local function HideSlot(row, key)
    local button = row.buttons[key]
    StopGlow(button)
    button:Hide()
end

local function ShowSlot(row, key, spellID, remaining, missing)
    local button = row.buttons[key]
    button.icon:SetTexture(GetSpellTextureSafe(spellID))

    if missing then
        button.time:SetText("")
        StartGlow(button)
    else
        StopGlow(button)
        if remaining and remaining > 0 then
            button.time:SetFormattedText("%.1f", remaining)
        else
            button.time:SetText("")
        end
    end

    button:Show()
end

local function ShowNormalDot(row, key, spellID, expiration, known)
    if not known then
        HideSlot(row, key)
        return
    end

    local now = GetTime()

    if expiration and expiration > now then
        local remaining = expiration - now
        if remaining <= NORMAL_WARNING then
            ShowSlot(row, key, spellID, remaining, false)
        else
            HideSlot(row, key)
        end
    else
        ShowSlot(row, key, spellID, nil, true)
    end
end

local function ShowFaerieFire(row, state)
    local faerie = state and state.faerie
    local now = GetTime()

    if not KnowsAny(SPELLS.FAERIE_FIRE) then
        HideSlot(row, "faerie")
        return
    end

    if not faerie or not faerie.armedUntil or faerie.armedUntil <= now then
        HideSlot(row, "faerie")
        return
    end

    local spellID = faerie.spellID or SPELLS.FAERIE_FIRE.iconID

    if faerie.expiration and faerie.expiration > now then
        local remaining = faerie.expiration - now
        if remaining <= FAERIE_WARNING then
            ShowSlot(row, "faerie", spellID, remaining, false)
        else
            HideSlot(row, "faerie")
        end
    else
        ShowSlot(row, "faerie", spellID, nil, true)
    end
end

local function ShowTest(row)
    ShowSlot(row, "faerie", SPELLS.FAERIE_FIRE.iconID, 8.4, false)
    ShowSlot(row, "moonfire", SPELLS.MOONFIRE.iconID, 1.8, false)
    ShowSlot(row, "insect", SPELLS.INSECT_SWARM.iconID, nil, true)
end

local function RowHasVisibleButton(row)
    for _, key in ipairs(SLOT_ORDER) do
        if row.buttons[key]:IsShown() then
            return true
        end
    end
    return false
end

local function UpdateRow(row, unit, unitKeyFunc)
    if not db or not db.enabled then
        row.holder:Hide()
        return
    end

    if testMode and testUntil > GetTime() then
        row.holder:Show()
        ShowTest(row)
        return
    end

    if not db.locked then
        row.holder:Show()
        ShowTest(row)
        return
    end

    if not HostileUnit(unit) then
        row.holder:Hide()
        return
    end

    local key = unitKeyFunc()
    local state = StateFor(key, true)

    if not state then
        row.holder:Hide()
        return
    end

    row.holder:Show()

    ShowFaerieFire(row, state)

    ShowNormalDot(
        row,
        "moonfire",
        state.moonfire.spellID or SPELLS.MOONFIRE.iconID,
        state.moonfire.expiration,
        KnowsAny(SPELLS.MOONFIRE)
    )

    ShowNormalDot(
        row,
        "insect",
        state.insect.spellID or SPELLS.INSECT_SWARM.iconID,
        state.insect.expiration,
        KnowsAny(SPELLS.INSECT_SWARM)
    )

    if not RowHasVisibleButton(row) then
        row.holder:Hide()
    end
end

local function UpdateDisplay()
    UpdateRow(targetRow, "target", CurrentTargetKey)
    UpdateRow(focusRow, "focus", CurrentFocusKey)
end

-- ==========================================================================
-- Tracking
-- ==========================================================================

local function RecordSpellOnUnit(spellID, unitKey)
    if not unitKey or IsSecret(spellID) then
        return
    end

    local record = SPELL_BY_ID[spellID]
    local spellName

    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and name and not IsSecret(name) then
            spellName = name
        end
    end

    if not record and spellName then
        if spellName == SPELLS.FAERIE_FIRE.name then
            record = { key = "FAERIE_FIRE", duration = 40, info = SPELLS.FAERIE_FIRE }
        elseif spellName == SPELLS.MOONFIRE.name then
            record = { key = "MOONFIRE", duration = 12, info = SPELLS.MOONFIRE }
        elseif spellName == SPELLS.INSECT_SWARM.name then
            record = { key = "INSECT_SWARM", duration = 12, info = SPELLS.INSECT_SWARM }
        end
    end

    if not record then
        return
    end

    local state = StateFor(unitKey, true)
    if not state then
        return
    end

    local now = GetTime()
    local duration = AdjustDuration(record.key, record.duration)
    local expires = now + duration

    if record.key == "FAERIE_FIRE" then
        state.faerie.spellID = spellID
        state.faerie.expiration = expires
        state.faerie.armedUntil = now + FAERIE_MEMORY

    elseif record.key == "MOONFIRE" then
        state.moonfire.spellID = spellID
        state.moonfire.expiration = expires

    elseif record.key == "INSECT_SWARM" then
        state.insect.spellID = spellID
        state.insect.expiration = expires
    end
end

local function MatchAuraToState(state, aura)
    if not aura or IsSecret(aura.name) then
        return
    end

    local name = aura.name
    local expiration = aura.expirationTime
    if IsSecret(expiration) then
        return
    end

    local spellID = aura.spellId
    if IsSecret(spellID) then
        spellID = nil
    end

    if name == SPELLS.FAERIE_FIRE.name then
        state.faerie.spellID = spellID or SPELLS.FAERIE_FIRE.iconID
        state.faerie.expiration = expiration
        state.faerie.armedUntil = expiration + FAERIE_WARNING

    elseif name == SPELLS.MOONFIRE.name then
        state.moonfire.spellID = spellID or SPELLS.MOONFIRE.iconID
        state.moonfire.expiration = expiration

    elseif name == SPELLS.INSECT_SWARM.name then
        state.insect.spellID = spellID or SPELLS.INSECT_SWARM.iconID
        state.insect.expiration = expiration
    end
end

local function ScanUnitOutOfCombat(unit, unitKeyFunc)
    if not HostileUnit(unit) then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return end

    local key = unitKeyFunc()
    local state = StateFor(key, true)
    if not state then return end

    local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, "HARMFUL|PLAYER")
    if not ok or not auras then return end

    state.moonfire.expiration = nil
    state.insect.expiration = nil
    state.faerie.expiration = nil

    for _, aura in ipairs(auras) do
        MatchAuraToState(state, aura)
    end
end

local function ScanTargetOutOfCombat()
    ScanUnitOutOfCombat("target", CurrentTargetKey)
end

local function ScanFocusOutOfCombat()
    ScanUnitOutOfCombat("focus", CurrentFocusKey)
end

local function CleanupOldTargets()
    local now = GetTime()

    for key, state in pairs(targets) do
        if now - (state.touched or now) > TARGET_MEMORY_TTL then
            targets[key] = nil
        end
    end
end

local function CheckNameplates()
    if warnedNameplates then return end

    local value
    if C_CVar and C_CVar.GetCVarInfo then
        local ok, cvarValue = pcall(C_CVar.GetCVarInfo, "nameplateShowEnemies")
        if ok then
            value = cvarValue
        end
    end

    if value == nil and GetCVar then
        local ok, cvarValue = pcall(GetCVar, "nameplateShowEnemies")
        if ok then
            value = cvarValue
        end
    end

    if tostring(value) == "0" then
        warnedNameplates = true
        Print("Warning: enemy nameplates are disabled. Forever Auras uses nameplates to distinguish enemies when GUIDs are restricted, so target-swapping tracking may not work.")
    end
end

-- ==========================================================================
-- Events
-- ==========================================================================

FA:RegisterEvent("ADDON_LOADED")
FA:RegisterEvent("PLAYER_ENTERING_WORLD")
FA:RegisterEvent("PLAYER_TARGET_CHANGED")
FA:RegisterEvent("PLAYER_FOCUS_CHANGED")
FA:RegisterEvent("PLAYER_REGEN_ENABLED")
FA:RegisterEvent("NAME_PLATE_UNIT_ADDED")
FA:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
FA:RegisterUnitEvent("UNIT_AURA", "target", "focus")
FA:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

FA:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end

        ForeverAurasDruidBalanceDB = ForeverAurasDruidBalanceDB or {}
        db = ForeverAurasDruidBalanceDB

        if db.enabled == nil then db.enabled = true end
        if db.locked == nil then db.locked = true end

        RestoreRowPosition(targetRow, "targetPosition")
        RestoreRowPosition(focusRow, "focusPosition")
        ApplyLockState()

        Print("Druid Balance loaded. /fa or /fabalance for commands.")
        return
    end

    if not db then return end

    if event == "PLAYER_ENTERING_WORLD" then
        CheckNameplates()
        ScanTargetOutOfCombat()
        ScanFocusOutOfCombat()
        UpdateDisplay()

    elseif event == "PLAYER_TARGET_CHANGED" then
        targets[SECRET_TARGET_KEY] = nil
        ScanTargetOutOfCombat()
        UpdateDisplay()

    elseif event == "PLAYER_FOCUS_CHANGED" then
        targets[SECRET_FOCUS_KEY] = nil
        ScanFocusOutOfCombat()
        UpdateDisplay()

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local unit = ...

        if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
            local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)

            if ok and plate then
                local oldPlate = plateKeysByUnit[unit]

                if oldPlate and oldPlate ~= plate then
                    targets[oldPlate] = nil
                end

                plateKeysByUnit[unit] = plate
                targets[plate] = nil
            end
        end

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local unit = ...
        local plate = plateKeysByUnit[unit]

        if plate then
            targets[plate] = nil
            plateKeysByUnit[unit] = nil
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        ScanTargetOutOfCombat()
        ScanFocusOutOfCombat()
        CleanupOldTargets()
        UpdateDisplay()

    elseif event == "UNIT_AURA" then
        local unit = ...

        if not InCombatLockdown() then
            if unit == "target" then
                ScanTargetOutOfCombat()
                UpdateDisplay()
            elseif unit == "focus" then
                ScanFocusOutOfCombat()
                UpdateDisplay()
            end
        end

    elseif event == "UNIT_SPELLCAST_SENT" then
        local unit, sentTarget = ...

        if unit == "player" and sentTarget and not IsSecret(sentTarget) then
            local targetMatches = NameMatchesUnit(sentTarget, "target")
            local focusMatches = NameMatchesUnit(sentTarget, "focus")

            if focusMatches and not targetMatches then
                pendingUnitKey = CurrentFocusKey()
            elseif targetMatches then
                pendingUnitKey = CurrentTargetKey()
            end
        end

    elseif event == "UNIT_SPELLCAST_START" then
        local unit = ...

        if unit == "player" and not pendingUnitKey then
            pendingUnitKey = CurrentTargetKey()
        end

    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_INTERRUPTED" then

        local unit = ...

        if unit == "player" then
            pendingUnitKey = nil
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...

        if unit ~= "player" then
            return
        end

        local unitKey = pendingUnitKey or CurrentTargetKey()
        pendingUnitKey = nil

        RecordSpellOnUnit(spellID, unitKey)
        UpdateDisplay()
    end
end)

FA:SetScript("OnUpdate", function(self, dt)
    if not db then return end

    elapsed = elapsed + dt
    if elapsed < UPDATE_RATE then return end
    elapsed = 0

    if testMode and testUntil <= GetTime() then
        testMode = false
    end

    UpdateDisplay()
end)

-- ==========================================================================
-- Commands
-- ==========================================================================

local function HandleSlash(msg)
    if not db then return end

    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "unlock" then
        db.locked = false
        ApplyLockState()
        UpdateDisplay()
        Print("unlocked. Drag TARGET and FOCUS rows, then /fa lock.")

    elseif msg == "lock" then
        db.locked = true
        SaveRowPosition(targetRow, "targetPosition")
        SaveRowPosition(focusRow, "focusPosition")
        ApplyLockState()
        UpdateDisplay()
        Print("locked.")

    elseif msg == "test" then
        testMode = true
        testUntil = GetTime() + 10
        UpdateDisplay()
        Print("10-second test: Faerie Fire 8.4, Moonfire 1.8, Insect Swarm missing/glow.")

    elseif msg == "reset" then
        db.targetPosition = nil
        db.focusPosition = nil
        RestoreRowPosition(targetRow, "targetPosition")
        RestoreRowPosition(focusRow, "focusPosition")
        SaveRowPosition(targetRow, "targetPosition")
        SaveRowPosition(focusRow, "focusPosition")
        UpdateDisplay()
        Print("target and focus positions reset.")

    elseif msg == "on" then
        db.enabled = true
        UpdateDisplay()
        Print("enabled.")

    elseif msg == "off" then
        db.enabled = false
        UpdateDisplay()
        Print("disabled.")

    elseif msg == "clear" then
        targets = {}
        UpdateDisplay()
        Print("target memory cleared.")

    elseif msg == "status" then
        Print(
            "enabled=" .. (db.enabled and "YES" or "NO")
            .. ", locked=" .. (db.locked and "YES" or "NO")
            .. ", normal warning=3.0s"
            .. ", Faerie Fire warning=10.0s"
            .. ", Nature's Splendor=" .. (HasNaturesSplendor() and "YES" or "NO") .. "."
        )

    else
        Print("commands: /fa test, unlock, lock, reset, on, off, clear, status")
    end
end

SLASH_FOREVERAURASDRUIDBALANCE1 = "/fa"
SLASH_FOREVERAURASDRUIDBALANCE2 = "/fabalance"
SlashCmdList.FOREVERAURASDRUIDBALANCE = HandleSlash
