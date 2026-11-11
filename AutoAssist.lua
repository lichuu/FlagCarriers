local _, GK = ...

-- Port of "Battleground Auto Assist All": if you lead the BG raid, give everyone assist.

local Assist = {}
GK.RegisterModule("AutoAssist", Assist)

local function Apply()
    if not GK.db.autoAssist or not GK.InBattleground() then return end
    if not UnitIsGroupLeader("player") or not SetEveryoneIsAssistant then return end
    if IsEveryoneAssistant and IsEveryoneAssistant() then return end
    pcall(SetEveryoneIsAssistant, true)
end

function Assist:Init()
    local f = CreateFrame("Frame")
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("PARTY_LEADER_CHANGED")
    f:SetScript("OnEvent", GK.Safe("AutoAssist event", Apply))
end

function Assist:Refresh()
    Apply()
end
