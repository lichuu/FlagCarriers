local _, GK = ...

local ALLY_ICON, HORDE_ICON, MID_ICON, FLAG_ICON = 132486, 132485, 136212, 133217
local BLUE, RED, GOLD, CYAN = "|cff4fa3ff", "|cffff4f4f", "|cffffd100", "|cff61f7ff"

-- Same spots and messages as the "!WSG Callout Bar (Both Factions)" WeakAura.
local SPOTS = {
    { "FR", "Flag Room" }, { "TUN", "Tunnel" }, { "TOT", "TOT (Top of Tunnel)" },
    { "ROOF", "Roof/Banana" }, { "RAMP", "Ramp" }, { "GY", "GY" },
    { "LEAF", "Leaf Hut" }, { "ZERK", "Zerk Hut" }, { "CON", "Connector" },
    { "2ND", "2nd Lvl" },
}

local rows = { {}, {}, {} }
for _, s in ipairs(SPOTS) do
    rows[1][#rows[1] + 1] = { label = BLUE .. s[1], icon = ALLY_ICON, msg = "EFC Is Alliance " .. s[2] }
    rows[2][#rows[2] + 1] = { label = RED .. s[1], icon = HORDE_ICON, msg = "EFC Is Horde " .. s[2] }
end
rows[3] = {
    { label = CYAN .. "MID", icon = MID_ICON, msg = "EFC Is Midfield" },
    { label = CYAN .. "TREE", icon = MID_ICON, msg = "EFC Is Mid (Tree Stump)" },
    { label = CYAN .. "TOP", icon = MID_ICON, msg = "EFC Is TOPSIDE (Alternating Ramp/GY/TOT)" },
    { label = GOLD .. "PICK", icon = FLAG_ICON, msg = "---PICK UP FLAG---" },
    { label = GOLD .. "CAP", icon = FLAG_ICON, msg = "---CAP---" },
    { label = RED .. "LOW", icon = FLAG_ICON, msg = ">>> EFC LOW - NUKE <<<" },
}

local SIZE, GAP = 34, 2

local Callouts = {}
GK.RegisterModule("Callouts", Callouts)

local buttons = {}

-- Forever blocks addons from sending chat directly, so each button is a
-- secure macro button: clicking it runs "/i <message>" like a player macro.
local function ChatSlash()
    local channel = GK.ChatChannel()
    if channel == "INSTANCE_CHAT" then return "/i " end
    if channel == "RAID" then return "/ra " end
    if channel == "PARTY" then return "/p " end
    return "/s "
end

local function UpdateMacros()
    if InCombatLockdown() then return end
    local slash = ChatSlash()
    for _, b in ipairs(buttons) do
        b:SetAttribute("macrotext", slash .. b.msg)
    end
end

local function MakeButton(parent, spec)
    local b = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    b:SetSize(SIZE, SIZE)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "macro")
    b.msg = spec.msg
    buttons[#buttons + 1] = b

    b.icon = b:CreateTexture(nil, "BACKGROUND")
    b.icon:SetAllPoints()
    b.icon:SetTexture(spec.icon)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:SetAlpha(0.85)

    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "THICKOUTLINE")
    b.text:SetPoint("CENTER", 1, 0)
    b.text:SetText(spec.label)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(spec.msg, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

function Callouts:Init()
    local width = #rows[1] * (SIZE + GAP) - GAP
    local height = #rows * (SIZE + GAP) - GAP
    local f = CreateFrame("Frame", "FlagCarriersCallouts", UIParent)
    f:SetSize(width, height)
    f:SetFrameStrata("HIGH")
    for r, row in ipairs(rows) do
        -- Centre short rows under the full ones.
        local offset = (width - (#row * (SIZE + GAP) - GAP)) / 2
        for c, spec in ipairs(row) do
            local b = MakeButton(f, spec)
            b:SetPoint("TOPLEFT", offset + (c - 1) * (SIZE + GAP), -(r - 1) * (SIZE + GAP))
        end
    end
    GK.MakeMovable(f, "Callouts", { "CENTER", "CENTER", 460, -230 })
    self.frame = f

    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", GK.Safe("Callouts event", UpdateMacros))
    UpdateMacros()
end

function Callouts:OutOfCombat()
    UpdateMacros()
end

function Callouts:Refresh()
    if not self.frame then return end
    UpdateMacros()
    self.frame:SetShown(GK.db.callouts and (GK.InWSG() or GK.ShouldShowAll()))
end
