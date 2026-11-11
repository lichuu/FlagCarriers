local _, GK = ...

-- Flag carriers in WSG:
--  * HP % after Blizzard's carrier names at the top of the screen
--    (or FlagCarriers's own clickable names with /fc fcnames)
--  * a countdown when a dropped flag will return to base
--  * an "EFC LOW" banner when the enemy carrier is under 50% HP

local DROP_RETURN = 10 -- seconds before a dropped flag returns to base
local LOW_HP = 0.5     -- "EFC LOW" banner below this

local FC = {}
GK.RegisterModule("Carriers", FC)

-- Keyed by which flag is carried: "Alliance" = the Alliance flag (held by a Horde player).
local state = {
    Alliance = { holder = nil, droppedAt = nil },
    Horde = { holder = nil, droppedAt = nil },
}
local classByName = {}

local function OurFlag()
    return UnitFactionGroup("player")
end

local function TheirFlag()
    return OurFlag() == "Horde" and "Alliance" or "Horde"
end

-- The game's unit slots for flag carriers (arena1/arena2 in BGs).
-- On Forever these slots hold carriers from both teams, so check the side.
local function CarrierUnit(wantEnemy)
    for i = 1, 2 do
        local unit = "arena" .. i
        if GK.Plain(UnitExists(unit)) then
            local friend = GK.Plain(UnitIsFriend("player", unit))
            if friend ~= nil and friend ~= wantEnemy then return unit end
        end
    end
end

function GK.EnemyCarrierUnit() return CarrierUnit(true) end
local function FriendlyCarrierUnit() return CarrierUnit(false) end

-- Name of the enemy holding our flag, if known.
function GK.GetEFC()
    return state[OurFlag()].holder
end

-- Name of our player holding the enemy flag, if known.
function GK.GetOurFC()
    return state[TheirFlag()].holder
end

local function Reset()
    for _, s in pairs(state) do
        s.holder, s.droppedAt, s.fromSlot, s.lostAt, s.capsAtLoss = nil, nil, nil, nil, nil
    end
end

local function RefreshClasses()
    for _, row in ipairs(GK.ScoreRows()) do
        classByName[row.name] = row.classToken
        classByName[GK.ShortName(row.name)] = row.classToken
    end
end

-- Blizzard's capture widgets ---------------------------------------------

-- Finds the widget for each flag. The WeakAura matched these tooltips:
-- "Horde flag captures" sits on the Alliance side, and vice versa.
local function FindWidgets()
    local found = {}
    local container = _G.UIWidgetTopCenterContainerFrame
    if not container then return found end
    for _, child in ipairs({ container:GetChildren() }) do
        local tip = GK.Plain(child.tooltip)
        if child:IsShown() and type(tip) == "string" then
            if tip:find("Horde flag") then found.Alliance = child
            elseif tip:find("Alliance flag") then found.Horde = child end
        end
    end
    return found
end

-- Finds the FontString in Blizzard's widget that shows this carrier's name.
local function FindNameString(frame, name, depth)
    if not frame or depth > 3 then return nil end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region.GetText and region:GetObjectType() == "FontString" then
            local text = GK.Plain(region:GetText())
            if type(text) == "string" and text:find(name, 1, true) then return region end
        end
    end
    for _, child in ipairs({ frame:GetChildren() }) do
        local found = FindNameString(child, name, depth + 1)
        if found then return found end
    end
end

-- Capture count ("1/3") shown in the widget for the team carrying this flag.
local function Captures(flag)
    local widget = FindWidgets()[flag]
    if not widget then return nil end
    local function scan(frame, depth)
        if depth > 2 then return nil end
        for _, region in ipairs({ frame:GetRegions() }) do
            if region:GetObjectType() == "FontString" then
                local text = GK.Plain(region:GetText())
                local n = type(text) == "string" and text:match("(%d+)%s*/%s*%d+")
                if n then return tonumber(n) end
            end
        end
        for _, child in ipairs({ frame:GetChildren() }) do
            local n = scan(child, depth + 1)
            if n then return n end
        end
    end
    return scan(widget, 0)
end

-- Keeps each flag's carrier in sync with the game's carrier slots. In
-- battlegrounds the flag messages can reach addons hidden, so the slots are
-- the reliable source. Returns true if a carrier changed.
local function SyncFromSlots(flag, now)
    local s = state[flag]
    local unit = CarrierUnit(flag == OurFlag())
    local name = unit and GK.FullName(unit)
    local changed = false
    if name then
        if s.holder ~= name then
            s.holder, s.droppedAt, s.lostAt = name, nil, nil
            changed = true
        end
        s.fromSlot = true
    elseif s.holder and s.fromSlot then
        -- Slot emptied: the flag was dropped or captured. Decide which once
        -- the capture count has had a moment to update.
        s.holder, s.fromSlot = nil, nil
        s.lostAt, s.capsAtLoss = now, Captures(flag)
        changed = true
    end
    if s.lostAt and now - s.lostAt > 1 then
        local caps = Captures(flag)
        local captured = caps and s.capsAtLoss and caps > s.capsAtLoss
        if not captured and not s.droppedAt then s.droppedAt = s.lostAt end
        s.lostAt = nil
    end
    return changed
end

-- Our clickable name buttons (only shown with /fc fcnames) -----------------

local buttons = {}

local function MakeButton(flag)
    local b = CreateFrame("Button", "FlagCarriersFC" .. flag, UIParent, "SecureActionButtonTemplate")
    -- Above Blizzard's flag display, which otherwise catches the clicks.
    b:SetFrameStrata("HIGH")
    -- Fire on the same click edge as action buttons, like BattleGroundEnemies.
    local keyDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") or false
    b:RegisterForClicks(keyDown and "AnyDown" or "AnyUp")
    b:SetAttribute("useOnKeyDown", keyDown)
    b:SetAttribute("type", "macro")
    b:SetAttribute("macrotext", "")
    b.text = b:CreateFontString(nil, "ARTWORK")
    b.text:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    b.text:SetPoint("LEFT")
    b:SetSize(1, 16)
    return b
end

-- Anchors our buttons next to the widgets. Only possible out of combat.
local function Anchor()
    if InCombatLockdown() then return end
    local widgets = FindWidgets()
    local container = _G.UIWidgetTopCenterContainerFrame
    for i, flag in ipairs({ "Alliance", "Horde" }) do
        local b = buttons[flag]
        b:ClearAllPoints()
        if widgets[flag] then
            b:SetPoint("LEFT", widgets[flag], "LEFT", 85, 0)
        elseif container then
            b:SetPoint("TOP", container, "BOTTOM", 0, -2 - (i - 1) * 18)
        else
            b:SetPoint("TOP", UIParent, "TOP", 0, -60 - (i - 1) * 18)
        end
    end
end

local function ApplyMacros()
    if InCombatLockdown() then return end
    for flag, s in pairs(state) do
        local b = buttons[flag]
        if flag == OurFlag() then
            -- Enemy carrier: target the game's carrier slot directly, the way
            -- BattleGroundEnemies does. Works in combat and when the flag
            -- changes hands, no name needed. Right click sets focus.
            b:SetAttribute("unit", GK.EnemyCarrierUnit() or "arena1")
            b:SetAttribute("type1", "target")
            b:SetAttribute("type2", "focus")
        else
            -- Our own carrier: target by name.
            b:SetAttribute("unit", nil)
            b:SetAttribute("type1", "macro")
            b:SetAttribute("type2", "macro")
            b:SetAttribute("macrotext", s.holder and ("/targetexact " .. s.holder) or "")
        end
        b:SetWidth(math.max(1, b.text:GetStringWidth()))
    end
end

-- HP / drop-timer labels -----------------------------------------------------

-- Plain labels (not clickable, so they can move in combat). They sit after
-- Blizzard's carrier name, or after ours with /fc fcnames.
local labels = {}

local function MakeLabel()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f:SetSize(1, 16)
    f.text = f:CreateFontString(nil, "ARTWORK")
    f.text:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    f.text:SetPoint("LEFT")
    return f
end

local function PlaceLabel(flag, holder)
    local label = labels[flag]
    label:ClearAllPoints()
    if GK.db.fcNames then
        label:SetPoint("LEFT", buttons[flag].text, "RIGHT", 4, 0)
        return
    end
    local widget = FindWidgets()[flag]
    local nameFS = widget and holder and FindNameString(widget, holder, 0)
    if nameFS then
        label:SetPoint("LEFT", nameFS, "LEFT", nameFS:GetUnboundedStringWidth() + 6, 0)
    elseif widget then
        label:SetPoint("LEFT", widget, "RIGHT", 4, 0)
    else
        label:SetPoint("TOP", UIParent, "TOP", 0, flag == "Alliance" and -60 or -78)
    end
end

-- "EFC LOW" banner -----------------------------------------------------------
-- The addon can't read enemy HP, but the game can turn hidden HP into a bar
-- fill. A step curve maps HP below 50% to 1 and above to 0; the bar's fill
-- is the banner, so it only shows when the enemy carrier is low.

local lowBanner, lowCurve

local function MakeLowBanner()
    if not (C_CurveUtil and C_CurveUtil.CreateCurve and Enum and Enum.LuaCurveType) then return end
    local ok = pcall(function()
        lowCurve = C_CurveUtil.CreateCurve()
        lowCurve:SetType(Enum.LuaCurveType.Step)
        lowCurve:AddPoint(0, 1)
        lowCurve:AddPoint(LOW_HP, 0)
    end)
    if not ok then lowCurve = nil return end

    local f = CreateFrame("StatusBar", "FlagCarriersEFCLow", UIParent)
    f:SetSize(190, 30)
    f:SetFrameStrata("HIGH")
    f:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    f:GetStatusBarTexture():SetAlpha(0) -- the fill only drives the clip below
    f:SetMinMaxValues(0, 1)
    f:SetValue(0)

    -- Everything visible lives in a frame clipped to the fill, so it all
    -- appears at once when HP drops under 50% and vanishes above it.
    local clip = CreateFrame("Frame", nil, f)
    clip:SetPoint("TOPLEFT", f:GetStatusBarTexture(), "TOPLEFT")
    clip:SetPoint("BOTTOMRIGHT", f:GetStatusBarTexture(), "BOTTOMRIGHT")
    clip:SetClipsChildren(true)
    local plate = CreateFrame("Frame", nil, clip)
    plate:SetAllPoints(f)

    local bg = plate:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.07, 0.02, 0.02, 0.88)
    -- Thin red border.
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = plate:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.85, 0.12, 0.1, 0.9)
        if side == "TOP" or side == "BOTTOM" then
            t:SetPoint(side .. "LEFT"); t:SetPoint(side .. "RIGHT"); t:SetHeight(1)
        else
            t:SetPoint("TOP" .. side); t:SetPoint("BOTTOM" .. side); t:SetWidth(1)
        end
    end
    -- Accent stripe on the left.
    local stripe = plate:CreateTexture(nil, "ARTWORK")
    stripe:SetPoint("TOPLEFT", 1, -1)
    stripe:SetPoint("BOTTOMLEFT", 1, 1)
    stripe:SetWidth(4)
    stripe:SetColorTexture(1, 0.2, 0.15, 1)
    -- Soft red glow that pulses.
    local glow = plate:CreateTexture(nil, "ARTWORK", nil, -1)
    glow:SetPoint("TOPLEFT", 5, -1)
    glow:SetPoint("BOTTOMRIGHT", -1, 1)
    glow:SetTexture("Interface\\Buttons\\WHITE8X8")
    if glow.SetGradient and CreateColor then
        glow:SetGradient("HORIZONTAL", CreateColor(0.9, 0.1, 0.08, 0.45), CreateColor(0.9, 0.1, 0.08, 0))
    else
        glow:SetVertexColor(0.9, 0.1, 0.08, 0.2)
    end
    local pulse = plate:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetTarget(glow)
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.2)
    fade:SetDuration(0.5)
    fade:SetSmoothing("IN_OUT")
    pulse:Play()

    local skull = plate:CreateTexture(nil, "OVERLAY")
    skull:SetSize(18, 18)
    skull:SetPoint("LEFT", 12, 0)
    skull:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    local text = plate:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    text:SetPoint("LEFT", skull, "RIGHT", 8, 0)
    text:SetTextColor(1, 0.4, 0.35)
    text:SetText("ENEMY FC LOW")
    GK.MakeMovable(f, "EFC low alert", { "TOP", "TOP", 0, -140 })
    lowBanner = f
end

local function UpdateLowBanner(unit)
    if not lowBanner then return end
    if GK.ShouldShowAll() and not GK.InWSG() then
        lowBanner:SetValue(1) -- keep it visible while placing or testing
        return
    end
    if not unit or not GK.db.efcLowAlert then
        lowBanner:SetValue(0)
        return
    end
    local ok = pcall(function()
        local v = UnitHealthPercent(unit, true, lowCurve)
        if v then lowBanner:SetValue(v) end
    end)
    if not ok then lowBanner:SetValue(0) end
end

-- Per-tick update ------------------------------------------------------------

local function UpdateFlag(flag, units)
    local s, b = state[flag], buttons[flag]
    local label = labels[flag].text
    local isEFC = (flag == OurFlag())

    if not s.holder then
        b.text:SetText("")
        local left = s.droppedAt and (s.droppedAt + DROP_RETURN - GetTime())
        if left and left > 0 then
            PlaceLabel(flag, nil)
            label:SetText(string.format("|cffffd100Dropped - returns in %d|r", math.ceil(left)))
        else
            s.droppedAt = nil
            label:SetText("")
        end
        if isEFC then UpdateLowBanner(nil) end
        return
    end

    if GK.db.fcNames then
        local r, g, bl = GK.ClassColor(classByName[s.holder])
        b.text:SetText(string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, bl * 255, s.holder))
        if not InCombatLockdown() then b:SetWidth(math.max(1, b.text:GetStringWidth())) end
    else
        b.text:SetText("")
    end
    PlaceLabel(flag, s.holder)

    local unit = units[s.holder]
    if not unit then unit = isEFC and GK.EnemyCarrierUnit() or (not isEFC and FriendlyCarrierUnit()) or nil end
    -- Blizzard's carrier frames already show HP when we move them up here.
    if unit and not GK.db.moveBlizzCarriers then
        GK.SetHealthText(label, unit, "pct")
    else
        label:SetText("")
    end
    if isEFC then UpdateLowBanner(unit) end
end

-- Events ---------------------------------------------------------------

local function FlagFromMsg(msg)
    local lower = msg:lower()
    if lower:find("alliance flag") then return "Alliance" end
    if lower:find("horde flag") then return "Horde" end
end

local function OnSystemMessage(msg)
    msg = GK.Plain(msg)
    if type(msg) ~= "string" then return end
    local lower = msg:lower()
    if lower:find("placed at their bases") then Reset() return end
    local flag = FlagFromMsg(msg)
    if not flag then return end
    local s = state[flag]
    local picker = msg:match("[Pp]icked up by (.-)!?$")
    if picker then
        s.holder, s.droppedAt, s.lostAt = picker, nil, nil
        if RequestBattlefieldScoreData then RequestBattlefieldScoreData() end
    elseif lower:find("dropped by") then
        s.holder, s.fromSlot, s.lostAt, s.droppedAt = nil, nil, nil, GetTime()
    elseif lower:find("captured the") or lower:find("returned") then
        s.holder, s.fromSlot, s.lostAt, s.droppedAt = nil, nil, nil, nil
    end
    ApplyMacros()
end

function FC:Init()
    buttons.Alliance = MakeButton("Alliance")
    buttons.Horde = MakeButton("Horde")
    labels.Alliance = MakeLabel()
    labels.Horde = MakeLabel()
    MakeLowBanner()

    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_BG_SYSTEM_ALLIANCE")
    f:RegisterEvent("CHAT_MSG_BG_SYSTEM_HORDE")
    f:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")
    f:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
    f:RegisterEvent("UPDATE_UI_WIDGET")
    f:RegisterEvent("ARENA_OPPONENT_UPDATE")
    f:SetScript("OnEvent", GK.Safe("FlagCarriers event", function(_, event, ...)
        if not GK.InWSG() and not GK.testMode then return end
        if event == "UPDATE_BATTLEFIELD_SCORE" then
            RefreshClasses()
        elseif event == "UPDATE_UI_WIDGET" then
            Anchor()
        elseif event == "ARENA_OPPONENT_UPDATE" then
            ApplyMacros() -- carrier slot changed; no-op in combat
        else
            OnSystemMessage(...)
        end
    end))

    local elapsed = 0
    f:SetScript("OnUpdate", GK.Safe("FlagCarriers", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.2 then return end
        elapsed = 0
        if not labels.Alliance:IsShown() then return end
        local units = GK.VisibleUnits()
        local now = GetTime()
        local changedA = SyncFromSlots("Alliance", now)
        local changedH = SyncFromSlots("Horde", now)
        if changedA or changedH then ApplyMacros() end
        UpdateFlag("Alliance", units)
        UpdateFlag("Horde", units)
    end))
end

function FC:OutOfCombat()
    Anchor()
    ApplyMacros()
end

function FC:Refresh()
    if not buttons.Alliance then return end
    local inWSG = GK.InWSG()
    local show = GK.db.carriers and (inWSG or GK.testMode)
    -- Clear sample names when test mode ends, and everything when leaving WSG.
    if not inWSG or (self.showingTest and not GK.testMode) then Reset() end
    self.showingTest = show and GK.testMode and not inWSG
    if self.showingTest then
        state.Alliance.holder = GK.FullName("player")
        state.Horde.droppedAt = GetTime()
    end
    buttons.Alliance:SetShown(show and GK.db.fcNames)
    buttons.Horde:SetShown(show and GK.db.fcNames)
    labels.Alliance:SetShown(show)
    labels.Horde:SetShown(show)
    if lowBanner then
        lowBanner:SetShown(GK.db.efcLowAlert and (inWSG or GK.ShouldShowAll()))
        -- Show it filled while unlocked or testing so it can be placed.
        if GK.ShouldShowAll() and not inWSG then lowBanner:SetValue(1) end
    end
    if show then
        RefreshClasses()
        Anchor()
        ApplyMacros()
    end
end
