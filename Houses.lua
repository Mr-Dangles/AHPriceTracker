-- AH Price Tracker: separate auction houses
--
-- Forever has more than one auction house per realm:
--   * your faction's house: Orgrimmar, Undercity and Thunder Bluff share one (Stormwind, Ironforge and
--     Darnassus share the Alliance one),
--   * the neutral goblin house: Booty Bay, Gadgetzan, Everlook and Auctioneer Quickcoin (the Crossroads
--     and Redridge), open to both factions, with a bigger cut,
--   * any other auctioneer we don't recognise gets a house of its own until we know better.
-- Each house keeps its own scans, sales timeline, Flip Finder prices and auction list, so a sold-out
-- item at the goblins never looks like a sell-out in Orgrimmar. The watch list is shared by all houses.
local ADDON, ns = ...

-- Auctioneer NPC IDs (Wowhead, WoW Forever database)
local NEUTRAL = {
    [258878] = true, -- Auctioneer Quickcoin (The Crossroads, Redridge)
    [9858] = true, [15677] = true, [15681] = true, -- Booty Bay: Kresky, Graves, O'reely
    [8661] = true, -- Gadgetzan: Beardo
    [9857] = true, -- Everlook: Grizzlin
}
local FACTION = {}
for _, id in ipairs({
    8673, 9856, 8724,                                       -- Orgrimmar
    15676, 15686, 15684, 8721, 15682, 15683, 8672, 15675,   -- Undercity
    8722, 8674,                                             -- Thunder Bluff
    8670, 15659, 8719,                                      -- Stormwind
    9859, 8671, 8720,                                       -- Ironforge
    8723, 15679, 8669, 15678,                               -- Darnassus
}) do FACTION[id] = true end

ns.HOUSE_CUT = { neutral = 0.15 } -- everything else: 5%

function ns:AHCut(house)
    return self.HOUSE_CUT[house or self.house or "home"] or 0.05
end

function ns:HouseLabel(key, short)
    key = key or self.house or "home"
    if key == "home" then
        local side = UnitFactionGroup("player") or "Horde"
        return short and side or (side .. " auction house")
    elseif key == "neutral" then
        return short and "Neutral" or "Neutral (goblin) auction house"
    end
    local h = self.realmData and self.realmData.houses and self.realmData.houses[key]
    local where = h and h.label or key
    return short and where or ("Auctioneer in " .. where)
end

-- Which house the auctioneer you're talking to belongs to.
function ns:DetectHouse()
    local ok, guid = pcall(UnitGUID, "npc")
    if not ok or not guid or (issecretvalue and issecretvalue(guid)) then return "home" end
    local kind, _, _, _, _, npc = strsplit("-", guid)
    npc = tonumber(npc)
    if kind ~= "Creature" or not npc then return "home" end
    if NEUTRAL[npc] then return "neutral" end
    if FACTION[npc] then return "home" end
    return "npc" .. npc, GetRealZoneText and GetRealZoneText() or nil
end

-- The saved tables for a house. Your faction's house uses the realm's own tables (as before v1.8).
function ns:HouseData(key, create)
    key = key or self.house or "home"
    local rd = self.realmData
    if key == "home" then
        rd.stackFixed = rd.stackFixed or {}
        rd.ownedBy = rd.ownedBy or {}
        return rd
    end
    rd.houses = rd.houses or {}
    local h = rd.houses[key]
    if not h and create == false then return nil end
    if not h then
        h = { items = {}, flipPrices = {}, sales = {}, syncBuys = {}, unitPending = {}, stackFixed = {}, ownedBy = {} }
        rd.houses[key] = h
    end
    return h
end

-- Every house this realm has data for: { "home", "neutral", ... }
function ns:KnownHouses()
    local out = { "home" }
    local rd = self.realmData
    if rd.houses and rd.houses.neutral then out[#out + 1] = "neutral" end
    for k in pairs(rd.houses or {}) do if k ~= "neutral" then out[#out + 1] = k end end
    return out
end

local function Bind(self, h)
    self.items, self.flipPrices, self.sales, self.syncBuys = h.items, h.flipPrices, h.sales, h.syncBuys
    self.unitPending = h.unitPending
end

-- Run fn with another house's tables in place (incoming shared data, other houses' auctions).
function ns:WithHouse(key, fn, ...)
    key = key or "home"
    if key == (self.house or "home") then return fn(...) end
    local saved = { self.items, self.flipPrices, self.sales, self.syncBuys, self.unitPending, self.house, self.salesCache }
    self.house = key
    self.salesCache = {}
    -- (a house this realm has no data for, e.g. another realm's auctions, reads as empty)
    Bind(self, self:HouseData(key, false) or { items = {}, flipPrices = {}, sales = {}, syncBuys = {}, unitPending = {} })
    local ok, a, b, c = pcall(fn, ...)
    self.items, self.flipPrices, self.sales, self.syncBuys, self.unitPending, self.house, self.salesCache = unpack(saved, 1, 7)
    if not ok then geterrorhandler()(a) end
    return a, b, c
end

-- Switch every page to another house.
function ns:SetHouse(key, label, quiet)
    key = key or "home"
    local h = self:HouseData(key)
    if label then h.label = label end
    if self.house == key then return end
    self.house = key
    -- Everything you track in any house is tracked here too.
    local function copy(src)
        for id, e in pairs(src or {}) do
            if not h.items[id] then
                h.items[id] = { id = id, added = e.added, lastScan = 0, lastAttempt = 0, history = {},
                    name = e.name, link = e.link, icon = e.icon }
            end
        end
    end
    copy(self.realmData.items)
    for _, other in pairs(self.realmData.houses or {}) do copy(other.items) end
    Bind(self, h)
    local me = UnitName("player") or "?"
    h.ownedBy[me] = h.ownedBy[me] or { t = 0, list = {} }
    self.owned = h.ownedBy[me]
    if self.salesCache then wipe(self.salesCache) end
    if self.flipQueue then wipe(self.flipQueue) end
    self.mktCache, self.profitCache = nil, nil
    if self.selected and not self.items[self.selected] then self.selected = nil end
    if not quiet then
        self.Print("Showing data for the %s%s.", self:HouseLabel(key),
            key == "neutral" and " (separate from your faction's auction house; 15% cut)" or "")
        if self.SendHello then C_Timer.After(2, function() ns:SendHello() end) end
    end
    if self.UpdateHouseButton then self:UpdateHouseButton() end
    if self.frame and self.frame:IsShown() and self.RefreshAll then self:RefreshAll() end
end

-- Stopping tracking an item stops it in every house.
hooksecurefunc(ns, "RemoveItem", function(self, id)
    if self.realmData.items then self.realmData.items[id] = nil end
    for _, h in pairs(self.realmData.houses or {}) do h.items[id] = nil end
end)

-- Opening the AH picks the house before anything is scanned (Core's AH handler calls this first).
function ns:OnHouseOpened()
    local key, label = self:DetectHouse()
    self:SetHouse(key, label)
end
