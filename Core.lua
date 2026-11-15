-- AH Price Tracker: core data + auction house scanning
local ADDON, ns = ...
_G.AHPriceTracker = ns

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

ns.DEFAULTS = {
    interval = 300,           -- seconds between scans of the same item
    autoScan = true,          -- scan automatically while the AH is open
    maxPoints = 5000,         -- history points kept per item
    pauseWhileTrading = true, -- don't auto-scan while a buy/sell screen is open
    flipWatch = 8,            -- best Flip Finder candidates scanned automatically to measure volume
}

local RETRY_DELAY    = 30   -- wait before retrying an item whose search got no answer
local QUERY_TIMEOUT  = 10   -- give up waiting for a search result after this long
local MERGE_WINDOW   = 30   -- results arriving within this window update the last point
local MARKET_FRACTION = 0.15 -- "market" price = avg unit price of the cheapest 15% of units
local DISCOVERY_GAP   = 1.5     -- seconds between background scans of unpriced vendor items
local DISCOVERY_STALE = 3 * 3600 -- vendor items without an in-game price this recent get rescanned

local PREFIX = "|cff33ff99AH Tracker|r: "
function ns.Print(fmt, ...)
    print(PREFIX .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt))
end

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------
function ns.Money(c)
    if not c then return "|cff808080--|r" end
    -- Fractions of a copper (per-item prices of things bought in bundles, like arrows at 0.25c)
    if c > -100 and c < 100 and math.abs(c - math.floor(c + 0.5)) >= 0.005 then
        local s = string.format("%.2f", math.abs(c)):gsub("0+$", ""):gsub("%.$", "")
        return (c < 0 and "-" or "") .. s .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
    end
    c = math.floor(c + 0.5)
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(c)
    end
    return GetMoneyString(c, true)
end

function ns.ShortMoney(c)
    c = math.floor(c + 0.5)
    local g = c / 10000
    if g >= 100000 then
        return string.format("%.0fk g", g / 1000)
    elseif g >= 100 then
        return string.format("%dg", math.floor(g + 0.5))
    elseif g >= 1 then
        return string.format("%.2fg", g)
    end
    return string.format("%ds %dc", math.floor(c / 100), c % 100)
end

function ns.Duration(s)
    s = math.max(0, math.floor(s))
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    if s < 86400 then return string.format("%.1fh", s / 3600) end
    return string.format("%.1fd", s / 86400)
end

function ns.Ago(t)
    if not t or t == 0 then return "never" end
    return ns.Duration(time() - t) .. " ago"
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
function ns:InitDB()
    AHPriceTrackerDB = AHPriceTrackerDB or {}
    local db = AHPriceTrackerDB
    db.settings = db.settings or {}
    for k, v in pairs(self.DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    db.realms = db.realms or {}
    local realm = GetRealmName() or "Unknown"
    db.realms[realm] = db.realms[realm] or { items = {} }
    self.db = db
    self.settings = db.settings
    self.realmData = db.realms[realm]
    self.items = db.realms[realm].items
    self.house = "home" -- your faction's auction house; see Houses.lua
    if self.InitTrades then self:InitTrades() end
    if self.InitFlips then self:InitFlips() end
    if self.InitSales then self:InitSales() end
    -- v1.5.1: scans saved before this version may hold stack totals instead of unit prices. Until an
    -- item is scanned again (which tells us whether it's a commodity or sold in stacks), its saved
    -- scan prices aren't used anywhere.
    if not self.realmData.unitCheckStarted then
        self.realmData.unitCheckStarted = true
        local pend = {}
        for id in pairs(self.items) do pend[id] = true end
        for id in pairs(self.flipPrices or {}) do pend[id] = true end
        for id in pairs(self.sales or {}) do pend[id] = true end
        self.realmData.unitPending = pend
    end
    self.realmData.unitPending = self.realmData.unitPending or {}
    self.unitPending = self.realmData.unitPending
    if self.InitSync then self:InitSync() end
    if self.InitAuctions then self:InitAuctions() end
    if self.InitTownServices then self:InitTownServices() end
    if self.InitCamp then self:InitCamp() end
    for id, entry in pairs(self.items) do
        entry.history = entry.history or {}
        self:LoadItemInfo(id)
    end
end

function ns:LoadItemInfo(id)
    local entry = self.items[id]
    if not entry then return end
    local item = Item:CreateFromItemID(id)
    item:ContinueOnItemLoad(function()
        entry.name = item:GetItemName()
        entry.link = item:GetItemLink()
        entry.icon = item:GetItemIcon()
        self:OnDataUpdated(id)
    end)
end

-- Item name search over the full catalogue (market data + recipe data), so items can be found by
-- name even if the game hasn't loaded them yet. Built once, on first use.
local nameIndex
local function BuildNameIndex()
    nameIndex = {}
    local seen = {}
    local function add(id, name)
        if id and name and not seen[id] then
            seen[id] = true
            nameIndex[#nameIndex + 1] = { id = id, name = name, lower = name:lower() }
        end
    end
    local md = _G.AHPT_MarketData
    for id, c in pairs(md and md.names or {}) do
        if c[3] == id then add(id, c[1]) end -- skip random-suffix variants
    end
    local rd = _G.AHPT_Recipes
    for id, n in pairs(rd and rd.names or {}) do add(id, n) end
    for id, e in pairs(ns.items or {}) do add(id, e.name) end
end

-- Up to `max` matches for a name: exact first, then names starting with it, then word starts, then anywhere.
function ns:SearchItems(text, max)
    if not nameIndex then BuildNameIndex() end
    text = strtrim(text or ""):lower()
    if #text < 2 then return {} end
    local buckets = { {}, {}, {}, {} }
    for _, e in ipairs(nameIndex) do
        local l = e.lower
        if l == text then
            buckets[1][#buckets[1] + 1] = e
        elseif l:sub(1, #text) == text then
            buckets[2][#buckets[2] + 1] = e
        else
            local pos = l:find(text, 1, true)
            if pos then
                local word = pos == 1 or l:sub(pos - 1, pos - 1) == " "
                local b = buckets[word and 3 or 4]
                b[#b + 1] = e
            end
        end
    end
    local out = {}
    for _, b in ipairs(buckets) do
        table.sort(b, function(x, y) return #x.name < #y.name or (#x.name == #y.name and x.name < y.name) end)
        for _, e in ipairs(b) do
            out[#out + 1] = e
            if #out >= (max or 8) then return out end
        end
    end
    return out
end

function ns.ParseItemID(text)
    if type(text) == "number" then return text end
    text = strtrim(text or "")
    if text == "" then return nil end
    local id = text:match("item:(%d+)") or text:match("^(%d+)$")
    if id then return tonumber(id) end
    -- Plain name: the game knows it if the item is cached...
    local _, link = GetItemInfo(text)
    if link then return tonumber(link:match("item:(%d+)")) end
    -- ...otherwise look it up in the item catalogue: an exact name, or the only match.
    local hits = ns:SearchItems(text, 2)
    if hits[1] and (hits[1].lower == text:lower() or #hits == 1) then return hits[1].id end
end

function ns:AddItem(text)
    local id = self.ParseItemID(text)
    if not id then
        local hits = type(text) == "string" and self:SearchItems(text, 5) or {}
        if #hits > 0 then
            local names = {}
            for _, h in ipairs(hits) do names[#names + 1] = h.name end
            self.Print("Several items match. Did you mean: %s?", table.concat(names, ", "))
        else
            self.Print("Couldn't find that item. Type its name, shift-click an item link, drag an item in, or use its item ID.")
        end
        return
    end
    if C_Item and C_Item.DoesItemExistByID and not C_Item.DoesItemExistByID(id) then
        self.Print("Item ID %d doesn't exist.", id)
        return
    end
    if self.items[id] then
        self.Print("Already tracking %s.", self.items[id].link or ("item " .. id))
        self:Select(id)
        return
    end
    self.items[id] = { id = id, added = time(), lastScan = 0, lastAttempt = 0, history = {} }
    self:LoadItemInfo(id)
    self.Print("Now tracking item %d.%s", id, self.ahOpen and "" or " Prices are logged while the Auction House is open.")
    self:Select(id)
    self:OnDataUpdated(id)
end

function ns:AddFromCursor()
    local kind, id, link = GetCursorInfo()
    if kind == "item" then
        ClearCursor()
        self:AddItem(link or id)
        return true
    end
end

function ns:RemoveItem(id)
    local entry = self.items[id]
    if not entry then return end
    self.items[id] = nil
    if self.pending == id then self.pending = nil end
    if self.selected == id then self.selected = nil end
    self.Print("Stopped tracking %s.", entry.link or ("item " .. id))
    self:OnDataUpdated(id)
end

---------------------------------------------------------------------------
-- Price math
---------------------------------------------------------------------------
-- "Market" price: average unit price of the cheapest 15% of units. listings: { {unitPrice, quantity}, ... }
function ns.MarketPrice(listings)
    table.sort(listings, function(a, b) return a[1] < b[1] end)
    local loaded = 0
    for _, l in ipairs(listings) do loaded = loaded + l[2] end
    local target = math.max(1, math.ceil(loaded * MARKET_FRACTION))
    local acc, sum = 0, 0
    for _, l in ipairs(listings) do
        local take = math.min(l[2], target - acc)
        sum = sum + take * l[1]
        acc = acc + take
        if acc >= target then break end
    end
    return acc > 0 and math.floor(sum / acc + 0.5) or false
end

-- listings: array of { unitPrice, quantity }
function ns:Record(id, listings, totalQty)
    local entry = self.items[id]
    if not entry then return end

    local market = ns.MarketPrice(listings) -- also sorts the listings
    local minPrice = listings[1] and listings[1][1] or false
    local loaded = 0
    for _, l in ipairs(listings) do loaded = loaded + l[2] end

    local now = time()
    local point = { now, minPrice, market, totalQty or loaded }
    local h = entry.history
    local last = h[#h]
    if last and now - last[1] < MERGE_WINDOW then
        h[#h] = point -- same scan refreshing (more results loaded)
    else
        h[#h + 1] = point
    end
    local excess = #h - self.settings.maxPoints
    if excess > 0 then
        for _ = 1, excess do table.remove(h, 1) end
    end

    entry.lastScan = now
    if self.pending == id then self.pending = nil end
    self:OnDataUpdated(id)
end

function ns:Latest(entry)
    local h = entry and entry.history
    return h and h[#h]
end

-- Percent change of the lowest price versus roughly `secs` ago.
function ns:Change(entry, secs)
    local h = entry.history
    local latest
    for i = #h, 1, -1 do
        if h[i][2] then latest = h[i]; break end
    end
    if not latest then return nil end
    local cutoff = latest[1] - secs
    for i = #h, 1, -1 do
        local p = h[i]
        if p[1] <= cutoff and p[2] then
            return (latest[2] - p[2]) / p[2] * 100
        end
    end
end

---------------------------------------------------------------------------
-- Auction house scanning
---------------------------------------------------------------------------
local SORTS

function ns:IsBusyAtAH()
    local f = AuctionHouseFrame
    if not f then return false end
    for _, key in ipairs({ "CommoditiesBuyFrame", "ItemBuyFrame", "CommoditiesSellFrame", "ItemSellFrame" }) do
        local sub = f[key]
        if sub and sub.IsVisible and sub:IsVisible() then return true end
    end
    return false
end

-- Fast watch: a few chosen items scanned every minute, so listings that are posted and bought
-- within a few minutes still show up as sales.
ns.FAST_INTERVAL = 60
ns.FAST_MAX = 5
function ns:IsFastWatched(id) return self.settings.fastWatch and self.settings.fastWatch[id] or false end
function ns:ToggleFastWatch(id)
    self.settings.fastWatch = self.settings.fastWatch or {}
    local fw = self.settings.fastWatch
    if fw[id] then
        fw[id] = nil
        self.Print("Fast watch off for %s.", self:ItemName(id))
    else
        local n = 0
        for _ in pairs(fw) do n = n + 1 end
        if n >= self.FAST_MAX then
            self.Print("Fast watch is limited to %d items (the AH allows about one search a second). Turn one off first.", self.FAST_MAX)
            return
        end
        if not self.items[id] then self:AddItem(id) end
        fw[id] = true
        self.Print("Fast watch on for %s: scanned every %d seconds while the AH is open.", self:ItemName(id), self.FAST_INTERVAL)
    end
    if self.frame and self.frame:IsShown() then self:RefreshList() end
end

function ns:NextDue()
    local now, best, bestDue = time(), nil, nil
    for id, e in pairs(self.items) do
        local interval = self:IsFastWatched(id) and math.min(self.FAST_INTERVAL, self.settings.interval) or self.settings.interval
        local due = math.max((e.lastScan or 0) + interval, (e.lastAttempt or 0) + RETRY_DELAY)
        if not bestDue or due < bestDue then best, bestDue = id, due end
    end
    return best, bestDue and (bestDue - now)
end

function ns:Query(id)
    SORTS = SORTS or { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    local entry = self.items[id]
    if entry then entry.lastAttempt = time() end
    self.pending = id
    self.pendingSince = GetTime()
    C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(id), SORTS, false)
    self:UpdateStatus()
end

function ns:Tick(force)
    if not self.ahOpen then return end
    local flipping = self.flipQueue and #self.flipQueue > 0
    if not force and not self.settings.autoScan and not flipping then return end
    if self.pending then
        if GetTime() - (self.pendingSince or 0) < QUERY_TIMEOUT then return end
        self.pending = nil
    end
    if not force and self.settings.pauseWhileTrading and self:IsBusyAtAH() then return end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
    -- Tracked items first, then any Flip Finder scan in progress.
    if force or self.settings.autoScan then
        local id, wait = self:NextDue()
        if id and wait <= 0 then self:Query(id); return end
        -- Then the best Flip Finder candidates, so their sales volume gets measured.
        local fid = self.NextFlipWatch and self:NextFlipWatch()
        if fid then self:Query(fid); return end
    end
    if flipping then
        self:Query(table.remove(self.flipQueue, 1))
        if #self.flipQueue == 0 then self.Print("Flip Finder scan finished.") end
        if self.OnFlipsUpdated then self:OnFlipsUpdated() end
        return
    end
    -- Lowest priority: slowly work through vendor items with no recent in-game price, so every
    -- vendor item eventually gets a price (and a chance to show up as a good flip).
    if self.settings.autoScan and GetTime() - (self.lastDiscovery or 0) >= DISCOVERY_GAP then
        local did = self:NextDiscovery()
        if did then
            self.lastDiscovery = GetTime()
            self:Query(did)
        end
    end
end

-- How many vendor items have never been priced in game (shown in the Flip Finder).
function ns:UnpricedVendorCount()
    local n, now = 0, time()
    local tried = self.discoveryTried or {}
    for id in pairs(self.vendor or {}) do
        -- (items searched recently that the AH returned nothing for don't count as waiting)
        if not (self.flipPrices and self.flipPrices[id]) and now - (tried[id] or 0) >= DISCOVERY_STALE then n = n + 1 end
    end
    return n
end

-- Vendor item with the oldest (or no) in-game price, if it's older than DISCOVERY_STALE.
function ns:NextDiscovery()
    if not (self.vendor and self.flipPrices) then return nil end
    local now, best, bestT = time(), nil, nil
    self.discoveryTried = self.discoveryTried or {}
    for id in pairs(self.vendor) do
        local fp = self.flipPrices[id]
        local t = fp and fp.t or 0
        local tried = self.discoveryTried[id] or 0
        if now - t >= DISCOVERY_STALE and now - tried >= DISCOVERY_STALE and (not bestT or t < bestT) then
            best, bestT = id, t
        end
    end
    if best then self.discoveryTried[best] = now end -- don't retry an item the AH has nothing for every few seconds
    return best
end

function ns:ScanNow()
    if not self.ahOpen then
        self.Print("Open the Auction House to scan.")
        return
    end
    for _, e in pairs(self.items) do e.lastScan, e.lastAttempt = 0, 0 end
    self:Tick(true)
end

-- Results feed the price tracker (tracked items) and the Flip Finder (items with a known vendor price).
function ns:HandleResults(id, listings, total)
    local wasQueried = self.pending == id
    if self.pending == id then self.pending = nil end
    local known = true -- any item seen on the AH is recorded (and shared)
    if known and self.RecordSales then self:RecordSales(id, listings, total) end
    if known and self.RecordFlipPrice then self:RecordFlipPrice(id, listings, total) end
    if self.items[id] then self:Record(id, listings, total) end
    self:UpdateStatus()
end

-- Every search result is used, including searches the player runs themselves: it feeds price history,
-- sales volume and (through sync) everyone else's data, even if they never open the tracker window.
local function Wanted(id)
    return id ~= nil
end

function ns:OnCommodityResults(itemID)
    if not Wanted(itemID) then return end
    local listings = {}
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice then listings[#listings + 1] = { r.unitPrice, r.quantity or 1 } end
    end
    local total = C_AuctionHouse.GetCommoditySearchResultsQuantity
        and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID)
    -- The game reports "no results" for a moment before a search finishes loading. Only trust an
    -- empty answer once the search is complete (and the total agrees).
    if #listings == 0 then
        if C_AuctionHouse.HasFullCommoditySearchResults and not C_AuctionHouse.HasFullCommoditySearchResults(itemID) then return end
        if total and total > 0 then return end
    end
    -- A commodity: its saved prices were always per unit, so they're fine to use again.
    if self.unitPending then self.unitPending[itemID] = nil end
    self:HandleResults(itemID, listings, total)
end

function ns:OnItemResults(itemKey)
    local id = itemKey and itemKey.itemID
    if not Wanted(id) then return end
    local listings = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount then
            -- Stack listings report the buyout for the whole stack; everything here works per unit.
            local q = math.max(1, r.quantity or 1)
            listings[#listings + 1] = { r.buyoutAmount / q, q } -- keep fractions (200 arrows for 1s = 0.5c each)
        end
    end
    local total = C_AuctionHouse.GetItemSearchResultsQuantity
        and C_AuctionHouse.GetItemSearchResultsQuantity(itemKey)
    if #listings == 0 then -- same as above: an empty answer only counts once the search is complete
        if C_AuctionHouse.HasFullItemSearchResults and not C_AuctionHouse.HasFullItemSearchResults(itemKey) then return end
        if total and total > 0 then return end
    end
    self:ClearStackPriceData(id)
    self:HandleResults(id, listings, total)
end

-- Sorts out items whose saved scans are waiting for a re-check, without searching the AH: the game
-- can say whether an item is a commodity (saved prices were always per unit, so keep them) or sold in
-- stacks (saved prices were stack totals, so clear them and rescan). Returns how many were resolved.
function ns:ResolveUnitPending()
    if not (self.unitPending and next(self.unitPending)) then return 0 end
    if not (C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.MakeItemKey) then return 0 end
    local resolved, cleared = 0, 0
    for id in pairs(self.unitPending) do
        local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, C_AuctionHouse.MakeItemKey(id))
        if ok and info and info.isCommodity ~= nil then
            if info.isCommodity then
                self.unitPending[id] = nil
            else
                self:ClearStackPriceData(id)
                cleared = cleared + 1
            end
            resolved = resolved + 1
        end
    end
    if resolved > 0 then
        if self.salesCache then wipe(self.salesCache) end
        self.mktCache = nil
        if self.frame and self.frame:IsShown() then self:RefreshAll() end
    end
    if cleared > 0 then self:QueueStackRescans() end
    return resolved
end

-- Items sold in stacks whose old prices were cleared get rescanned as soon as the AH is open.
function ns:QueueStackRescans()
    if not (self.ahOpen and self.flipQueue) then return end
    local stackFixed = self:HouseData().stackFixed
    local queued = {}
    for _, id in ipairs(self.flipQueue) do queued[id] = true end
    local n = 0
    for id in pairs(stackFixed) do
        local wanted = self.items[id] or (self.vendor and self.vendor[id])
        if wanted and not queued[id] and not (self.flipPrices and self.flipPrices[id]) then
            self.flipQueue[#self.flipQueue + 1] = id
            queued[id] = true
            n = n + 1
        end
    end
    if n > 0 then
        self.Print("Rescanning %d item%s sold in stacks to get per-unit prices.", n, n == 1 and "" or "s")
        if self.OnFlipsUpdated then self:OnFlipsUpdated() end
    end
end

-- Before v1.5.1, stack listings were saved at the whole-stack price as if it were per unit. The first
-- time an item comes back as stack listings, drop its old (wrong) prices so the graph and volume
-- start clean. Commodities were always right and are never touched.
function ns:ClearStackPriceData(id)
    local fixed = self:HouseData().stackFixed
    local pending = self.unitPending and self.unitPending[id]
    if self.unitPending then self.unitPending[id] = nil end
    if fixed[id] and not pending then return end
    fixed[id] = true
    local e = self.items[id]
    local hadData = (e and #e.history > 0) or (self.sales and self.sales[id]) or (self.flipPrices and self.flipPrices[id])
    if e then wipe(e.history) end
    if self.sales then self.sales[id] = nil end
    if self.salesCache then self.salesCache[id] = nil end
    if self.flipPrices then self.flipPrices[id] = nil end
    if hadData then
        local name = (e and (e.link or e.name)) or ("item " .. id)
        self.Print("%s is sold in stacks: cleared its old prices, which were stack totals. New scans are per unit.", name)
    end
end

---------------------------------------------------------------------------
-- CSV export
---------------------------------------------------------------------------
function ns:BuildCSV(onlyID)
    local out = { "item_id,item_name,timestamp,datetime,lowest_copper,market_copper,quantity" }
    for id, e in pairs(self.items) do
        if not onlyID or onlyID == id then
            local name = (e.name or ""):gsub('"', '""')
            for _, p in ipairs(e.history) do
                out[#out + 1] = string.format('%d,"%s",%d,%s,%s,%s,%d', id, name, p[1],
                    date("%Y-%m-%d %H:%M:%S", p[1]), p[2] and tostring(p[2]) or "",
                    p[3] and tostring(p[3]) or "", p[4] or 0)
            end
        end
    end
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
events:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
events:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
events:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")

events:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        ns:InitDB()
        ns.loginTime = GetTime()
        C_Timer.After(3, function() ns:ResolveUnitPending() end)
    elseif not ns.items then
        return
    elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
        -- Item info arriving can let us tell commodities from stack items; batch these up.
        if ns.unitPending and next(ns.unitPending) and not ns.resolveTimer then
            ns.resolveTimer = C_Timer.NewTimer(1, function() ns.resolveTimer = nil; ns:ResolveUnitPending() end)
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
        ns.ahOpen = true
        if ns.OnHouseOpened then ns:OnHouseOpened() end
        ns:AttachToAuctionHouse()
        if ns.ticker then ns.ticker:Cancel() end
        ns.ticker = C_Timer.NewTicker(1, function() ns:Tick() end)
        ns:ResolveUnitPending()
        ns:QueueStackRescans()
        -- Anything still unresolved gets a real search, which settles it either way.
        if ns.unitPending and next(ns.unitPending) then
            local queued = {}
            for _, id in ipairs(ns.flipQueue) do queued[id] = true end
            for id in pairs(ns.unitPending) do
                if not queued[id] then ns.flipQueue[#ns.flipQueue + 1] = id end
            end
        end
        ns:UpdateStatus()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ns.ahOpen = false
        ns.pending = nil
        if ns.ticker then ns.ticker:Cancel(); ns.ticker = nil end
        ns:UpdateStatus()
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        ns:OnCommodityResults(...)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        ns:OnItemResults(...)
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        ns:Tick()
    end
end)

---------------------------------------------------------------------------
-- Performance report (/aht perf)
---------------------------------------------------------------------------
function ns:PerfReport()
    local UpdateMem = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or UpdateAddOnMemoryUsage
    local GetMem = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
    if UpdateMem then UpdateMem() end
    local kb = GetMem and GetMem(ADDON) or 0
    self.Print("Memory: %.1f MB (the bundled market data accounts for several MB of that; that is normal and costs no speed).", kb / 1024)

    local snaps, salesItems = 0, 0
    for _, s in pairs(self.sales or {}) do salesItems = salesItems + 1; snaps = snaps + #s.snaps end
    local items, points = 0, 0
    for _, e in pairs(self.items or {}) do items = items + 1; points = points + #e.history end
    local flips = 0
    for _ in pairs(self.flipPrices or {}) do flips = flips + 1 end
    print(string.format("  Tracked items: %d (%d price points). Sales timeline: %d items, %d scans. Flip prices: %d. Trades: %d.",
        items, points, salesItems, snaps, flips, #(self.trades or {})))
    print(string.format("  Scanning: %s. Sync queue: %d live, %d catch-up.",
        self.ahOpen and "AH open (one search per second at most)" or "idle (AH closed)",
        self.sendQueue and #self.sendQueue or 0, self.bulkQueue and #self.bulkQueue or 0))

    local cpuOn = GetCVarBool and GetCVarBool("scriptProfile")
    local UpdateCPU = (C_AddOns and C_AddOns.UpdateAddOnCPUUsage) or UpdateAddOnCPUUsage
    local GetCPU = (C_AddOns and C_AddOns.GetAddOnCPUUsage) or GetAddOnCPUUsage
    if cpuOn and UpdateCPU and GetCPU then
        UpdateCPU()
        local ms = GetCPU(ADDON)
        print(string.format("  CPU used since login: %.0f ms (%.2f ms per second of play).", ms, ms / math.max(1, GetTime() - (self.loginTime or 0))))
    else
        print("  CPU: not measured. To measure it, type  /console scriptProfile 1  then /reload, run /aht perf again, and  /console scriptProfile 0  afterwards (profiling slows the game slightly).")
    end
    print("  With the window closed and the AH closed, this addon only listens for trades, mail and sync messages.")
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_AHPRICETRACKER1 = "/aht"
SLASH_AHPRICETRACKER2 = "/ahtracker"
SlashCmdList.AHPRICETRACKER = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "show" then
        ns:ToggleUI()
    elseif cmd == "add" then
        ns:AddItem(rest)
    elseif cmd == "remove" or cmd == "rm" then
        local id = ns.ParseItemID(rest)
        if id and ns.items[id] then ns:RemoveItem(id) else ns.Print("Not tracking that item.") end
    elseif cmd == "scan" then
        ns:ScanNow()
    elseif cmd == "interval" then
        local s = tonumber(rest)
        if s and s >= 30 then
            ns.settings.interval = math.floor(s)
            ns.Print("Each item is now scanned every %s.", ns.Duration(s))
        else
            ns.Print("Usage: /aht interval <seconds> (minimum 30). Current: %s", ns.Duration(ns.settings.interval))
        end
    elseif cmd == "auto" then
        ns.settings.autoScan = (rest:lower() ~= "off")
        ns.Print("Auto-scan %s.", ns.settings.autoScan and "on" or "off")
        ns:UpdateStatus()
    elseif cmd == "export" then
        ns:ShowExport(ns:BuildCSV())
    elseif cmd == "sync" then
        ns:SyncCommand(rest)
    elseif cmd == "perf" then
        ns:PerfReport()
    elseif cmd == "pins" or cmd == "services" then
        ns.settings.townPinsOn = not ns.settings.townPinsOn
        ns.Print("Town service icons on the world map: %s.", ns.settings.townPinsOn and "on" or "off")
        ns:RefreshTownPins()
    elseif cmd == "tracking" then
        ns:EnableServiceTracking()
    elseif cmd == "debug" then
        -- Auction messages the addon didn't recognise, to help fix sale detection
        local log = ns.db.auctionMsgLog or {}
        ns.Print("Unrecognised auction messages (%d):", #log)
        for _, line in ipairs(log) do print("  " .. line) end
        if #log == 0 then print("  none so far") end
    elseif cmd == "camp" or cmd == "schedule" then
        ns:CampCommand(rest)
    elseif cmd == "help" or cmd == "manual" then
        ns:ShowHelp()
    elseif cmd == "history" or cmd == "flips" or cmd == "market" or cmd == "auctions" or cmd == "prices"
        or cmd == "profit" or cmd == "crafting" then
        ns:CreateUI()
        ns:ShowTab(cmd)
        ns.frame:Show()
    else
        ns.Print("Commands:")
        print("  /aht - open/close the tracker window")
        print("  /aht history - open your trade history")
        print("  /aht flips - open the Flip Finder (vendor-to-AH profits)")
        print("  /aht market - open Market Data (prices from auctionhouse.fyi)")
        print("  /aht auctions - your current auctions and projected earnings")
        print("  /aht sync - share scans with other players running the addon")
        print("  /aht perf - show how much memory and CPU the addon uses")
        print("  /aht help - open the manual")
        print("  /aht pins - show/hide town service icons on the world map")
        print("  /aht tracking - turn on minimap tracking for banks, trainers, vendors...")
        print("  /aht add <item link or ID> - track an item")
        print("  /aht remove <item link or ID> - stop tracking an item")
        print("  /aht scan - scan every tracked item now (AH must be open)")
        print("  /aht interval <seconds> - how often each item is re-scanned")
        print("  /aht auto on|off - toggle automatic scanning")
        print("  /aht export - copy all history as CSV")
    end
end
