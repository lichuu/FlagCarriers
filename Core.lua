local ADDON, GK = ...
_G.FlagCarriers = GK

GK.modules = {}
GK.testMode = false

local defaults = {
    locked = true,
    positions = {},
    scales = {},
    callouts = true,
    calloutScale = 1,
    carriers = true,
    fcNames = false, -- Blizzard already shows clickable carrier names
    moveBlizzCarriers = true, -- move Blizzard's carrier frames by the flags

    efcLowAlert = true,
    raidFlag = true,
    rezTimer = true,
    rezInterval = 31.5,
    wsgRezThreshold = 2,
    avRezThreshold = 4,
    autoAssist = true,
    enemies = true,
    enemyScale = 1,
}

-- Forever runs the Midnight API, where some values (enemy health, some names)
-- come back as "secret" values that error on math or comparison.
local issecret = _G.issecretvalue
function GK.IsSecret(v)
    return issecret and issecret(v) or false
end

-- Returns v only if it's a normal, readable value.
function GK.Plain(v)
    if v == nil or GK.IsSecret(v) then return nil end
    return v
end

function GK.Print(...)
    print("|cff61f7ffFlagCarriers|r:", ...)
end

local WSG_IDS = { [489] = true, [2106] = true }
local AV_IDS = { [30] = true, [2197] = true }

local function InstanceInfo()
    local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
    return name, instanceType, instanceID
end

function GK.InBattleground()
    local _, instanceType = InstanceInfo()
    return instanceType == "pvp"
end

function GK.InWSG()
    local name, instanceType, id = InstanceInfo()
    if instanceType ~= "pvp" then return false end
    return WSG_IDS[id] or name == "Warsong Gulch" or GetZoneText() == "Warsong Gulch"
end

function GK.InAV()
    local name, instanceType, id = InstanceInfo()
    if instanceType ~= "pvp" then return false end
    return AV_IDS[id] or name == "Alterac Valley" or GetZoneText() == "Alterac Valley"
end

function GK.ChatChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function GK.SendAddon(prefix, msg)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    local channel = GK.ChatChannel()
    if not channel then return end
    pcall(C_ChatInfo.SendAddonMessage, prefix, msg, channel)
end

-- Class color hex for a class token like "WARRIOR".
function GK.ClassColor(classToken)
    local c = classToken and RAID_CLASS_COLORS[classToken]
    if c then return c.r, c.g, c.b end
    return 0.5, 0.5, 0.5
end

-- Scoreboard rows: { name, classToken, faction, deaths } (faction: 0 = Horde, 1 = Alliance).
function GK.ScoreRows()
    local rows = {}
    local n = GetNumBattlefieldScores and GetNumBattlefieldScores() or 0
    for i = 1, n do
        local name, classToken, faction, deaths
        if C_PvP and C_PvP.GetScoreInfo then
            local info = C_PvP.GetScoreInfo(i)
            if info then name, classToken, faction, deaths = info.name, info.classToken, info.faction, info.deaths end
        elseif GetBattlefieldScore then
            local _
            name, _, _, deaths, _, faction, _, _, _, classToken = GetBattlefieldScore(i)
        end
        name = GK.Plain(name)
        if name then
            rows[#rows + 1] = {
                name = name, classToken = GK.Plain(classToken),
                faction = GK.Plain(faction), deaths = GK.Plain(deaths),
            }
        end
    end
    return rows
end

function GK.PlayerFactionIndex()
    return UnitFactionGroup("player") == "Horde" and 0 or 1
end

-- Unit tokens we can read health from. In PvP, chained tokens like
-- "raid1target" return no health, so only direct tokens are listed.
local scanUnits = { "target", "focus", "mouseover", "softenemy" }
for i = 1, 5 do scanUnits[#scanUnits + 1] = "arena" .. i end
for i = 1, 40 do scanUnits[#scanUnits + 1] = "nameplate" .. i end
for i = 1, 40 do scanUnits[#scanUnits + 1] = "raid" .. i end

-- Forever names are "First Surname": UnitName's second result is the
-- surname, not a realm, and the scoreboard joins them with a space.
local usesSurnames = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
local NAME_SEP = "-"
if usesSurnames then
    local consts = Constants and Constants.CharacterNameSeparatorConsts
    NAME_SEP = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR or " "
end

local function FullName(unit)
    local name, second = UnitName(unit)
    name, second = GK.Plain(name), GK.Plain(second)
    if not name or name == "" or name == UNKNOWNOBJECT then return nil end
    if second and second ~= "" then return name .. NAME_SEP .. second end
    return name
end
GK.FullName = FullName

-- Name without a "-Realm" suffix (unchanged on Forever).
function GK.ShortName(name)
    if usesSurnames then return name end
    return name:match("^([^-]+)") or name
end

-- Builds name -> unit token map for every unit we can currently see.
function GK.VisibleUnits()
    local map = {}
    for _, unit in ipairs(scanUnits) do
        if GK.Plain(UnitExists(unit)) then
            local name = FullName(unit)
            if name and not map[name] then
                map[name] = unit
                local short = GK.ShortName(name)
                if not map[short] then map[short] = unit end
            end
        end
    end
    return map
end

-- Health fraction as a normal number, or nil when health is secret.
function GK.HealthFraction(unit)
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if GK.IsSecret(cur) or GK.IsSecret(max) then return nil end
    if not cur or not max or max <= 0 then return nil end
    return cur / max
end

-- Writes a unit's health into a FontString. Forever hides enemy health from
-- addons, but these text calls accept hidden values and the game draws them.
-- mode: "pct" for "42%", "hp" for the health number like "393".
-- Keep this text in its own FontString: once it shows a hidden value, its
-- width can't be read any more.
function GK.SetHealthText(fs, unit, mode)
    pcall(function()
        if mode == "hp" then
            local h = UnitHealth(unit, true)
            if not h then return end
            fs:SetText(AbbreviateNumbers(h))
        else
            if not (UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100) then return end
            local pct = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)
            if not pct then return end
            fs:SetFormattedText("%d%%", pct)
        end
    end)
end

-- Sets a StatusBar from a unit's health. Works with hidden values too.
function GK.SetHealthBar(bar, unit)
    local max, cur = UnitHealthMax(unit), UnitHealth(unit, true)
    if not max or not cur then return false end
    bar:SetMinMaxValues(0, max)
    -- Glide to the new value instead of jumping, where the client supports it.
    local smooth = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut
    if not (smooth and pcall(bar.SetValue, bar, cur, smooth)) then bar:SetValue(cur) end
    return true
end

-- Sets a StatusBar from a unit's mana/energy/rage.
function GK.SetPowerBar(bar, unit)
    local max, cur = UnitPowerMax(unit), UnitPower(unit)
    if not max or not cur then return end
    bar:SetMinMaxValues(0, max)
    bar:SetValue(cur)
end

-- Wraps a script handler so an error can't flood the game: the first
-- error per handler is printed to chat, later ones are dropped.
function GK.Safe(label, fn)
    local reported = false
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok and not reported then
            reported = true
            GK.Print("|cffff4f4f" .. label .. " error (shown once):|r " .. tostring(err))
        end
    end
end

-- Movable frames ----------------------------------------------------------

local movers = {}

function GK.MakeMovable(frame, key, defaultPoint)
    frame.gkKey = key
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame.gkDefault = defaultPoint

    local handle = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    handle:SetAllPoints()
    handle:SetFrameLevel(frame:GetFrameLevel() + 50)
    handle:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    handle:SetBackdropColor(0.2, 0.6, 1, 0.35)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle.label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    handle.label:SetPoint("CENTER")
    handle.label:SetText(key)
    -- Scroll over the box to resize it, keeping it centred where it is.
    handle:EnableMouseWheel(true)
    handle:SetScript("OnMouseWheel", function(_, delta)
        if InCombatLockdown() then return end
        local old = frame:GetEffectiveScale()
        local cx, cy = frame:GetCenter()
        local scale = math.floor(((GK.db.scales[key] or 1) + delta * 0.05) * 100 + 0.5) / 100
        scale = math.max(0.5, math.min(2, scale))
        GK.db.scales[key] = scale
        GK.ApplyScale(frame)
        if cx then
            local new = frame:GetEffectiveScale()
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx * old / new, cy * old / new)
            local p, _, rp, x, y = frame:GetPoint()
            GK.db.positions[key] = { p, rp, x, y }
        end
        handle.label:SetText(string.format("%s %d%%", key, scale * 100))
    end)
    handle:SetScript("OnDragStart", function()
        if not InCombatLockdown() then frame:StartMoving() end
    end)
    handle:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local p, _, rp, x, y = frame:GetPoint()
        GK.db.positions[key] = { p, rp, x, y }
    end)
    handle:Hide()
    frame.gkHandle = handle
    movers[#movers + 1] = frame
    GK.ApplyScale(frame)
    GK.RestorePosition(frame)
end

-- Applies the saved size. A frame can set gkOnScale to also scale
-- something it carries (like Blizzard's carrier frames).
function GK.ApplyScale(frame)
    local scale = GK.db.scales[frame.gkKey] or frame.gkDefaultScale or 1
    frame:SetScale(scale)
    if frame.gkOnScale then frame.gkOnScale(scale) end
end

function GK.RestorePosition(frame)
    local pos = GK.db.positions[frame.gkKey] or frame.gkDefault
    frame:ClearAllPoints()
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
end

function GK.SetLocked(locked)
    if InCombatLockdown() then GK.Print("Can't do that in combat.") return end
    GK.db.locked = locked
    for _, f in ipairs(movers) do f.gkHandle:SetShown(not locked) end
    GK.Refresh()
end

-- Modules -----------------------------------------------------------------

function GK.RegisterModule(name, mod)
    GK.modules[name] = mod
end

-- Ask every module to show or hide itself. Deferred if in combat.
local pendingRefresh = false
function GK.Refresh()
    if InCombatLockdown() then pendingRefresh = true return end
    pendingRefresh = false
    for name, mod in pairs(GK.modules) do
        if mod.Refresh then
            -- One module failing shouldn't stop the others from updating.
            local ok, err = pcall(mod.Refresh, mod)
            if not ok then GK.Print("|cffff4f4f" .. name .. " error:|r " .. tostring(err)) end
        end
    end
end

function GK.ShouldShowAll()
    return GK.testMode or not GK.db.locked
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        FlagCarriersDB = FlagCarriersDB or {}
        for k, v in pairs(defaults) do
            if FlagCarriersDB[k] == nil then FlagCarriersDB[k] = (type(v) == "table") and {} or v end
        end
        GK.db = FlagCarriersDB
        -- Older settings kept two sizes separately.
        if GK.db.enemyScale ~= 1 and not GK.db.scales.Enemies then GK.db.scales.Enemies = GK.db.enemyScale end
        if GK.db.calloutScale ~= 1 and not GK.db.scales.Callouts then GK.db.scales.Callouts = GK.db.calloutScale end
        for name, mod in pairs(GK.modules) do
            if mod.Init then
                local ok, err = pcall(mod.Init, mod)
                if not ok then GK.Print("|cffff4f4f" .. name .. " failed to start:|r " .. tostring(err)) end
            end
        end
        GK.SetLocked(GK.db.locked)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingRefresh then GK.Refresh() end
        for name, mod in pairs(GK.modules) do
            if mod.OutOfCombat then
                local ok, err = pcall(mod.OutOfCombat, mod)
                if not ok then GK.Print("|cffff4f4f" .. name .. " error:|r " .. tostring(err)) end
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if GK.db then GK.Refresh() end
    end
end)

-- Slash command -----------------------------------------------------------

-- Toggle commands, in help order: { command, setting, what it does }.
local toggleList = {
    { "callouts", "callouts", "EFC location callout buttons" },
    { "carriers", "carriers", "carrier HP and flag drop timer by the flags" },
    { "fcnames", "fcNames", "FlagCarriers' own clickable carrier names" },
    { "blizzfc", "moveBlizzCarriers", "move Blizzard's carrier frames by the flags (reload to undo)" },
    { "lowalert", "efcLowAlert", "red EFC LOW banner under 50% HP" },
    { "fcicon", "raidFlag", "flag icon on your carrier's raid frame" },
    { "rez", "rezTimer", "graveyard rez timer" },
    { "enemies", "enemies", "enemy player frames" },
    { "assist", "autoAssist", "give everyone assist when you lead" },
}
local toggles = { raidflag = "raidFlag" } -- old name still works
for _, t in ipairs(toggleList) do toggles[t[1]] = t[2] end

local function Help()
    GK.Print("commands:")
    print("  /fc unlock | lock  - move frames (scroll on them to resize)")
    print("  /fc test           - preview everything outside a battleground")
    print("  /fc reset          - reset frame positions and sizes")
    print("  /fc sync           - sync rez timer with your group")
    print("  Turn a feature on or off:")
    for _, t in ipairs(toggleList) do
        local on = GK.db[t[2]] and "|cff4fff4fon|r" or "|cffff4f4foff|r"
        print(string.format("  /fc %-10s %s - %s", t[1], on, t[3]))
    end
end

SLASH_FLAGCARRIERS1 = "/fc"
SLASH_FLAGCARRIERS2 = "/flagcarriers"
SlashCmdList.FLAGCARRIERS = function(input)
    local cmd = (input or ""):lower():match("^%s*(%S*)")
    if cmd == "unlock" then
        GK.SetLocked(false)
        GK.Print("Unlocked. Drag the blue boxes to move them, scroll on them to resize. /fc lock when done.")
    elseif cmd == "lock" then
        GK.SetLocked(true)
    elseif cmd == "test" then
        GK.testMode = not GK.testMode
        GK.Print("Test mode " .. (GK.testMode and "on" or "off"))
        GK.Refresh()
    elseif cmd == "reset" then
        if InCombatLockdown() then GK.Print("Can't do that in combat.") return end
        wipe(GK.db.positions)
        wipe(GK.db.scales)
        for _, f in ipairs(movers) do
            GK.ApplyScale(f)
            GK.RestorePosition(f)
            f.gkHandle.label:SetText(f.gkKey)
        end
        GK.Refresh()
    elseif cmd == "debug" then
        local m = GK.modules.BlizzCarriers
        if m then m:Debug() end
    elseif cmd == "sync" then
        local rez = GK.modules.RezTimer
        if rez then rez:SendSync() end
    elseif toggles[cmd] then
        local key = toggles[cmd]
        GK.db[key] = not GK.db[key]
        GK.Print(cmd .. " " .. (GK.db[key] and "on" or "off"))
        GK.Refresh()
    else
        Help()
    end
end
