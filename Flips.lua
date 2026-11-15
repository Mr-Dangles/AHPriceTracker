-- AH Price Tracker: Flip Finder data
--   * learns vendor buy prices whenever you open a merchant (and imports Auctionator's vendor cache)
--   * records AH prices for those items from your scans / searches
--   * works out profit after the AH cut
local ADDON, ns = ...

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RESCAN_AFTER = 15 * 60 -- "Scan AH" skips items scanned more recently than this
local CALLER = "AHPriceTracker"

function ns:InitFlips()
    self.db.vendor = self.db.vendor or {}           -- vendor prices are the same on every realm
    self.vendor = self.db.vendor
    self.realmData.flipPrices = self.realmData.flipPrices or {}
    self.flipPrices = self.realmData.flipPrices
    self.flipQueue = {}
    self.db.crafted = self.db.crafted or {}         -- items made by a profession (learned from profession windows)
    self.crafted = self.db.crafted
    self:ImportAuctionatorVendorPrices()
end

---------------------------------------------------------------------------
-- Learning which items are crafted (open any profession window)
---------------------------------------------------------------------------
function ns:MarkCrafted(id, share)
    if not id or id <= 0 or self.crafted[id] then return false end
    self.crafted[id] = true
    if share and self.ShareCrafted then self:ShareCrafted(id) end
    return true
end

function ns:ScanProfession()
    if not self.crafted then return end
    local learned = 0
    if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
        local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
        for _, rid in ipairs(ok and ids or {}) do
            local ok2, s = pcall(C_TradeSkillUI.GetRecipeSchematic, rid, false)
            if ok2 and s and self:MarkCrafted(s.outputItemID, true) then learned = learned + 1 end
        end
    end
    if GetNumTradeSkills and GetTradeSkillItemLink then -- older profession window
        for i = 1, GetNumTradeSkills() do
            if self:MarkCrafted(self.LinkID(GetTradeSkillItemLink(i)), true) then learned = learned + 1 end
        end
    end
    if learned > 0 then
        self.Print("Learned %d crafted item%s for the Flip Finder's item filters.", learned, learned == 1 and "" or "s")
        self:OnFlipsUpdated()
    end
end

-- Auctionator remembers vendor prices from merchants you've visited; reuse them.
function ns:ImportAuctionatorVendorPrices()
    local cache = _G.AUCTIONATOR_VENDOR_PRICE_CACHE
    if type(cache) ~= "table" then return 0 end
    local n = 0
    for k, v in pairs(cache) do
        local id = tonumber(k)
        if id and type(v) == "number" and v > 0 and not self.vendor[id] then
            self.vendor[id] = { price = v, source = "Auctionator" }
            n = n + 1
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Learning vendor prices
---------------------------------------------------------------------------
local function MerchantItem(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if info then return info.price, info.stackCount, info.numAvailable, info.hasExtendedCost end
    elseif GetMerchantItemInfo then
        local _, _, price, stack, avail, _, _, ext = GetMerchantItemInfo(i)
        return price, stack, avail, ext
    end
end

function ns:ScanMerchant()
    if not self.vendor or not GetMerchantNumItems then return end
    local who = UnitName("npc")
    local learned = 0
    for i = 1, GetMerchantNumItems() do
        local price, stack, avail, ext = MerchantItem(i)
        local id = (GetMerchantItemID and GetMerchantItemID(i)) or self.LinkID(GetMerchantItemLink(i))
        if id and price and price > 0 and not ext then
            local per = price / math.max(1, stack or 1)
            if not self.vendor[id] or self.vendor[id].price ~= per then
                if not self.vendor[id] then learned = learned + 1 end
                if self.ShareVendor then self:ShareVendor(id, per) end
            end
            self.vendor[id] = {
                price = price / math.max(1, stack or 1), -- per item
                stack = (stack and stack > 1) and stack or nil, -- the vendor sells this many at a time
                limited = (avail and avail >= 0) or nil,
                vendor = who, t = time(),
            }
        end
    end
    if learned > 0 then
        self.Print("Learned %d new vendor price%s for the Flip Finder.", learned, learned == 1 and "" or "s")
        self:OnFlipsUpdated()
    end
end

---------------------------------------------------------------------------
-- AH prices for vendor items
---------------------------------------------------------------------------
function ns:RecordFlipPrice(id, listings, total)
    local minP, loaded = nil, 0
    for _, l in ipairs(listings) do
        if not minP or l[1] < minP then minP = l[1] end
        loaded = loaded + l[2]
    end
    self.flipPrices[id] = { min = minP or false, qty = total or loaded, t = time() }
    self:OnFlipsUpdated()
end

-- Which prices to use everywhere: "mix" (freshest of all), "local" (in-game scans: yours, other addon
-- users', Auctionator) or "online" (auctionhouse.fyi only).
ns.PRICE_SOURCES = {
    { "mix", "Mixed", "The freshest price from any source: your scans, other addon users' scans, or auctionhouse.fyi." },
    { "local", "Game scans", "Only prices scanned in game: by you, by other players running this addon, or by Auctionator." },
    { "online", "Online", "Only auctionhouse.fyi (run Update Market Data.bat, then /reload, to refresh it)." },
}
function ns:PriceSource() return self.settings.priceSource or "mix" end

-- Freshest AH price we know, from the sources allowed by the price-source setting:
-- { price, qty, t, source, none }
function ns:GetAHPrice(id, mode)
    mode = mode or self:PriceSource()
    local useLocal, useOnline = mode ~= "online", mode ~= "local"
    local best
    -- Saved scans from before v1.5.1 aren't trusted until the item is scanned again.
    if useLocal and not (self.unitPending and self.unitPending[id]) then
        -- A lone empty scan right after a non-empty one is usually a search that hadn't loaded yet:
        -- keep showing the last confirmed listings until the next scan agrees it's empty.
        local s = self.sales and self.sales[id]
        local snaps = s and s.snaps
        local IsEmpty = ns.IsEmptySnap
        local unconfirmedEmpty = snaps and IsEmpty and #snaps >= 2 and IsEmpty(snaps[#snaps]) and not IsEmpty(snaps[#snaps - 1])
        local fp = self.flipPrices and self.flipPrices[id]
        if fp and fp.min == false and unconfirmedEmpty then fp = nil end
        if fp then
            best = { price = fp.min or nil, qty = fp.qty, t = fp.t, none = fp.min == false,
                source = fp.shared and "another addon user" or "your scan" }
        end
        local e = self.items and self.items[id]
        local p = e and self:Latest(e)
        if p and not p[2] and unconfirmedEmpty then p = nil end
        if p and (not best or p[1] > best.t) then
            best = { price = p[2] or nil, qty = p[4], t = p[1], none = not p[2],
                source = p.shared and "another addon user" or "price tracker" }
        end
        -- Latest scan from the sales timeline: yours, or shared by another addon user.
        local sn = snaps and snaps[#snaps]
        if unconfirmedEmpty then sn = snaps[#snaps - 1] end
        if sn and (not best or sn.t > best.t) then
            local mine = self.SyncID and sn.src == self:SyncID()
            best = { price = sn.min or nil, qty = sn.total, t = sn.t, source = mine and "your scan" or "another addon user",
                none = not sn.min }
        end
    end
    if useOnline then
        local site = self.GetSitePrice and self:GetSitePrice(id)
        if site and site.t and (not best or not best.t or site.t > best.t) then
            best = { price = site.price, qty = site.qty, t = site.t, source = "auctionhouse.fyi", none = site.none }
        end
    end
    if not best and useLocal and (self.house or "home") == "home" and Auctionator and Auctionator.API and Auctionator.API.v1 then
        local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, CALLER, id)
        if ok and price then
            local ok2, age = pcall(Auctionator.API.v1.GetAuctionAgeByItemID, CALLER, id)
            best = { price = price, t = (ok2 and age) and (time() - age * 86400) or nil, source = "Auctionator" }
        end
    end
    return best
end

function ns:DisplayPrice(id) return self:GetAHPrice(id) end

local function NewRow(self, id)
    local name, link, _, _, _, _, _, maxStack, _, _, sellPrice, classID, subclassID = GetItemInfo(id)
    if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    local mname = self.MarketName and self:MarketName(id)
    if not classID then
        local d = _G.AHPT_MarketData
        local c = d and d.names and d.names[id]
        classID, subclassID = c and c[6] or nil, c and c[7] or nil
    end
    return {
        id = id, name = name or mname or ("Item " .. id), link = link, maxStack = maxStack,
        classID = classID, subclassID = subclassID,
        gameSell = sellPrice, -- what a vendor pays you, straight from the game (nil until the item is cached)
        icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id),
        ah = self:GetAHPrice(id),
        sales = self.SalesEstimate and self:SalesEstimate(id),
    }
end

local function AddVolume(r)
    -- Volume: what the market actually absorbs per day (from scans by you and other addon users).
    r.soldDay = r.sales and r.sales.perDay
    if r.soldDay then
        if r.profit then r.profitDay = r.profit * r.soldDay end
        if r.soldDay > 0 then r.daysFor20 = 20 / r.soldDay end
        if r.ah and r.ah.qty and r.soldDay > 0 then r.supplyDays = r.ah.qty / r.soldDay end
    end
end

-- Catalogue entry from the market data file: { name, quality, baseID, buy, sell, class }
local function Catalogue(id)
    local d = _G.AHPT_MarketData
    return d and d.names and d.names[id]
end

-- Vendor -> AH: buy from a vendor, list on the AH.
--   Confirmed: vendor prices you (or another addon user) saw at a merchant, or from Auctionator.
--   Maybe (optional): trade goods whose AH price beats the game's listed buy price. Many of these aren't
--   sold by any vendor, so they're marked "check a vendor".
function ns:GetVendorFlips(includeMaybe)
    local rows = {}
    for id, v in pairs(self.vendor or {}) do
        local r = NewRow(self, id)
        r.vendorPrice, r.limited, r.vendorName, r.vendorSource = v.price, v.limited, v.vendor, v.source
        r.bundle = v.stack or (Catalogue(id) and Catalogue(id)[9]) or nil
        rows[#rows + 1] = r
    end
    if includeMaybe then
        for id in pairs(self:PricedItemIDs()) do
            local c = Catalogue(id)
            if c and c[3] == id and not self.vendor[id] and c[6] == 7 and c[4] and c[4] > 0 then
                local ah = self:GetAHPrice(id)
                if ah and ah.price and ah.price * (1 - ns:AHCut()) > c[4] then
                    local r = NewRow(self, id)
                    r.vendorPrice, r.maybe = c[4], true
                    r.bundle = c[9] or nil
                    rows[#rows + 1] = r
                end
            end
        end
    end
    for _, r in ipairs(rows) do
        if r.ah and r.ah.price then
            -- Keep fractions of a copper: cheap items (arrows at 0.25c, 1c reagents) would otherwise
            -- round to 0 and show nonsense profit and return.
            r.profit = r.ah.price * (1 - ns:AHCut()) - r.vendorPrice
            r.roi = r.profit / r.vendorPrice
            r.per20 = r.profit * 20
        end
        AddVolume(r)
    end
    return rows
end

-- Every item we have a price for under the current price-source setting.
function ns:PricedItemIDs()
    local mode, ids = self:PriceSource(), {}
    if mode ~= "local" then
        for id in pairs(self:MarketItems() or {}) do ids[id] = true end
    end
    if mode ~= "online" then
        for id in pairs(self.flipPrices or {}) do ids[id] = true end
        for id in pairs(self.sales or {}) do ids[id] = true end
        for id in pairs(self.items or {}) do ids[id] = true end
    end
    return ids
end

-- AH -> Vendor: AH listings cheaper than what a vendor pays for the item. Checks every item with a
-- price. The game's own sell price is used once the item is cached; until then the catalogue's.
function ns:GetVendorSellFlips()
    local rows = {}
    for id in pairs(self:PricedItemIDs()) do
        local c = Catalogue(id)
        if not c or c[3] == id then
            local sell = c and c[5]
            if not sell then sell = select(11, GetItemInfo(id)) end
            local ah = (sell and sell > 0) and self:GetAHPrice(id)
            if ah and ah.price and sell > ah.price then
                local r = NewRow(self, id)
                sell = r.gameSell or sell
                r.unconfirmed = not r.gameSell
                r.ah = ah
                if sell > ah.price then
                    r.vendorPrice = sell
                    r.profit = sell - ah.price
                    r.roi = r.profit / ah.price
                    r.per20 = r.profit * 20
                    r.allListed = r.profit * (ah.qty or 0)
                    rows[#rows + 1] = r
                end
            end
        end
    end
    return rows
end

function ns:GetFlips()
    if self.flipMode == "ahvendor" then return self:GetVendorSellFlips() end
    return self:GetVendorFlips(self.flipMaybe)
end

-- Best vendor flips that still need volume measured: scanned automatically while the AH is open.
function ns:FlipWatchCandidates()
    local n = self.settings.flipWatch or 8
    if n <= 0 then return {} end
    local rows = {}
    for _, r in ipairs(self:GetVendorFlips(false)) do
        if r.profit and r.profit > 0 and not self.items[r.id] then rows[#rows + 1] = r end
    end
    table.sort(rows, function(a, b) return a.per20 > b.per20 end)
    local out, seen = {}, {}
    for i = 1, math.min(n, #rows) do out[i] = rows[i].id; seen[rows[i].id] = true end
    -- Items you have listed are watched too, so My Auctions can project when they'll sell.
    for _, a in ipairs(self.owned and self.owned.list or {}) do
        if not a.sold and not seen[a.id] and not self.items[a.id] then
            out[#out + 1] = a.id
            seen[a.id] = true
        end
    end
    return out
end

-- Next watched flip candidate that's due for a scan (called from the scan ticker).
function ns:NextFlipWatch()
    local now = time()
    if not self.watchList or now - (self.watchListAt or 0) > 60 then
        self.watchList, self.watchListAt = self:FlipWatchCandidates(), now
        self.flipWatchSet = {}
        for _, id in ipairs(self.watchList) do self.flipWatchSet[id] = true end
    end
    self.flipAttempt = self.flipAttempt or {}
    for _, id in ipairs(self.watchList) do
        local fp = self.flipPrices[id]
        if (not fp or now - fp.t >= self.settings.interval) and now - (self.flipAttempt[id] or 0) >= 60 then
            self.flipAttempt[id] = now
            return id
        end
    end
end

function ns:StartFlipScan()
    if not self.ahOpen then
        self.Print("Open the Auction House first, then press Scan AH.")
        return
    end
    wipe(self.flipQueue)
    local now = time()
    for id in pairs(self.vendor) do
        local fp = self.flipPrices[id]
        if not fp or now - fp.t > RESCAN_AFTER then self.flipQueue[#self.flipQueue + 1] = id end
    end
    if #self.flipQueue == 0 then
        self.Print("Every vendor item was scanned in the last %s.", self.Duration(RESCAN_AFTER))
    else
        self.Print("Scanning the AH for %d vendor items (about %s).", #self.flipQueue, self.Duration(#self.flipQueue * 1.5))
        self:Tick(true)
    end
    self:OnFlipsUpdated()
end

---------------------------------------------------------------------------
-- Refresh (debounced: scans and item-info loads fire lots of events)
---------------------------------------------------------------------------
local refreshTimer
function ns:OnFlipsUpdated(slow)
    if refreshTimer then return end
    -- The Flip Finder can check thousands of items, so it redraws at most once a second.
    if not (ns.frame and ns.frame:IsShown() and ns.tab == "flips") then return end
    refreshTimer = C_Timer.NewTimer(1, function()
        refreshTimer = nil
        if ns.frame and ns.frame:IsShown() and ns.tab == "flips" and ns.RefreshFlips then ns:RefreshFlips() end
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("MERCHANT_SHOW")
ev:RegisterEvent("MERCHANT_UPDATE")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:RegisterEvent("TRADE_SKILL_SHOW")
ev:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
local merchantTimer, professionTimer
ev:SetScript("OnEvent", function(_, event)
    if not ns.vendor then return end
    if event == "GET_ITEM_INFO_RECEIVED" then
        if ns.tab == "flips" then ns:OnFlipsUpdated() end
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
        if professionTimer then professionTimer:Cancel() end
        professionTimer = C_Timer.NewTimer(1, function() professionTimer = nil; ns:ScanProfession() end)
    else
        if merchantTimer then merchantTimer:Cancel() end
        merchantTimer = C_Timer.NewTimer(0.3, function() merchantTimer = nil; ns:ScanMerchant() end)
    end
end)
