local _, GK = ...

-- Port of the "RF: WSG Flag Carrier" WeakAura: puts a flag icon on the
-- Blizzard raid frame of whoever on our team has the enemy flag.

local RaidFlag = {}
GK.RegisterModule("RaidFlag", RaidFlag)

local icon

-- Blizzard raid/party frame names, in the order they're likely to exist.
local frameNames = {}
for i = 1, 40 do frameNames[#frameNames + 1] = "CompactRaidFrame" .. i end
for g = 1, 8 do
    for m = 1, 5 do frameNames[#frameNames + 1] = "CompactRaidGroup" .. g .. "Member" .. m end
end
for i = 1, 5 do frameNames[#frameNames + 1] = "CompactPartyFrameMember" .. i end

local function FindRaidFrame(name)
    for _, frameName in ipairs(frameNames) do
        local f = _G[frameName]
        if f and f:IsVisible() and type(f.unit) == "string" and GK.FullName(f.unit) == name then
            return f
        end
    end
end

local function Update()
    local holder = GK.db.raidFlag and GK.GetOurFC and GK.GetOurFC()
    local frame = holder and FindRaidFrame(holder)
    if not frame then
        icon:Hide()
        return
    end
    icon:ClearAllPoints()
    icon:SetPoint("RIGHT", frame, "RIGHT", -2, 0)
    icon:SetHeight(math.min(24, frame:GetHeight() - 4))
    icon:SetWidth(icon:GetHeight())
    icon:Show()
end

function RaidFlag:Init()
    icon = CreateFrame("Frame", nil, UIParent)
    icon:SetFrameStrata("HIGH")
    local tex = icon:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    -- The flag we're carrying is the enemy's: Alliance flag for Horde players.
    tex:SetTexture(UnitFactionGroup("player") == "Horde" and 132486 or 132485)
    icon.tex = tex
    icon:Hide()

    local elapsed = 0
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", GK.Safe("RaidFlag", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.3 then return end
        elapsed = 0
        if GK.InWSG() then Update() else icon:Hide() end
    end))
end

function RaidFlag:Refresh()
    if icon then
        icon.tex:SetTexture(UnitFactionGroup("player") == "Horde" and 132486 or 132485)
    end
end
