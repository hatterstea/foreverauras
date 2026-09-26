local ADDON_NAME = ...

-- Class-module guard. All Forever Auras modules can coexist.
local _, PLAYER_CLASS = UnitClass("player")
if PLAYER_CLASS ~= "WARLOCK" then
    return
end

local FA = CreateFrame("Frame")

-- ============================================================================
-- Forever Auras: Warlock
-- Base build v0.1.0
--
-- Row:
--   Curse | Bane | Corruption | Siphon Life | Immolate
--
-- Rules:
--   * Only displays for a hostile living target.
--   * Ordinary DoTs:
--       > 3.0 sec remaining = hidden
--       <= 3.0 sec remaining = icon + countdown, NO glow
--       absent               = icon + glow
--   * Bane is ONE slot:
--       Bane of Agony / Bane of Doom / Bane of Havoc are mutually exclusive.
--       Whichever one you last applied to this target owns the slot.
--       Fresh targets default to Bane of Agony.
--   * Curse is special:
--       hidden until you cast Recklessness or Elements on THIS target.
--       Recklessness tracking window = 2:30 from cast.
--       Elements tracking window     = 5:30 from cast.
--       warning threshold            = 5 sec.
--   * Immolate is special:
--       hidden until you cast it on THIS target.
--       remembered for 30 sec from cast.
--       warning threshold = 3 sec.
--
-- This base build intentionally caches YOUR successful casts per target GUID.
-- That makes another Warlock's DoTs irrelevant. An out-of-combat aura scan is
-- also used when possible to resync the real aura state.
--
-- IMPORTANT:
-- Forever can protect aura identity/timing during combat. This build gives us
-- the UI and behavior to test now. If beta testing exposes a case where an aura
-- is refreshed/removed without a corresponding player cast, the tracking layer
-- can be replaced with Blizzard's secure AuraContainer backend without changing
-- the presentation code below.
-- ============================================================================

-- Easy knobs Ally can edit.
local ICON_SIZE = 35
local ICON_SPACING = 5
local NORMAL_WARNING = 3.0
local CURSE_WARNING = 5.0
local IMMOLATE_MEMORY = 30.0
local UPDATE_RATE = 0.05
local TARGET_MEMORY_TTL = 15 * 60

-- Spell IDs / rank durations used by Forever's Classic-derived spellbook.
local SPELLS = {
    BANE_AGONY = {
        name = "Bane of Agony",
        iconID = 980,
        ranks = {
            [980] = 24, [1014] = 24, [6217] = 24,
            [11711] = 24, [11712] = 24, [11713] = 24,
        },
    },

    BANE_DOOM = {
        name = "Bane of Doom",
        iconID = 603,
        ranks = {
            [603] = 60,
        },
    },

    BANE_HAVOC = {
        name = "Bane of Havoc",
        iconID = 1225228,
        ranks = {
            [1225228] = 300,
        },
    },

    CORRUPTION = {
        name = "Corruption",
        iconID = 172,
        ranks = {
            [172] = 12,
            [6222] = 15,
            [6223] = 18,
            [7648] = 18,
            [11671] = 18,
            [11672] = 18,
        },
    },

    SIPHON = {
        name = "Siphon Life",
        iconID = 18265,
        ranks = {
            [18265] = 30,
            [18879] = 30,
            [18880] = 30,
            [18881] = 30,
        },
    },

    IMMOLATE = {
        name = "Immolate",
        iconID = 348,
        ranks = {
            [348] = 15, [707] = 15, [1094] = 15, [2941] = 15,
            [11665] = 15, [11667] = 15, [11668] = 15,
        },
    },

    RECKLESSNESS = {
        name = "Curse of Recklessness",
        iconID = 704,
        ranks = {
            [704] = 120, [7658] = 120, [7659] = 120, [11717] = 120,
            -- Forever also has server/custom copies; name fallback catches them.
            [1225841] = 120,
        },
        memory = 150, -- 2:30
    },

    ELEMENTS = {
        name = "Curse of the Elements",
        iconID = 1490,
        ranks = {
            [1490] = 300, [11721] = 300, [11722] = 300,
        },
        memory = 330, -- 5:30
    },
}

-- Build quick lookup by spell ID.
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
local testUntil = 0
local testMode = false
local pendingTargetKey = nil
local targets = {}
local plateKeysByUnit = {}

local SECRET_TARGET_KEY = "__FA_SECRET_TARGET__"

local SECRET_FOCUS_KEY = "__FA_SECRET_FOCUS__"

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff55ffffForever Auras:|r " .. msg)
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function GetSpellTextureSafe(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and tex then return tex end
    end
    return 134400
end

local function KnowsAny(info)
    for spellID in pairs(info.ranks) do
        if (IsPlayerSpell and IsPlayerSpell(spellID))
            or (IsSpellKnown and IsSpellKnown(spellID)) then
            return true
        end
    end
    return false
end

local function HostileTarget()
    return UnitExists("target")
        and UnitCanAttack("player", "target")
        and not UnitIsDeadOrGhost("target")
end

local function CurrentUnitKey(unit, fallbackKey)
    local guid = UnitGUID(unit)

    -- Outside restricted content, keep using the real GUID.
    if guid and not IsSecret(guid) then
        return guid
    end

    -- In restricted content, use the mob's nameplate frame instead.
    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)

        if ok and plate then
            return plate
        end
    end

    -- Last resort if the mob somehow has no usable nameplate.
    return fallbackKey
end

local function CurrentTargetGUID()
    if not HostileTarget() then
        return nil
    end

    return CurrentUnitKey("target", SECRET_TARGET_KEY)
end

local function HostileFocus()
    return UnitExists("focus")
        and UnitCanAttack("player", "focus")
        and not UnitIsDeadOrGhost("focus")
end

local function CurrentFocusGUID()
    if not HostileFocus() then
        return nil
    end

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

local function NewTargetState(guid)
    local now = GetTime()
    return {
        guid = guid,
        touched = now,

        bane = {
            spellKey = nil,
            spellID = nil,
            expiration = nil,
        },

        corruption = {
            spellID = nil,
            expiration = nil,
        },

        siphon = {
            spellID = nil,
            expiration = nil,
        },

        immolate = {
            spellID = nil,
            expiration = nil,
            armedUntil = nil,
        },

        curse = {
            spellKey = nil,
            spellID = nil,
            expiration = nil,
            armedUntil = nil,
        },
    }
end

local function StateFor(guid, create)
    if not guid then
        return nil
    end

    -- Never allow a Blizzard secret to become a Lua table key.
    if IsSecret(guid) then
        return nil
    end

    local state = targets[guid]

    if not state and create then
        state = NewTargetState(guid)
        targets[guid] = state
    end

    if state then
        state.touched = GetTime()
    end

    return state
end

-- ============================================================================
-- UI
-- ============================================================================

local holder = CreateFrame("Frame", "ForeverAurasWarlockFrame", UIParent)
holder:SetSize((ICON_SIZE * 5) + (ICON_SPACING * 4), ICON_SIZE)
holder:SetFrameStrata("HIGH")
holder:SetMovable(true)
holder:SetClampedToScreen(true)
holder:RegisterForDrag("LeftButton")

local moveBG = holder:CreateTexture(nil, "BACKGROUND")
moveBG:SetPoint("TOPLEFT", -5, 5)
moveBG:SetPoint("BOTTOMRIGHT", 5, -5)
moveBG:SetColorTexture(0, 0, 0, 0.45)
moveBG:Hide()

local moveLabel = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
moveLabel:SetPoint("BOTTOM", holder, "TOP", 0, 7)
moveLabel:SetText("DRAG: FOREVER AURAS - WARLOCK")
moveLabel:SetTextColor(1, 0.82, 0)
moveLabel:Hide()

local SLOT_ORDER = { "curse", "bane", "corruption", "siphon", "immolate" }
local buttons = {}

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

local function CreateSlot(index, key)
    local b = CreateFrame("Button", nil, holder)
    b:SetSize(ICON_SIZE, ICON_SIZE)
    b:EnableMouse(false)

    if index == 1 then
        b:SetPoint("LEFT", holder, "LEFT", 0, 0)
    else
        b:SetPoint("LEFT", buttons[SLOT_ORDER[index - 1]], "RIGHT", ICON_SPACING, 0)
    end

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.time = b:CreateFontString(nil, "OVERLAY")

    local font = GameFontNormal and select(1, GameFontNormal:GetFont())

    b.time:SetFont(
        font or "Fonts\\FRIZQT__.TTF",
        14,
        "OUTLINE"
    )

    b.time:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
    b.time:SetTextColor(1, 1, 1, 1)

    b:Hide()
    buttons[key] = b
end

for i, key in ipairs(SLOT_ORDER) do
    CreateSlot(i, key)
end

local focusHolder = CreateFrame("Frame", "ForeverAurasWarlockFocusFrame", UIParent)
focusHolder:SetSize((ICON_SIZE * 5) + (ICON_SPACING * 4), ICON_SIZE)
focusHolder:SetFrameStrata("HIGH")
focusHolder:SetMovable(true)
focusHolder:SetClampedToScreen(true)
focusHolder:RegisterForDrag("LeftButton")

local focusMoveBG = focusHolder:CreateTexture(nil, "BACKGROUND")
focusMoveBG:SetPoint("TOPLEFT", -5, 5)
focusMoveBG:SetPoint("BOTTOMRIGHT", 5, -5)
focusMoveBG:SetColorTexture(0, 0, 0, 0.45)
focusMoveBG:Hide()

local focusMoveLabel = focusHolder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
focusMoveLabel:SetPoint("BOTTOM", focusHolder, "TOP", 0, 7)
focusMoveLabel:SetText("DRAG: FOCUS")
focusMoveLabel:SetTextColor(1, 0.82, 0)
focusMoveLabel:Hide()

local focusButtons = {}

local function CreateFocusSlot(index, key)
    local b = CreateFrame("Button", nil, focusHolder)
    b:SetSize(ICON_SIZE, ICON_SIZE)
    b:EnableMouse(false)

    if index == 1 then
        b:SetPoint("LEFT", focusHolder, "LEFT", 0, 0)
    else
        b:SetPoint(
            "LEFT",
            focusButtons[SLOT_ORDER[index - 1]],
            "RIGHT",
            ICON_SPACING,
            0
        )
    end

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.time = b:CreateFontString(nil, "OVERLAY")

    local font = GameFontNormal and select(1, GameFontNormal:GetFont())

    b.time:SetFont(
        font or "Fonts\\FRIZQT__.TTF",
        14,
        "OUTLINE"
    )

    b.time:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
    b.time:SetTextColor(1, 1, 1, 1)

    b:Hide()
    focusButtons[key] = b
end

for i, key in ipairs(SLOT_ORDER) do
    CreateFocusSlot(i, key)
end

local function SaveFocusPosition()
    if not db then return end

    local point, _, relativePoint, x, y = focusHolder:GetPoint(1)

    db.focusPosition = {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    }
end

local function RestoreFocusPosition()
    focusHolder:ClearAllPoints()

    if db and db.focusPosition then
        focusHolder:SetPoint(
            db.focusPosition.point or "CENTER",
            UIParent,
            db.focusPosition.relativePoint or db.focusPosition.point or "CENTER",
            db.focusPosition.x or 0,
            db.focusPosition.y or -125
        )
    else
        focusHolder:SetPoint("CENTER", UIParent, "CENTER", 0, -125)
    end
end

focusHolder:SetScript("OnDragStart", function(self)
    if db and not db.locked then
        self:StartMoving()
    end
end)

focusHolder:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveFocusPosition()
end)

local function SavePosition()
    if not db then return end
    local point, _, relativePoint, x, y = holder:GetPoint(1)
    db.position = {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    }
end

local function RestorePosition()
    holder:ClearAllPoints()
    if db and db.position then
        holder:SetPoint(
            db.position.point or "CENTER",
            UIParent,
            db.position.relativePoint or db.position.point or "CENTER",
            db.position.x or 0,
            db.position.y or -80
        )
    else
        holder:SetPoint("CENTER", UIParent, "CENTER", 0, -80)
    end
end

holder:SetScript("OnDragStart", function(self)
    if db and not db.locked then
        self:StartMoving()
    end
end)

holder:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition()
end)

local function ApplyLockState()
    local unlocked = db and not db.locked

    holder:EnableMouse(unlocked)
    moveBG:SetShown(unlocked)
    moveLabel:SetShown(unlocked)

    focusHolder:EnableMouse(unlocked)
    focusMoveBG:SetShown(unlocked)
    focusMoveLabel:SetShown(unlocked)
end

--[[ taken out of the single frame to add focus functionality.
local function HideSlot(key)
    local b = buttons[key]
    StopGlow(b)
    b:Hide()
end

local function ShowSlot(key, spellID, remaining, missing)
    local b = buttons[key]
    b.icon:SetTexture(GetSpellTextureSafe(spellID))

    if missing then
        b.time:SetText("")
        StartGlow(b)
    else
        StopGlow(b)
        if remaining and remaining > 0 then
            b.time:SetFormattedText("%.1f", remaining)
        else
            b.time:SetText("")
        end
    end

    b:Show()
end

-- ============================================================================
-- Presentation logic
-- ============================================================================

local function ShowNormalDot(key, spellID, expiration, known)
    if not known then
        HideSlot(key)
        return
    end

    local now = GetTime()

    if expiration and expiration > now then
        local remaining = expiration - now
        if remaining <= NORMAL_WARNING then
            ShowSlot(key, spellID, remaining, false)
        else
            HideSlot(key)
        end
    else
        ShowSlot(key, spellID, nil, true)
    end
end

local function ShowBane(state)
    if not KnowsAny(SPELLS.BANE_AGONY)
        and not KnowsAny(SPELLS.BANE_DOOM)
        and not KnowsAny(SPELLS.BANE_HAVOC) then
        HideSlot("bane")
        return
    end

    local bane = state and state.bane
    local spellID = SPELLS.BANE_AGONY.iconID

    if bane and bane.spellID then
        spellID = bane.spellID
    end

    local expiration = bane and bane.expiration
    local now = GetTime()

    if expiration and expiration > now then
        local remaining = expiration - now
        if remaining <= NORMAL_WARNING then
            ShowSlot("bane", spellID, remaining, false)
        else
            HideSlot("bane")
        end
    else
        -- Fresh target: default missing Bane is Agony.
        ShowSlot("bane", spellID, nil, true)
    end
end

local function ShowCurse(state)
    local curse = state and state.curse
    local now = GetTime()

    if not curse or not curse.armedUntil or curse.armedUntil <= now then
        HideSlot("curse")
        return
    end

    local spellID = curse.spellID
    if not spellID then
        HideSlot("curse")
        return
    end

    if curse.expiration and curse.expiration > now then
        local remaining = curse.expiration - now
        if remaining <= CURSE_WARNING then
            ShowSlot("curse", spellID, remaining, false)
        else
            HideSlot("curse")
        end
    else
        ShowSlot("curse", spellID, nil, true)
    end
end

local function ShowImmolate(state)
    local imm = state and state.immolate
    local now = GetTime()

    if not imm or not imm.armedUntil or imm.armedUntil <= now then
        HideSlot("immolate")
        return
    end

    local spellID = imm.spellID or SPELLS.IMMOLATE.iconID

    if imm.expiration and imm.expiration > now then
        local remaining = imm.expiration - now
        if remaining <= NORMAL_WARNING then
            ShowSlot("immolate", spellID, remaining, false)
        else
            HideSlot("immolate")
        end
    else
        ShowSlot("immolate", spellID, nil, true)
    end
end

local function ShowTest()
    -- Test pattern demonstrates every important visual state.
    ShowSlot("curse", SPELLS.RECKLESSNESS.iconID, 4.2, false)
    ShowSlot("bane", SPELLS.BANE_AGONY.iconID, nil, true)
    ShowSlot("corruption", SPELLS.CORRUPTION.iconID, 1.6, false)
    ShowSlot("siphon", SPELLS.SIPHON.iconID, nil, true)
    ShowSlot("immolate", SPELLS.IMMOLATE.iconID, 2.4, false)
end
]]--

local function HideSlot(key, buttonSet)
    buttonSet = buttonSet or buttons

    local b = buttonSet[key]
    StopGlow(b)
    b:Hide()
end

local function ShowSlot(key, spellID, remaining, missing, buttonSet)
    buttonSet = buttonSet or buttons

    local b = buttonSet[key]
    b.icon:SetTexture(GetSpellTextureSafe(spellID))

    if missing then
        b.time:SetText("")
        StartGlow(b)
    else
        StopGlow(b)

        if remaining and remaining > 0 then
            b.time:SetFormattedText("%.1f", remaining)
        else
            b.time:SetText("")
        end
    end

    b:Show()
end

local function ShowNormalDot(key, spellID, expiration, known, buttonSet)
    if not known then
        HideSlot(key, buttonSet)
        return
    end

    local now = GetTime()

    if expiration and expiration > now then
        local remaining = expiration - now

        if remaining <= NORMAL_WARNING then
            ShowSlot(key, spellID, remaining, false, buttonSet)
        else
            HideSlot(key, buttonSet)
        end
    else
        ShowSlot(key, spellID, nil, true, buttonSet)
    end
end

local function ShowBane(state, buttonSet)
    if not KnowsAny(SPELLS.BANE_AGONY)
        and not KnowsAny(SPELLS.BANE_DOOM)
        and not KnowsAny(SPELLS.BANE_HAVOC) then

        HideSlot("bane", buttonSet)
        return
    end

    local bane = state and state.bane
    local spellID = SPELLS.BANE_AGONY.iconID

    if bane and bane.spellID then
        spellID = bane.spellID
    end

    local expiration = bane and bane.expiration
    local now = GetTime()

    if expiration and expiration > now then
        local remaining = expiration - now

        if remaining <= NORMAL_WARNING then
            ShowSlot("bane", spellID, remaining, false, buttonSet)
        else
            HideSlot("bane", buttonSet)
        end
    else
        ShowSlot("bane", spellID, nil, true, buttonSet)
    end
end

local function ShowCurse(state, buttonSet)
    local curse = state and state.curse
    local now = GetTime()

    if not curse
        or not curse.armedUntil
        or curse.armedUntil <= now then

        HideSlot("curse", buttonSet)
        return
    end

    local spellID = curse.spellID

    if not spellID then
        HideSlot("curse", buttonSet)
        return
    end

    if curse.expiration and curse.expiration > now then
        local remaining = curse.expiration - now

        if remaining <= CURSE_WARNING then
            ShowSlot("curse", spellID, remaining, false, buttonSet)
        else
            HideSlot("curse", buttonSet)
        end
    else
        ShowSlot("curse", spellID, nil, true, buttonSet)
    end
end

local function ShowImmolate(state, buttonSet)
    local imm = state and state.immolate
    local now = GetTime()

    if not imm
        or not imm.armedUntil
        or imm.armedUntil <= now then

        HideSlot("immolate", buttonSet)
        return
    end

    local spellID = imm.spellID or SPELLS.IMMOLATE.iconID

    if imm.expiration and imm.expiration > now then
        local remaining = imm.expiration - now

        if remaining <= NORMAL_WARNING then
            ShowSlot("immolate", spellID, remaining, false, buttonSet)
        else
            HideSlot("immolate", buttonSet)
        end
    else
        ShowSlot("immolate", spellID, nil, true, buttonSet)
    end
end

local function ShowTest(buttonSet)
    ShowSlot("curse", SPELLS.RECKLESSNESS.iconID, 4.2, false, buttonSet)
    ShowSlot("bane", SPELLS.BANE_AGONY.iconID, nil, true, buttonSet)
    ShowSlot("corruption", SPELLS.CORRUPTION.iconID, 1.6, false, buttonSet)
    ShowSlot("siphon", SPELLS.SIPHON.iconID, nil, true, buttonSet)
    ShowSlot("immolate", SPELLS.IMMOLATE.iconID, 2.4, false, buttonSet)
end

local function UpdateTargetDisplay()
    if not db or not db.enabled then
        holder:Hide()
        return
    end

    if testMode and testUntil > GetTime() then
        holder:Show()
        ShowTest()
        return
    end

    if db and not db.locked then
        holder:Show()
        ShowTest()
        return
    end

    if not HostileTarget() then
        holder:Hide()
        return
    end

    local guid = CurrentTargetGUID()
    local state = StateFor(guid, true)
    if not state then
        holder:Hide()
        return
    end

    holder:Show()

    ShowCurse(state)
    ShowBane(state)

    ShowNormalDot(
        "corruption",
        (state.corruption.spellID or SPELLS.CORRUPTION.iconID),
        state.corruption.expiration,
        KnowsAny(SPELLS.CORRUPTION)
    )

    ShowNormalDot(
        "siphon",
        (state.siphon.spellID or SPELLS.SIPHON.iconID),
        state.siphon.expiration,
        KnowsAny(SPELLS.SIPHON)
    )

    ShowImmolate(state)

    -- If all five children are hidden, hide the holder too.
    local any = false
    for _, key in ipairs(SLOT_ORDER) do
        if buttons[key]:IsShown() then
            any = true
            break
        end
    end
    if not any then
        holder:Hide()
    end
end

local function UpdateFocusDisplay()
    if not db or not db.enabled then
        focusHolder:Hide()
        return
    end

    if testMode and testUntil > GetTime() then
        focusHolder:Show()
        ShowTest(focusButtons)
        return
    end

    if db and not db.locked then
        focusHolder:Show()
        ShowTest(focusButtons)
        return
    end

    if not HostileFocus() then
        focusHolder:Hide()
        return
    end

    local guid = CurrentFocusGUID()
    local state = StateFor(guid, true)

    if not state then
        focusHolder:Hide()
        return
    end

    focusHolder:Show()

    ShowCurse(state, focusButtons)
    ShowBane(state, focusButtons)

    ShowNormalDot(
        "corruption",
        (state.corruption.spellID or SPELLS.CORRUPTION.iconID),
        state.corruption.expiration,
        KnowsAny(SPELLS.CORRUPTION),
        focusButtons
    )

    ShowNormalDot(
        "siphon",
        (state.siphon.spellID or SPELLS.SIPHON.iconID),
        state.siphon.expiration,
        KnowsAny(SPELLS.SIPHON),
        focusButtons
    )

    ShowImmolate(state, focusButtons)

    local any = false

    for _, key in ipairs(SLOT_ORDER) do
        if focusButtons[key]:IsShown() then
            any = true
            break
        end
    end

    if not any then
        focusHolder:Hide()
    end
end

local function UpdateDisplay()
    UpdateTargetDisplay()
    UpdateFocusDisplay()
end

-- ============================================================================
-- Tracking
-- ============================================================================

local function ClearHavocFromOtherTargets(currentGUID)
    for guid, state in pairs(targets) do
        if guid ~= currentGUID and state.bane.spellKey == "BANE_HAVOC" then
            state.bane.spellKey = nil
            state.bane.spellID = nil
            state.bane.expiration = nil
        end
    end
end

local function RecordSpellOnTarget(spellID, targetGUID)
    if not targetGUID or IsSecret(spellID) then return end

    local record = SPELL_BY_ID[spellID]
    local spellName

    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and not IsSecret(name) then spellName = name end
    end

    -- Name fallback catches Forever custom copies/ranks whose ID we haven't
    -- explicitly listed yet.
    if not record and spellName then
        if spellName == SPELLS.BANE_AGONY.name then
            record = { key = "BANE_AGONY", duration = 24, info = SPELLS.BANE_AGONY }
        elseif spellName == SPELLS.BANE_DOOM.name then
            record = { key = "BANE_DOOM", duration = 60, info = SPELLS.BANE_DOOM }
        elseif spellName == SPELLS.BANE_HAVOC.name then
            record = { key = "BANE_HAVOC", duration = 300, info = SPELLS.BANE_HAVOC }
        elseif spellName == SPELLS.CORRUPTION.name then
            record = { key = "CORRUPTION", duration = 18, info = SPELLS.CORRUPTION }
        elseif spellName == SPELLS.SIPHON.name then
            record = { key = "SIPHON", duration = 30, info = SPELLS.SIPHON }
        elseif spellName == SPELLS.IMMOLATE.name then
            record = { key = "IMMOLATE", duration = 15, info = SPELLS.IMMOLATE }
        elseif spellName == SPELLS.RECKLESSNESS.name then
            record = { key = "RECKLESSNESS", duration = 120, info = SPELLS.RECKLESSNESS }
        elseif spellName == SPELLS.ELEMENTS.name or spellName == "Curse of Elements" then
            record = { key = "ELEMENTS", duration = 300, info = SPELLS.ELEMENTS }
        end
    end

    if not record then return end

    local state = StateFor(targetGUID, true)
    if not state then return end

    local now = GetTime()
    local expires = now + record.duration

    if record.key == "BANE_AGONY"
        or record.key == "BANE_DOOM"
        or record.key == "BANE_HAVOC" then

        state.bane.spellKey = record.key
        state.bane.spellID = spellID
        state.bane.expiration = expires

        if record.key == "BANE_HAVOC" then
            ClearHavocFromOtherTargets(targetGUID)
        end

    elseif record.key == "CORRUPTION" then
        state.corruption.spellID = spellID
        state.corruption.expiration = expires

    elseif record.key == "SIPHON" then
        state.siphon.spellID = spellID
        state.siphon.expiration = expires

    elseif record.key == "IMMOLATE" then
        state.immolate.spellID = spellID
        state.immolate.expiration = expires
        state.immolate.armedUntil = now + IMMOLATE_MEMORY

    elseif record.key == "RECKLESSNESS" or record.key == "ELEMENTS" then
        state.curse.spellKey = record.key
        state.curse.spellID = spellID
        state.curse.expiration = expires
        state.curse.armedUntil = now + record.info.memory
    end
end

local function MatchAuraToState(state, aura)
    if not aura or IsSecret(aura.name) then return end

    local name = aura.name
    local expiration = aura.expirationTime
    if IsSecret(expiration) then return end

    local spellID = aura.spellId
    if IsSecret(spellID) then spellID = nil end

    if name == SPELLS.BANE_AGONY.name then
        state.bane.spellKey = "BANE_AGONY"
        state.bane.spellID = spellID or SPELLS.BANE_AGONY.iconID
        state.bane.expiration = expiration

    elseif name == SPELLS.BANE_DOOM.name then
        state.bane.spellKey = "BANE_DOOM"
        state.bane.spellID = spellID or SPELLS.BANE_DOOM.iconID
        state.bane.expiration = expiration

    elseif name == SPELLS.BANE_HAVOC.name then
        state.bane.spellKey = "BANE_HAVOC"
        state.bane.spellID = spellID or SPELLS.BANE_HAVOC.iconID
        state.bane.expiration = expiration

    elseif name == SPELLS.CORRUPTION.name then
        state.corruption.spellID = spellID or SPELLS.CORRUPTION.iconID
        state.corruption.expiration = expiration

    elseif name == SPELLS.SIPHON.name then
        state.siphon.spellID = spellID or SPELLS.SIPHON.iconID
        state.siphon.expiration = expiration

    elseif name == SPELLS.IMMOLATE.name then
        state.immolate.spellID = spellID or SPELLS.IMMOLATE.iconID
        state.immolate.expiration = expiration
        -- Immolate lasts 15 sec, and the desired memory is 30 sec from cast.
        state.immolate.armedUntil = math.max(
            state.immolate.armedUntil or 0,
            expiration + 15
        )

    elseif name == SPELLS.RECKLESSNESS.name then
        state.curse.spellKey = "RECKLESSNESS"
        state.curse.spellID = spellID or SPELLS.RECKLESSNESS.iconID
        state.curse.expiration = expiration
        state.curse.armedUntil = expiration + 30

    elseif name == SPELLS.ELEMENTS.name or name == "Curse of Elements" then
        state.curse.spellKey = "ELEMENTS"
        state.curse.spellID = spellID or SPELLS.ELEMENTS.iconID
        state.curse.expiration = expiration
        state.curse.armedUntil = expiration + 30
    end
end

local function ScanTargetOutOfCombat()
    if not HostileTarget() then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return end

    local guid = CurrentTargetGUID()
    local state = StateFor(guid, true)
    if not state then return end

    local ok, auras = pcall(C_UnitAuras.GetUnitAuras, "target", "HARMFUL|PLAYER")
    if not ok or not auras then return end

    -- Reset ordinary aura expiration before rebuilding from the readable scan.
    state.bane.expiration = nil
    state.corruption.expiration = nil
    state.siphon.expiration = nil

    -- Special trackers keep their "armed" memory even if currently absent.
    state.immolate.expiration = nil
    state.curse.expiration = nil

    for _, aura in ipairs(auras) do
        MatchAuraToState(state, aura)
    end
end

local function ScanFocusOutOfCombat()
    if not HostileFocus() then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return end

    local guid = CurrentFocusGUID()
    local state = StateFor(guid, true)

    if not state then return end

    local ok, auras =
        pcall(C_UnitAuras.GetUnitAuras, "focus", "HARMFUL|PLAYER")

    if not ok or not auras then return end

    state.bane.expiration = nil
    state.corruption.expiration = nil
    state.siphon.expiration = nil

    state.immolate.expiration = nil
    state.curse.expiration = nil

    for _, aura in ipairs(auras) do
        MatchAuraToState(state, aura)
    end
end

local function CleanupOldTargets()
    local now = GetTime()
    for guid, state in pairs(targets) do
        if now - (state.touched or now) > TARGET_MEMORY_TTL then
            targets[guid] = nil
        end
    end
end

-- ============================================================================
-- Events
-- ============================================================================

FA:RegisterEvent("ADDON_LOADED")
FA:RegisterEvent("PLAYER_ENTERING_WORLD")
FA:RegisterEvent("PLAYER_TARGET_CHANGED")
FA:RegisterEvent("PLAYER_REGEN_ENABLED")
FA:RegisterEvent("PLAYER_FOCUS_CHANGED")
FA:RegisterEvent("NAME_PLATE_UNIT_ADDED")
FA:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
FA:RegisterUnitEvent("UNIT_AURA", "target", "focus")
FA:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
FA:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")


FA:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end

        ForeverAurasWarlockDB = ForeverAurasWarlockDB or {}
        db = ForeverAurasWarlockDB

        if db.enabled == nil then db.enabled = true end
        if db.locked == nil then db.locked = true end

        RestorePosition()
        RestoreFocusPosition()
        ApplyLockState()
        Print("Warlock loaded. /fa for commands.")
        return
    end

    if not db then return end

    if event == "PLAYER_ENTERING_WORLD" then
        ScanTargetOutOfCombat()
        ScanFocusOutOfCombat()
        UpdateDisplay()

    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Clear only the emergency anonymous fallback.
        -- Nameplate-keyed mob states stay intact when tab-targeting.
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
                -- A nameplate frame may have previously belonged to another mob.
                -- Start a new assignment clean.
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
            -- Prevent a recycled nameplate from inheriting the dead/old mob's DoTs.
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

        if unit == "player"
            and sentTarget
            and not IsSecret(sentTarget) then

            local targetMatches =
                NameMatchesUnit(sentTarget, "target")

            local focusMatches =
                NameMatchesUnit(sentTarget, "focus")

            if focusMatches and not targetMatches then
                pendingTargetKey = CurrentFocusGUID()

            elseif targetMatches then
                pendingTargetKey = CurrentTargetGUID()
            end
        end

    elseif event == "UNIT_SPELLCAST_START" then
        local unit = ...

        if unit == "player" and not pendingTargetKey then
            pendingTargetKey = CurrentTargetGUID()
        end

    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_INTERRUPTED" then

        local unit = ...

        if unit == "player" then
            pendingTargetKey = nil
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...

        if unit ~= "player" then
            return
        end

        local guid = pendingTargetKey or CurrentTargetGUID()
        pendingTargetKey = nil

        RecordSpellOnTarget(spellID, guid)
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
-- ============================================================================
-- Commands
-- ============================================================================

SLASH_FOREVERAURASWARLOCK1 = "/fa"
SLASH_FOREVERAURASWARLOCK2 = "/foreverauras"

SlashCmdList.FOREVERAURASWARLOCK = function(msg)
    if not db then return end
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "unlock" then
        db.locked = false
        ApplyLockState()
        holder:Show()
        UpdateDisplay()
        Print("unlocked. Drag the row, then /fa lock.")

    elseif msg == "lock" then
        db.locked = true
        SavePosition()
        SaveFocusPosition()
        ApplyLockState()
        UpdateDisplay()
        Print("locked.")

    elseif msg == "test" then
        testMode = true
        testUntil = GetTime() + 10
        UpdateDisplay()
        Print("10-second test: Curse 4.2, Bane missing/glow, Corruption 1.6, Siphon missing/glow, Immolate 2.4.")

    elseif msg == "reset" then
        db.position = nil
        db.focusPosition = nil

        RestorePosition()
        RestoreFocusPosition()

        SavePosition()
        SaveFocusPosition()

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
            .. ", curse warning=5.0s."
        )

    else
        Print("commands: /fa test, unlock, lock, reset, on, off, clear, status")
    end
end
