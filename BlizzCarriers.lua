local _, GK = ...

-- Moves Blizzard's flag carrier frames (ArenaEnemyMatchFrame1/2, which you can
-- click to target the carrier) up by the flags at the top of the screen.
-- They're protected frames, so they can only be moved out of combat.

local Carriers = {}
GK.RegisterModule("BlizzCarriers", Carriers)

local anchor
local moving = false

local function Container()
    return _G.ArenaEnemyFramesContainer
        or (_G.ArenaEnemyMatchFrame1 and _G.ArenaEnemyMatchFrame1:GetParent())
end

-- The "0/3" capture count FontString on the top flag row, so the carrier
-- frames can sit right after it instead of past the whole widget area.
local function TopFlagCount()
    local container = _G.UIWidgetTopCenterContainerFrame
    if not container then return nil end
    local best
    local function scan(frame, depth)
        if depth > 3 then return end
        for _, region in ipairs({ frame:GetRegions() }) do
            if region:GetObjectType() == "FontString" and region:IsVisible() then
                local text = GK.Plain(region:GetText())
                local top = region:GetTop()
                if type(text) == "string" then
                    -- Drop colour codes like |cffffffff ... |r before matching.
                    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                end
                if type(text) == "string" and text:match("^%s*%d+%s*/%s*%d+%s*$") and top then
                    if not best or top > best:GetTop() then best = region end
                end
            end
        end
        for _, child in ipairs({ frame:GetChildren() }) do scan(child, depth + 1) end
    end
    scan(container, 0)
    return best
end

local PlaceUnsafe
local function Place()
    local ok, err = pcall(PlaceUnsafe)
    moving = false
    if not ok and not Carriers.reported then
        Carriers.reported = true
        GK.Print("|cffff4f4fCarrier frames couldn't be moved:|r " .. tostring(err))
    end
end

function PlaceUnsafe()
    if not GK.db.moveBlizzCarriers or InCombatLockdown() or moving then return end
    local c = Container()
    if not c or not anchor then return end
    moving = true
    -- Default: just right of the flag rows (leaving room for Blizzard's
    -- carried-flag icon). A spot you dragged to wins.
    if not GK.db.positions["Carrier frames"] then
        local count = TopFlagCount()
        local widgets = _G.UIWidgetTopCenterContainerFrame
        anchor:ClearAllPoints()
        -- Blizzard's frames are protected and can't hang off text (or off
        -- Blizzard's widget frames), so convert the spot to plain screen
        -- coordinates on UIParent.
        local ref, refX, refY
        if count and count:GetRight() then
            ref, refX, refY = count, count:GetRight() + 34, count:GetTop() + 6
        elseif widgets and widgets:GetBottom() then
            ref, refX, refY = widgets, (widgets:GetLeft() + widgets:GetRight()) / 2 - 60, widgets:GetBottom() - 4
        end
        if ref then
            local k = ref:GetEffectiveScale() / anchor:GetEffectiveScale()
            anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", refX * k, refY * k)
        else
            GK.RestorePosition(anchor)
        end
    end
    c:SetScale(anchor:GetScale())
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    moving = false
end

local hooked = false
local function Hook()
    local c = Container()
    if hooked or not c then return end
    hooked = true
    -- Blizzard's layout puts the frames back on the right; move them again.
    hooksecurefunc(c, "SetPoint", function()
        if not moving then C_Timer.After(0, Place) end
    end)
end

function Carriers:Init()
    anchor = CreateFrame("Frame", "FlagCarriersCarrierAnchor", UIParent)
    anchor:SetSize(150, 60)
    anchor.gkDefaultScale = 0.8
    anchor.gkOnScale = function() if not InCombatLockdown() then Place() end end
    GK.MakeMovable(anchor, "Carrier frames", { "TOP", "TOP", 0, -75 })
    anchor.gkHandle:HookScript("OnDragStop", Place)

    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("ARENA_OPPONENT_UPDATE")
    f:RegisterEvent("ADDON_LOADED")
    -- The flag display may be built after we load; place again when it updates.
    f:RegisterEvent("UPDATE_UI_WIDGET")
    local queued = false
    f:SetScript("OnEvent", GK.Safe("BlizzCarriers event", function(_, event)
        Hook()
        if event == "UPDATE_UI_WIDGET" then
            -- These fire often; place at most once a second.
            if queued then return end
            queued = true
            C_Timer.After(1, function() queued = false; Place() end)
            return
        end
        Place()
    end))
end

-- /fc debug: what the placement code can see.
function Carriers:Debug()
    local c = Container()
    GK.Print("carrier frames container: " .. (c and (c:GetName() or "unnamed") or "NOT FOUND"))
    if c then
        local p, rel, rp, x, y = c:GetPoint()
        GK.Print(string.format("  anchored %s to %s %s (%.0f, %.0f), scale %.2f", tostring(p),
            rel and (rel:GetName() or "unnamed") or "nil", tostring(rp), x or 0, y or 0, c:GetScale()))
    end
    local count = TopFlagCount()
    GK.Print("flag count text: " .. (count and ("found: " .. tostring(GK.Plain(count:GetText()))) or "NOT FOUND"))
    GK.Print("saved carrier position: " .. (GK.db.positions["Carrier frames"] and "yes (use /fc reset)" or "no"))
    GK.Print("move enabled: " .. tostring(GK.db.moveBlizzCarriers) .. ", in combat: " .. tostring(InCombatLockdown()))
end

function Carriers:OutOfCombat()
    Hook()
    Place()
end

function Carriers:Refresh()
    Hook()
    Place()
end
