local _, GK = ...

-- Port of the "BG Rez Timer" WeakAura: when several teammates come back to
-- life at once, a spirit healer wave just happened, so the next one is
-- rezInterval seconds later.

local PREFIX = "FlagCarriersRez"
local START_OFFSET = {
    ["Let the battle for Warsong Gulch begin!"] = 5,
    ["The battle for Alterac Valley has begun!"] = 0,
}

local Rez = {}
GK.RegisterModule("RezTimer", Rez)

local nextRez, lastAlive, lastTotal
-- Enemy deaths on the scoreboard, total and at the last wave. The difference
-- is how many enemies will come back at the next wave.
local enemyDeaths, enemyDeathsAtWave = 0, 0

local function CountEnemyDeaths()
    if not GetNumBattlefieldScores then return end
    local mine = GK.PlayerFactionIndex()
    local total = 0
    for i = 1, GetNumBattlefieldScores() do
        local deaths, faction
        if C_PvP and C_PvP.GetScoreInfo then
            local info = C_PvP.GetScoreInfo(i)
            if info then deaths, faction = info.deaths, info.faction end
        else
            local _
            _, _, _, deaths, _, faction = GetBattlefieldScore(i)
        end
        deaths, faction = GK.Plain(deaths), GK.Plain(faction)
        if deaths and faction ~= nil and faction ~= mine then total = total + deaths end
    end
    enemyDeaths = total
    if enemyDeathsAtWave > enemyDeaths then enemyDeathsAtWave = enemyDeaths end
end

-- A spirit healer wave just happened.
local function Wave(now)
    nextRez = now + GK.db.rezInterval
    enemyDeathsAtWave = enemyDeaths
end

local function GroupAlive()
    local alive, total = 0, 0
    local n = GetNumGroupMembers()
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and n or (n - 1)
    for i = 1, count do
        local unit = prefix .. i
        if GK.Plain(UnitExists(unit)) then
            total = total + 1
            local dead = GK.Plain(UnitIsDeadOrGhost(unit))
            if dead == nil then return nil end -- can't read it, give up this tick
            if not dead then alive = alive + 1 end
        end
    end
    if not IsInRaid() then
        total = total + 1
        if not UnitIsDeadOrGhost("player") then alive = alive + 1 end
    end
    return alive, total
end

local function Threshold()
    if GK.InAV() then return GK.db.avRezThreshold end
    return GK.db.wsgRezThreshold
end

local function Active()
    return GK.InWSG() or GK.InAV()
end

function Rez:SendSync()
    if not nextRez then GK.Print("Rez timer isn't running.") return end
    GK.SendAddon(PREFIX, string.format("%.1f", nextRez - GetTime()))
    GK.Print("Sent rez timer to your group.")
end

function Rez:Init()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    end

    local f = CreateFrame("Frame", "FlagCarriersRezTimer", UIParent)
    f:SetSize(160, 36)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    f.text:SetPoint("CENTER")
    GK.MakeMovable(f, "RezTimer", { "TOP", "TOP", 0, -110 })
    self.frame = f

    f:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
    f:RegisterEvent("PLAYER_UNGHOST")
    f:SetScript("OnEvent", GK.Safe("RezTimer event", function(_, event, a1, a2, _, a4)
        if event == "ZONE_CHANGED_NEW_AREA" then
            nextRez, lastAlive, lastTotal = nil, nil, nil
            enemyDeaths, enemyDeathsAtWave = 0, 0
        elseif event == "UPDATE_BATTLEFIELD_SCORE" then
            if Active() then CountEnemyDeaths() end
        elseif event == "PLAYER_UNGHOST" then
            -- Coming back at full health means the spirit healer just rezzed us.
            if Active() and GK.HealthFraction("player") == 1 then
                Wave(GetTime())
                GK.SendAddon(PREFIX, string.format("%.1f", GK.db.rezInterval))
            end
        elseif event == "CHAT_MSG_BG_SYSTEM_NEUTRAL" then
            local offset = START_OFFSET[GK.Plain(a1) or ""]
            if offset then nextRez = GetTime() + GK.db.rezInterval + offset end
        elseif event == "CHAT_MSG_ADDON" and GK.Plain(a1) == PREFIX then
            local remaining = tonumber(GK.Plain(a2) or "")
            if remaining and GK.Plain(a4) ~= GK.FullName("player") then
                nextRez = GetTime() + remaining
            end
        end
    end))

    local elapsed, lastScoreRequest = 0, 0
    f:SetScript("OnUpdate", GK.Safe("RezTimer", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < 0.1 then return end
        elapsed = 0
        local now = GetTime()

        -- While we're dead the game tells us the exact time to the next wave.
        local exact = GetAreaSpiritHealerTime and GK.Plain(GetAreaSpiritHealerTime())
        if exact and exact > 0 then nextRez = now + exact end

        local alive, total = GroupAlive()
        if alive then
            if lastAlive and total == lastTotal and alive >= lastAlive + Threshold() then
                Wave(now)
            end
            lastAlive, lastTotal = alive, total
        end

        if nextRez then
            if nextRez - now <= 0 then
                Wave(now)
            end
            local left = nextRez - now
            -- Refresh enemy deaths just before the wave so the count is current.
            if left <= 2 and now - lastScoreRequest > 1 and RequestBattlefieldScoreData then
                lastScoreRequest = now
                RequestBattlefieldScoreData()
            end
            local color = left < 5 and "|cffff4f4f" or "|cffffffff"
            -- Scoreboard deaths can be hidden mid-match, so also count the
            -- enemies the enemy frames currently show as dead.
            local ressing = math.max(0, enemyDeaths - enemyDeathsAtWave)
            if GK.DeadEnemyCount then ressing = math.max(ressing, GK.DeadEnemyCount()) end
            self.text:SetText(string.format("Rez: %s%.1f|r\nEnemies ressing: %d", color, left, ressing))
        else
            self.text:SetText("Rez: |cff7f7f7f?|r")
        end
    end))
end

function Rez:Refresh()
    if not self.frame then return end
    self.frame:SetShown(GK.db.rezTimer and (Active() or GK.ShouldShowAll()))
end
