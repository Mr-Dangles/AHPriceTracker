-- AH Price Tracker: town services on the world map (auction houses, banks, trainers, vendors ...).
-- The game doesn't tell addons where NPCs stand, so locations are learned: whenever you use a service
-- NPC, your position (you're standing next to them) is saved, and shared with other addon users.
local ADDON, ns = ...

local TRACK = "Interface\\Minimap\\Tracking\\"
ns.TOWN_TYPES = { -- key, label, icon, priority (higher wins when an NPC does several things)
    { "auction", "Auction House", TRACK .. "Auctioneer", 9 },
    { "bank", "Bank", TRACK .. "Banker", 9 },
    { "inn", "Innkeeper", TRACK .. "Innkeeper", 8 },
    { "flight", "Flight Master", TRACK .. "FlightMaster", 8 },
    { "classtrainer", "Class Trainer", TRACK .. "Class", 7 },
    { "proftrainer", "Profession Trainer", TRACK .. "Profession", 7 },
    { "stable", "Stable Master", TRACK .. "StableMaster", 6 },
    { "repair", "Repair", TRACK .. "Repair", 5 },
    { "vendor", "Vendor", TRACK .. "Food", 4 },
    { "mailbox", "Mailbox", TRACK .. "Mailbox", 3 },
}
local TYPE = {}
for _, t in ipairs(ns.TOWN_TYPES) do TYPE[t[1]] = { label = t[2], icon = t[3], prio = t[4] } end
ns.TOWN_TYPE = TYPE

function ns:InitTownServices()
    self.db.townNpcs = self.db.townNpcs or {} -- account-wide: NPCs stand in the same place on every realm
    self.townNpcs = self.db.townNpcs
    self.settings.townPins = self.settings.townPins or {}
    for k in pairs(TYPE) do
        if self.settings.townPins[k] == nil then self.settings.townPins[k] = true end
    end
    if self.settings.townPinsOn == nil then self.settings.townPinsOn = true end
end

---------------------------------------------------------------------------
-- Learning locations
---------------------------------------------------------------------------
local function Safe(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end -- protected values (e.g. in combat)
    return v
end

local function PlayerSpot()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    if not x or x <= 0 or y <= 0 or x >= 1 or y >= 1 then return nil end
    return mapID, x, y
end

-- The NPC you're talking to: npcID, name, title ("<Banker>")
local function CurrentNpc()
    local guid = Safe(UnitGUID("npc"))
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, npcID = strsplit("-", guid)
    if kind ~= "Creature" or not npcID then return nil end
    local name = Safe(UnitName("npc"))
    local title
    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        local ok, data = pcall(C_TooltipInfo.GetUnit, "npc")
        local line = ok and data and data.lines and data.lines[2]
        local text = line and Safe(line.leftText)
        if type(text) == "string" and text:find("^<.+>$") then title = text end
    end
    return tonumber(npcID), name, title
end

-- What a gossip NPC offers, from their title
local function TypeFromTitle(title)
    if not title then return nil end
    local t = title:lower()
    if t:find("innkeeper") then return "inn" end
    if t:find("banker") then return "bank" end
    if t:find("auctioneer") then return "auction" end
    if t:find("stable master") then return "stable" end
    if t:find("flight master") or t:find("wind rider") or t:find("gryphon master") or t:find("hippogryph master")
        or t:find("bat handler") then return "flight" end
    return nil
end

-- Save (or upgrade) a service location. src = nil for your own, or a sync ID for shared ones.
function ns:SaveTownNpc(key, rec, src)
    if not self.townNpcs or not TYPE[rec.type] then return false end
    local old = self.townNpcs[key]
    if old then
        -- Keep the most important service for NPCs that do several things (e.g. vendor + repair)
        if TYPE[old.type].prio > TYPE[rec.type].prio then rec.type = old.type end
        if old.src == nil and src then return false end -- your own sighting beats a shared one
        if old.t and rec.t and old.t >= rec.t and old.type == rec.type then return false end
    end
    rec.src = src
    self.townNpcs[key] = rec
    self.townCache = nil
    if self.RefreshTownPins then self:RefreshTownPins() end
    return true
end

function ns:LearnService(stype)
    if not self.townNpcs then return end
    local mapID, x, y = PlayerSpot()
    if not mapID then return end
    local key, name, title
    if stype == "mailbox" then
        key = string.format("m%d:%d:%d", mapID, math.floor(x * 1000), math.floor(y * 1000))
    else
        local npcID
        npcID, name, title = CurrentNpc()
        if not npcID then return end
        key = npcID
        stype = TypeFromTitle(title) or stype
    end
    local rec = { type = stype, map = mapID, x = math.floor(x * 10000) / 10000, y = math.floor(y * 10000) / 10000,
        name = name, title = title, t = time() }
    if self:SaveTownNpc(key, rec, nil) and self.ShareTownNpc then self:ShareTownNpc(key, self.townNpcs[key]) end
end

local learn = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "BANKFRAME_OPENED", "MERCHANT_SHOW", "TRAINER_SHOW", "TAXIMAP_OPENED",
    "PET_STABLE_SHOW", "GOSSIP_SHOW", "MAIL_SHOW" }) do
    pcall(learn.RegisterEvent, learn, e)
end
learn:SetScript("OnEvent", function(_, event)
    if not ns.townNpcs then return end
    if event == "AUCTION_HOUSE_SHOW" then ns:LearnService("auction")
    elseif event == "BANKFRAME_OPENED" then ns:LearnService("bank")
    elseif event == "MERCHANT_SHOW" then ns:LearnService((CanMerchantRepair and CanMerchantRepair()) and "repair" or "vendor")
    elseif event == "TRAINER_SHOW" then
        local prof = IsTradeskillTrainer and IsTradeskillTrainer()
        ns:LearnService(prof and "proftrainer" or "classtrainer")
    elseif event == "TAXIMAP_OPENED" then ns:LearnService("flight")
    elseif event == "PET_STABLE_SHOW" then ns:LearnService("stable")
    elseif event == "MAIL_SHOW" then ns:LearnService("mailbox")
    elseif event == "GOSSIP_SHOW" then
        local _, _, title = CurrentNpc()
        local t = TypeFromTitle(title)
        if t then ns:LearnService(t) end
    end
end)

---------------------------------------------------------------------------
-- World map pins
---------------------------------------------------------------------------
local pins, nPins = {}, 0
local PIN_SIZE = 18

-- Position of a saved NPC on another map (e.g. a city's NPCs on the surrounding zone map)
local function Translate(n, mapID)
    if n.map == mapID then return n.x, n.y end
    ns.townCache = ns.townCache or {}
    local ck = n.map .. ":" .. n.x .. ":" .. n.y .. ":" .. mapID
    local hit = ns.townCache[ck]
    if hit ~= nil then
        if hit then return hit[1], hit[2] end
        return nil
    end
    local result = false
    local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, n.map, CreateVector2D(n.x, n.y))
    if ok and cont and world then
        local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, mapID)
        if ok2 and pos then
            local x, y = pos:GetXY()
            if x and x > 0 and x < 1 and y > 0 and y < 1 then result = { x, y } end
        end
    end
    ns.townCache[ck] = result
    if result then return result[1], result[2] end
end

local function PinTooltip(pin)
    local n = pin.npc
    if not n then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:AddLine(n.name or TYPE[n.type].label, 1, 1, 1)
    if n.title then GameTooltip:AddLine(n.title, 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(TYPE[n.type].label, 1, 0.82, 0)
    GameTooltip:AddLine(n.src and "Shared by another addon user" or "Found by you", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function AcquirePin(canvas)
    nPins = nPins + 1
    local p = pins[nPins]
    if not p then
        p = CreateFrame("Button", nil, canvas)
        p:SetFrameStrata("HIGH")
        p.tex = p:CreateTexture(nil, "OVERLAY")
        p.tex:SetAllPoints()
        p:SetScript("OnEnter", PinTooltip)
        p:SetScript("OnLeave", GameTooltip_Hide)
        pins[nPins] = p
    end
    return p
end

function ns:RefreshTownPins()
    if not (WorldMapFrame and WorldMapFrame:IsShown() and self.townNpcs) then return end
    nPins = 0
    local mapID = WorldMapFrame:GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    -- Only on zone, city and smaller maps; continents would be a sea of icons
    if self.settings.townPinsOn and info and info.mapType and info.mapType >= 3 then
        local canvas = WorldMapFrame:GetCanvas()
        local w, h = canvas:GetWidth(), canvas:GetHeight()
        local scale = WorldMapFrame:GetCanvasScale() or 1
        for _, n in pairs(self.townNpcs) do
            if TYPE[n.type] and self.settings.townPins[n.type] then
                local x, y = Translate(n, mapID)
                if x then
                    local p = AcquirePin(canvas)
                    local size = (n.map == mapID and PIN_SIZE or PIN_SIZE * 0.8) / scale
                    p:SetSize(size, size)
                    p:ClearAllPoints()
                    p:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
                    p.tex:SetTexture(TYPE[n.type].icon)
                    p.npc = n
                    p:Show()
                end
            end
        end
    end
    for i = nPins + 1, #pins do pins[i]:Hide() end
    self.townPinScale = WorldMapFrame:GetCanvasScale()
end

-- Services button on the world map
local function TypeMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        ns.settings.townPinsOn = not ns.settings.townPinsOn
        ns:RefreshTownPins()
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Town services")
        root:CreateCheckbox("Show service icons", function() return ns.settings.townPinsOn end,
            function() ns.settings.townPinsOn = not ns.settings.townPinsOn; ns:RefreshTownPins() end)
        root:CreateDivider()
        for _, t in ipairs(ns.TOWN_TYPES) do
            local key = t[1]
            root:CreateCheckbox("|T" .. t[3] .. ":14:14|t " .. t[2], function() return ns.settings.townPins[key] end,
                function() ns.settings.townPins[key] = not ns.settings.townPins[key]; ns:RefreshTownPins() end)
        end
        root:CreateDivider()
        local n = 0
        for _ in pairs(ns.townNpcs or {}) do n = n + 1 end
        root:CreateTitle(n .. " locations known")
    end)
end

local function SetupWorldMap()
    if ns.townMapHooked or not WorldMapFrame then return end
    ns.townMapHooked = true
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function() ns:RefreshTownPins() end)
    WorldMapFrame:HookScript("OnShow", function() ns:RefreshTownPins() end)
    -- Keep icons the same size on screen while zooming
    local watcher = CreateFrame("Frame", nil, WorldMapFrame)
    watcher:SetScript("OnUpdate", function()
        local s = WorldMapFrame:GetCanvasScale()
        if s and s ~= ns.townPinScale then ns:RefreshTownPins() end
    end)
    local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(76, 20)
    b:SetText("Services")
    b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -8)
    b:SetFrameStrata("HIGH")
    b:SetScript("OnClick", TypeMenu)
    b:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Town services")
        GameTooltip:AddLine("Auction houses, banks, trainers, vendors and more. Locations are learned when you or another addon user use them.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    if WorldMapFrame then SetupWorldMap() end
end)

---------------------------------------------------------------------------
-- Minimap tracking for service NPCs (/aht tracking)
---------------------------------------------------------------------------
function ns:EnableServiceTracking()
    if not (C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.SetTracking) then
        self.Print("Minimap tracking isn't available in this client.")
        return
    end
    local WANT = { "banker", "auctioneer", "innkeeper", "flight master", "stable master", "trainer", "repair",
        "mailbox", "food", "vendor", "reagent", "poison" }
    local turned = {}
    for i = 1, C_Minimap.GetNumTrackingTypes() do
        local info = C_Minimap.GetTrackingInfo(i)
        local name = info and info.name
        if name then
            local l = name:lower()
            for _, w in ipairs(WANT) do
                if l:find(w, 1, true) then
                    if not info.active then C_Minimap.SetTracking(i, true); turned[#turned + 1] = name end
                    break
                end
            end
        end
    end
    if #turned > 0 then
        self.Print("Minimap tracking turned on: %s.", table.concat(turned, ", "))
    else
        self.Print("All service tracking is already on (or none is available).")
    end
end
