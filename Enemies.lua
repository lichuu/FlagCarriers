local _, GK = ...

-- A light BattleGroundEnemies: one row per enemy from the scoreboard.
-- Left click targets, right click focuses. HP and mana show when the enemy is
-- visible on a nameplate, your target/focus/mouseover, or a raid member's target.
-- Deaths come from the scoreboard, so dead/alive works even when unseen.

local MAX_ROWS = 15
local ROW_H, GAP = 24, 3
local ICON_W = ROW_H
local BAR_W = 164
local ROW_W = ICON_W + 1 + BAR_W
local POWER_H = 3
local HEADER_H = 20
local FLAT = "Interface\\Buttons\\WHITE8X8"
local CLASS_ICONS = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
local FACTION_COLOR = { [0] = { 0.86, 0.22, 0.20 }, [1] = { 0.27, 0.56, 0.90 } } -- Horde, Alliance
local DEAD_MAX = 35 -- an enemy counted dead is assumed back up after this many seconds

-- Power colours before we've seen the unit: rage, energy, or mana by class.
local CLASS_POWER = { WARRIOR = "RAGE", ROGUE = "ENERGY" }
local FLAG_ICON = 132486

local Enemies = {}
GK.RegisterModule("Enemies", Enemies)

local rows = {}
local classCache = {}    -- name -> class token seen on a unit
local deathInfo = {}     -- name -> { deaths = n, deadAt = time or nil }
local roster = {}        -- what the rows currently show
local pendingRoster      -- new roster waiting for combat to end
-- After a zone change the scoreboard can still hold the last match's
-- players, so ignore it until a fresh update arrives for this match.
local waitingForFreshScore = false

local TEST_ROSTER = {
    { name = "Testwar", classToken = "WARRIOR" }, { name = "Testrogue", classToken = "ROGUE" },
    { name = "Testmage", classToken = "MAGE" }, { name = "Testpriest", classToken = "PRIEST" },
    { name = "Testdruid", classToken = "DRUID" }, { name = "Testhunter", classToken = "HUNTER" },
    { name = "Testlock", classToken = "WARLOCK" }, { name = "Testpally", classToken = "PALADIN" },
    { name = "Testsham", classToken = "SHAMAN" }, { name = "Testwar2", classToken = "WARRIOR" },
}

-- 1px border made of four textures, so it stays crisp at any scale.
local function AddBorder(frame, layer, r, g, b, a, inset)
    inset = inset or 0
    local edges = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = frame:CreateTexture(nil, layer)
        t:SetColorTexture(r, g, b, a)
        if side == "TOP" or side == "BOTTOM" then
            t:SetPoint(side .. "LEFT", -inset, side == "TOP" and inset or -inset)
            t:SetPoint(side .. "RIGHT", inset, side == "TOP" and inset or -inset)
            t:SetHeight(1)
        else
            t:SetPoint("TOP" .. side, side == "LEFT" and -inset or inset, inset)
            t:SetPoint("BOTTOM" .. side, side == "LEFT" and -inset or inset, -inset)
            t:SetWidth(1)
        end
        edges[#edges + 1] = t
    end
    function edges:SetShown(shown) for _, t in ipairs(self) do t:SetShown(shown) end end
    function edges:SetColor(...) for _, t in ipairs(self) do t:SetColorTexture(...) end end
    return edges
end

local function MakeRow(parent, i)
    local b = CreateFrame("Button", "FlagCarriersEnemy" .. i, parent, "SecureActionButtonTemplate")
    b:SetSize(ROW_W, ROW_H)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type1", "macro")
    b:SetAttribute("type2", "macro")

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.04, 0.04, 0.05, 0.85)
    b.border = AddBorder(b, "BORDER", 0, 0, 0, 1)

    -- Class icon on the left.
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT")
    b.icon:SetSize(ICON_W, ROW_H)
    b.icon:SetTexture(CLASS_ICONS)

    b.bar = CreateFrame("StatusBar", nil, b)
    b.bar:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 1, 0)
    b.bar:SetPoint("BOTTOMRIGHT", 0, POWER_H + 1)
    b.bar:SetStatusBarTexture(FLAT)
    b.bar:SetMinMaxValues(0, 1)
    b.bar:SetValue(1)
    -- Missing health shows as a dark tint of the class colour.
    b.missing = b.bar:CreateTexture(nil, "BACKGROUND")
    b.missing:SetAllPoints()
    b.missing:SetTexture(FLAT)
    -- Soft shine across the top half.
    b.shine = b.bar:CreateTexture(nil, "ARTWORK", nil, 2)
    b.shine:SetPoint("TOPLEFT")
    b.shine:SetPoint("TOPRIGHT")
    b.shine:SetHeight((ROW_H - POWER_H - 1) / 2)
    b.shine:SetTexture(FLAT)
    if b.shine.SetGradient and CreateColor then
        b.shine:SetGradient("VERTICAL", CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, 0.18))
    else
        b.shine:SetVertexColor(1, 1, 1, 0.08)
    end

    b.power = CreateFrame("StatusBar", nil, b)
    b.power:SetPoint("TOPLEFT", b.bar, "BOTTOMLEFT", 0, -1)
    b.power:SetPoint("BOTTOMRIGHT")
    b.power:SetStatusBarTexture(FLAT)
    b.power:SetMinMaxValues(0, 1)
    b.power:SetValue(1)
    b.powerBg = b.power:CreateTexture(nil, "BACKGROUND")
    b.powerBg:SetAllPoints()
    b.powerBg:SetColorTexture(0, 0, 0, 0.6)

    b.name = b.bar:CreateFontString(nil, "OVERLAY")
    b.name:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    b.name:SetShadowOffset(1, -1)
    b.name:SetShadowColor(0, 0, 0, 1)
    b.name:SetPoint("LEFT", 5, 0)
    b.name:SetPoint("RIGHT", -50, 0)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.name:SetMaxLines(1)

    b.hp = b.bar:CreateFontString(nil, "OVERLAY")
    b.hp:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    b.hp:SetShadowOffset(1, -1)
    b.hp:SetShadowColor(0, 0, 0, 1)
    b.hp:SetTextColor(0.92, 0.92, 0.92)
    b.hp:SetPoint("RIGHT", -5, 0)
    b.hp:SetJustifyH("RIGHT")

    b.skull = b.bar:CreateTexture(nil, "OVERLAY")
    b.skull:SetSize(14, 14)
    b.skull:SetPoint("RIGHT", b.hp, "LEFT", -3, 0)
    b.skull:SetTexture(SKULL)
    b.skull:Hide()

    -- Flag carrier: flag on the icon plus a pulsing gold border.
    b.flag = b:CreateTexture(nil, "OVERLAY", nil, 3)
    b.flag:SetSize(ROW_H - 2, ROW_H - 2)
    b.flag:SetPoint("CENTER", b.icon, "CENTER")
    b.flag:SetTexture(FLAG_ICON)
    b.flag:Hide()
    b.carrierGlow = CreateFrame("Frame", nil, b)
    b.carrierGlow:SetAllPoints()
    b.carrierGlow:SetFrameLevel(b:GetFrameLevel() + 5)
    AddBorder(b.carrierGlow, "OVERLAY", 1, 0.82, 0.1, 1, 1)
    AddBorder(b.carrierGlow, "OVERLAY", 1, 0.82, 0.1, 0.45, 2)
    local pulse = b.carrierGlow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.25)
    fade:SetDuration(0.55)
    fade:SetSmoothing("IN_OUT")
    b.carrierGlow.pulse = pulse
    b.carrierGlow:Hide()

    -- Your target: white border plus a bright edge on the left.
    b.targetMark = CreateFrame("Frame", nil, b)
    b.targetMark:SetAllPoints()
    b.targetMark:SetFrameLevel(b:GetFrameLevel() + 4)
    AddBorder(b.targetMark, "OVERLAY", 1, 1, 1, 0.9, 1)
    local edge = b.targetMark:CreateTexture(nil, "OVERLAY")
    edge:SetColorTexture(1, 1, 1, 1)
    edge:SetPoint("TOPRIGHT", b, "TOPLEFT", -3, 1)
    edge:SetPoint("BOTTOMRIGHT", b, "BOTTOMLEFT", -3, -1)
    edge:SetWidth(3)
    b.targetMark:Hide()

    -- Red flash when the enemy dies.
    b.flash = b:CreateTexture(nil, "OVERLAY", nil, 4)
    b.flash:SetAllPoints()
    b.flash:SetColorTexture(1, 0.1, 0.1, 1)
    b.flash:SetAlpha(0)
    local flash = b:CreateAnimationGroup()
    local flashIn = flash:CreateAnimation("Alpha")
    flashIn:SetTarget(b.flash)
    flashIn:SetFromAlpha(0.7)
    flashIn:SetToAlpha(0)
    flashIn:SetDuration(0.6)
    flashIn:SetSmoothing("OUT")
    b.flashAnim = flash

    -- How many of our team target this enemy: a small badge left of the row.
    b.targets = b:CreateFontString(nil, "OVERLAY")
    b.targets:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    b.targets:SetPoint("RIGHT", b, "LEFT", -8, 0)
    b.targets:SetTextColor(1, 0.82, 0)

    b:SetPoint("TOPLEFT", 0, -HEADER_H - (i - 1) * (ROW_H + GAP))
    b:Hide()
    return b
end

local function SetClassLook(row, token)
    local r, g, b = GK.ClassColor(token)
    row.classColor = { r, g, b }
    row.bar:SetStatusBarColor(r, g, b)
    row.missing:SetVertexColor(r * 0.22, g * 0.22, b * 0.22, 1)
    local coords = token and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
    if coords then
        row.icon:SetTexCoord(coords[1] + 0.02, coords[2] - 0.02, coords[3] + 0.02, coords[4] - 0.02)
        row.icon:SetVertexColor(1, 1, 1)
    else
        row.icon:SetTexCoord(0, 0, 0, 0) -- unknown class: blank square
        row.icon:SetVertexColor(0.2, 0.2, 0.2)
    end
end

-- Range ---------------------------------------------------------------
-- Classic harm spells per class, tried in order; the first one the game can
-- check against the unit decides. Ranges are roughly 25-36 yards.
local RANGE_SPELLS = {
    MAGE = { "Frostbolt", "Fireball", "Arcane Missiles" },
    WARLOCK = { "Shadow Bolt", "Immolate", "Corruption" },
    PRIEST = { "Smite", "Shadow Word: Pain", "Mind Blast" },
    SHAMAN = { "Lightning Bolt", "Earth Shock" },
    DRUID = { "Wrath", "Moonfire", "Entangling Roots" },
    HUNTER = { "Auto Shot", "Arcane Shot", "Serpent Sting" },
    WARRIOR = { "Charge", "Intercept", "Shoot Bow", "Throw" },
    ROGUE = { "Throw", "Shoot Bow", "Shoot Gun" },
    PALADIN = { "Judgement", "Hammer of Justice" },
}
local OUT_OF_RANGE = 0.35

-- true / false, a hidden boolean, or nil when no spell can tell us.
local function InRange(unit)
    if not (C_Spell and C_Spell.IsSpellInRange) then return nil end
    local _, myClass = UnitClass("player")
    for _, spell in ipairs(RANGE_SPELLS[myClass] or {}) do
        local ok, r = pcall(C_Spell.IsSpellInRange, spell, unit)
        if ok then
            if GK.IsSecret(r) then return r end
            if r ~= nil then return r end
        end
    end
    return nil
end

-- Fades the class icon and bar colours (never the name) when the enemy is
-- out of range or not visible at all. Handles hidden range answers too.
local function SetRange(row, inRange)
    local parts = { row.icon, row.bar:GetStatusBarTexture(), row.power:GetStatusBarTexture() }
    if GK.IsSecret(inRange) then
        for _, p in ipairs(parts) do
            if not (p.SetAlphaFromBoolean and pcall(p.SetAlphaFromBoolean, p, inRange, 1, OUT_OF_RANGE)) then
                p:SetAlpha(1)
            end
        end
        return
    end
    local a = inRange and 1 or OUT_OF_RANGE
    for _, p in ipairs(parts) do p:SetAlpha(a) end
end

local function SetDeadLook(row, dead)
    row.icon:SetDesaturated(dead)
    row.skull:SetShown(dead)
    if dead then
        row.bar:SetStatusBarColor(0.22, 0.22, 0.24)
        row.missing:SetVertexColor(0.1, 0.1, 0.1, 1)
        row.name:SetTextColor(0.55, 0.55, 0.55)
    else
        row.bar:SetStatusBarColor(unpack(row.classColor))
        local r, g, b = unpack(row.classColor)
        row.missing:SetVertexColor(r * 0.22, g * 0.22, b * 0.22, 1)
        row.name:SetTextColor(1, 1, 1)
    end
end

-- Shows the full name if it fits, else "First L.", else the first name
-- (anything still too long gets cut off with "...").
local NAME_W = BAR_W - 5 - 50 -- bar minus left pad and HP area

local function SetFittedName(fs, name)
    local maxW = NAME_W
    fs:SetText(name)
    if fs:GetUnboundedStringWidth() <= maxW then return end
    local first, last = name:match("^(%S+)%s+(%S)")
    if first then
        fs:SetText(first .. " " .. last .. ".")
        if fs:GetUnboundedStringWidth() > maxW then fs:SetText(first) end
    end
end

local function SetPowerColor(row, token)
    local c = token and PowerBarColor and PowerBarColor[token]
    if c then row.power:SetStatusBarColor(c.r, c.g, c.b) else row.power:SetStatusBarColor(0, 0.55, 1) end
end

-- Notes new deaths from the scoreboard.
local function UpdateDeaths(list)
    local now = GetTime()
    for _, e in ipairs(list) do
        if e.deaths then
            local d = deathInfo[e.name]
            if not d then
                deathInfo[e.name] = { deaths = e.deaths }
            elseif not d.deaths then
                d.deaths = e.deaths
            elseif e.deaths > d.deaths then
                d.deaths, d.deadAt = e.deaths, now
            end
        end
    end
end

local function IsDead(name, unit, now)
    if unit then
        local dead = GK.Plain(UnitIsDeadOrGhost(unit))
        if dead ~= nil then
            local d = deathInfo[name]
            if dead then
                -- Seen dead: remember it so the row stays dead out of sight.
                if not d then d = {}; deathInfo[name] = d end
                d.deadAt = d.deadAt or now
            elseif d then
                d.deadAt = nil
            end
            return dead
        end
    end
    local d = deathInfo[name]
    if d and d.deadAt then
        if now - d.deadAt < DEAD_MAX then return true end
        d.deadAt = nil
    end
    return false
end

local function SameRoster(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i].name ~= b[i].name then return false end
    end
    return true
end

-- Changes which enemies the secure rows point at. Out of combat only.
local function ApplyRoster(list)
    if InCombatLockdown() then pendingRoster = list return end
    pendingRoster = nil
    roster = list
    for i, row in ipairs(rows) do
        local e = list[i]
        if e then
            row.enemy = e
            row:SetAttribute("macrotext1", "/targetexact " .. e.name)
            row:SetAttribute("macrotext2", "/targetexact " .. e.name .. "\n/focus\n/targetlasttarget")
            SetClassLook(row, e.classToken)
            SetFittedName(row.name, GK.ShortName(e.name))
            row.wasDead = nil
            SetDeadLook(row, false)
            row.hp:SetText("")
            row.lastSeen = nil
            row.bar:SetMinMaxValues(0, 1)
            row.bar:SetValue(1)
            row.power:SetMinMaxValues(0, 1)
            row.power:SetValue(1)
            SetPowerColor(row, CLASS_POWER[e.classToken or ""] or "MANA")
            row:Show()
        else
            row.enemy = nil
            row.isDead = nil
            row:Hide()
        end
    end
end

local function BuildRoster()
    if GK.testMode and not GK.InBattleground() then return TEST_ROSTER end
    local mine = GK.PlayerFactionIndex()
    local list = {}
    for _, r in ipairs(GK.ScoreRows()) do
        if r.faction ~= nil and r.faction ~= mine then
            r.classToken = r.classToken or classCache[r.name]
            list[#list + 1] = r
        end
    end
    table.sort(list, function(a, b)
        if (a.classToken or "") ~= (b.classToken or "") then return (a.classToken or "") < (b.classToken or "") end
        return a.name < b.name
    end)
    while #list > MAX_ROWS do table.remove(list) end
    return list
end

-- How many enemies are dead right now (for the rez timer).
function GK.DeadEnemyCount()
    local n = 0
    for _, row in ipairs(rows) do
        if row.enemy and row.isDead then n = n + 1 end
    end
    return n
end

local function UpdateRoster()
    if waitingForFreshScore and not GK.testMode then return end
    local list = BuildRoster()
    UpdateDeaths(list)
    if not SameRoster(list, roster) then ApplyRoster(list) end
end


-- name -> how many of us (you plus group members) target that player.
-- Names of group members' targets are readable even in PvP.
local function TargetCounts()
    local counts = {}
    local function add(unit)
        local name = GK.Plain(UnitExists(unit)) and GK.FullName(unit)
        if name then counts[name] = (counts[name] or 0) + 1 end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do add("raid" .. i .. "target") end
    else
        add("target")
        for i = 1, 4 do add("party" .. i .. "target") end
    end
    return counts
end

local function UpdateHealth()
    local now = GetTime()
    local units = GK.VisibleUnits()
    local counts = TargetCounts()
    local efc = GK.GetEFC and GK.GetEFC()
    local targetName = GK.FullName("target")
    local alive, total = 0, 0
    for _, row in ipairs(rows) do
        if row.enemy and row:IsShown() then total = total + 1 end
        local e = row.enemy
        if e and row:IsShown() then
            local short = GK.ShortName(e.name)
            local unit = units[e.name] or units[short]
            if not unit and efc and (efc == e.name or efc == short) then
                unit = GK.EnemyCarrierUnit()
            end
            row.isDead = IsDead(e.name, unit, now)
            if row.isDead then
                if not row.wasDead then
                    row.wasDead = true
                    row.flashAnim:Play()
                    SetDeadLook(row, true)
                end
                row.bar:SetMinMaxValues(0, 1)
                row.bar:SetValue(1)
                row.power:SetValue(0)
                row.hp:SetText("|cffff5a5aDEAD|r")
                SetRange(row, true)
            else
                if row.wasDead then
                    row.wasDead = nil
                    SetDeadLook(row, false)
                    row.hp:SetText("")
                    row.power:SetValue(1)
                end
                if unit and not e.classToken then
                    -- Scoreboard class can be hidden mid-match; read it off the unit.
                    local _, token = UnitClass(unit)
                    token = GK.Plain(token)
                    if token then
                        e.classToken = token
                        classCache[e.name] = token
                        SetClassLook(row, token)
                    end
                end
                if unit and GK.SetHealthBar(row.bar, unit) then
                    GK.SetHealthText(row.hp, unit, "hp")
                    GK.SetPowerBar(row.power, unit)
                    local _, token = UnitPowerType(unit)
                    token = GK.Plain(token)
                    if token then SetPowerColor(row, token) end
                    row.lastSeen = now
                    -- No spell to check with: being visible counts as in range.
                    local inRange = InRange(unit)
                    if not GK.IsSecret(inRange) and inRange == nil then inRange = true end
                    SetRange(row, inRange)
                else
                    -- Not visible anywhere: almost always far away.
                    -- Health shown is the last known value.
                    SetRange(row, false)
                end
            end
            local isCarrier = efc ~= nil and (efc == e.name or efc == short)
            if isCarrier then
                -- The enemy carrier holds our flag.
                row.flag:SetTexture(UnitFactionGroup("player") == "Horde" and 132485 or 132486)
            end
            row.flag:SetShown(isCarrier)
            if isCarrier ~= row.carrierGlow:IsShown() then
                row.carrierGlow:SetShown(isCarrier)
                if isCarrier then row.carrierGlow.pulse:Play() else row.carrierGlow.pulse:Stop() end
            end
            row.targetMark:SetShown(targetName ~= nil and (targetName == e.name or targetName == short))
            if not row.isDead then alive = alive + 1 end
            local n = counts[e.name] or counts[short]
            row.targets:SetText(n and n > 0 and tostring(n) or "")
        end
    end
    Enemies:UpdateHeader(alive, total)
end

function Enemies:Init()
    local f = CreateFrame("Frame", "FlagCarriersEnemies", UIParent)
    f:SetSize(ROW_W, HEADER_H + MAX_ROWS * (ROW_H + GAP))

    -- Header: faction name, alive count, and an accent line.
    local h = f:CreateFontString(nil, "OVERLAY")
    h:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    h:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 1, -HEADER_H + 6)
    f.title = h
    local count = f:CreateFontString(nil, "OVERLAY")
    count:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    count:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -1, -HEADER_H + 6)
    f.count = count
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", 0, -HEADER_H + 4)
    line:SetPoint("TOPRIGHT", 0, -HEADER_H + 4)
    line:SetHeight(2)
    line:SetTexture(FLAT)
    f.line = line
    -- Sit above the objective tracker, which otherwise eats clicks on some rows.
    f:SetFrameStrata("HIGH")
    for i = 1, MAX_ROWS do rows[i] = MakeRow(f, i) end
    -- Default spot roughly where your BattleGroundEnemies frame was.
    GK.MakeMovable(f, "Enemies", { "TOPRIGHT", "TOPRIGHT", -150, -250 })
    self.frame = f

    f:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
    f:RegisterEvent("PLAYER_ENTERING_BATTLEGROUND")
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", GK.Safe("Enemies event", function(_, event)
        if event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
            -- New zone: drop the old match's players right away.
            wipe(deathInfo)
            wipe(classCache)
            pendingRoster = nil
            waitingForFreshScore = true
            if not InCombatLockdown() then ApplyRoster({}) end
            if GK.InBattleground() and RequestBattlefieldScoreData then RequestBattlefieldScoreData() end
            return
        end
        if event == "UPDATE_BATTLEFIELD_SCORE" then waitingForFreshScore = false end
        UpdateRoster()
    end))

    local hpTick, scoreTick = 0, 0
    f:SetScript("OnUpdate", GK.Safe("Enemies", function(_, dt)
        hpTick, scoreTick = hpTick + dt, scoreTick + dt
        if scoreTick > 3 then
            scoreTick = 0
            if GK.InBattleground() and RequestBattlefieldScoreData then RequestBattlefieldScoreData() end
        end
        if hpTick > 0.2 then
            hpTick = 0
            UpdateHealth()
        end
    end))
end

function Enemies:UpdateHeader(alive, total)
    local f = self.frame
    local enemyFaction = 1 - GK.PlayerFactionIndex()
    local c = FACTION_COLOR[enemyFaction]
    f.title:SetText(enemyFaction == 0 and "HORDE" or "ALLIANCE")
    f.title:SetTextColor(c[1], c[2], c[3])
    if f.line.SetGradient and CreateColor then
        f.line:SetGradient("HORIZONTAL", CreateColor(c[1], c[2], c[3], 1), CreateColor(c[1], c[2], c[3], 0))
    else
        f.line:SetVertexColor(c[1], c[2], c[3], 1)
    end
    local waiting = pendingRoster and math.max(0, #pendingRoster - #roster) or 0
    f.count:SetText(string.format("|cffffffff%d|r|cff8a8a8a/%d|r%s", alive, total,
        waiting > 0 and string.format(" |cffffd100+%d|r", waiting) or ""))
end

function Enemies:OutOfCombat()
    if pendingRoster then ApplyRoster(pendingRoster) end
    if GK.InBattleground() and RequestBattlefieldScoreData then RequestBattlefieldScoreData() end
end

function Enemies:Refresh()
    if not self.frame then return end
    local show = GK.db.enemies and (GK.InBattleground() or GK.ShouldShowAll())
    self.frame:SetShown(show)
    if show then
        roster = {}
        if GK.testMode and not GK.InBattleground() then
            deathInfo.Testmage = { deaths = 1, deadAt = GetTime() } -- preview a dead row
        end
        UpdateRoster()
    end
end
