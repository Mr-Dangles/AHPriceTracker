-- AH Price Tracker: your current auctions (what you have on the AH right now) and projected earnings.
-- The list is read from the Auction House while it's open and saved, so the tab works anywhere.
local ADDON, ns = ...

local TIME_LEFT_SECS = { [0] = 30 * 60, [1] = 2 * 3600, [2] = 12 * 3600, [3] = 48 * 3600 } -- old duration buckets

-- Which of two readings is nearer a reference price, on a ratio scale (10x off is 10x off at 1c or 1g)
local function Closer(ref, a, b)
    local da = math.abs(math.log(math.max(a, 0.01) / ref))
    local db = math.abs(math.log(math.max(b, 0.01) / ref))
    return da <= db
end

-- Auctions are stored per character, so each character's list survives switching characters.
function ns:InitAuctions()
    local me = UnitName("player") or "?"
    local rd = self.realmData
    rd.ownedBy = rd.ownedBy or {}
    if rd.owned then -- older versions kept one list for the realm: it belonged to whoever read it last
        rd.ownedBy[me] = rd.ownedBy[me] or rd.owned
        rd.owned = nil
    end
    rd.ownedBy[me] = rd.ownedBy[me] or { t = 0, list = {} }
    self.owned = rd.ownedBy[me]
    -- v1.8.1: sold parts of a stack were saved at their total as if it were the price of one.
    if not rd.soldPriceFixed then
        rd.soldPriceFixed = true
        local function fix(owners)
            for _, owned in pairs(owners or {}) do self:FixSoldPrices(owned.list or {}) end
        end
        fix(rd.ownedBy)
        for _, h in pairs(rd.houses or {}) do fix(h.ownedBy) end
    end
end

-- Repair saved sold entries: compare with the same auction's active part or your listing price.
function ns:FixSoldPrices(list)
    local activeUnit = {}
    for _, a in ipairs(list) do
        if not a.sold and a.auctionID and a.unit then activeUnit[a.auctionID] = a.unit end
    end
    for _, a in ipairs(list) do
        if a.sold and a.unit and (a.qty or 1) > 1 and a.priceMode ~= "batch" then
            local ref = activeUnit[a.auctionID]
            if not ref then
                for i = #(self.trades or {}), 1, -1 do
                    local r = self.trades[i]
                    if r.type == "listed" and r.itemID == a.id and r.unit and r.unit > 0 then ref = r.unit; break end
                end
            end
            if not ref or not Closer(ref, a.unit, a.unit / a.qty) then
                a.unit, a.priceMode = a.unit / a.qty, "batch"
            end
        end
    end
end

-- Auction lists for the current character scope: { { char, realm, owned }, ... }
function ns:ScopedOwned()
    local me, scope = UnitName("player"), self:Scope()
    local out = {}
    for realm, rd in pairs(self:ScopedRealms()) do
        local function add(list, house)
            for char, owned in pairs(list or {}) do
                if scope ~= "char" or char == me then
                    out[#out + 1] = { char = char, realm = realm, owned = owned, house = house }
                end
            end
        end
        add(rd.ownedBy, "home") -- your faction's auction house
        for key, h in pairs(rd.houses or {}) do add(h.ownedBy, key) end -- neutral and other houses
    end
    return out
end

---------------------------------------------------------------------------
-- Reading your auctions from the AH
---------------------------------------------------------------------------
function ns:QueryOwned(tries)
    if not (self.ahOpen and C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions) then return end
    tries = tries or 0
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        if tries < 10 then C_Timer.After(1, function() ns:QueryOwned(tries + 1) end) end
        return
    end
    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } }
    pcall(C_AuctionHouse.QueryOwnedAuctions, sorts)
end

-- Does the AH report this auction's price per unit or for the whole batch? The "is it a commodity"
-- flag isn't reliable on Forever, so decide from evidence:
--   1. the decision already made for this auction (it doesn't change between reads),
--   2. your own posting record (the exact per-unit price you listed it at),
--   3. the item's market price (whichever reading is closer),
--   4. only then the commodity flag.
-- Returns "unit" or "batch".
function ns:OwnedPriceMode(itemKey, qty, raw, previous, refUnit, sold)
    if not raw or qty <= 1 then return "unit" end
    if previous and previous.priceMode then return previous.priceMode end
    local id = itemKey.itemID
    local asUnit, asBatch = raw, raw / qty

    -- The same auction's active part (for a sold entry), else your posting record for this item:
    -- the most recent one with the same quantity, else any
    local ref = refUnit
    for i = (ref and 0 or #(self.trades or {})), 1, -1 do
        local r = self.trades[i]
        if r.type == "listed" and r.itemID == id and r.unit and r.unit > 0 then
            if r.qty == qty then ref = r.unit; break end
            ref = ref or r.unit
        end
    end
    -- Otherwise what the item goes for
    if not ref then
        local ah = self.GetAHPrice and self:GetAHPrice(id)
        ref = ah and ah.price
        if not ref or ref <= 0 then
            local d = _G.AHPT_MarketData
            local c = d and d.names and d.names[id]
            ref = c and c[5] and c[5] > 0 and c[5] * 4 or nil -- vendor sell price x4 is a rough market floor
        end
    end
    if ref and ref > 0 then return Closer(ref, asUnit, asBatch) and "unit" or "batch" end
    if sold then return "batch" end -- sold entries report the total the part fetched

    local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(itemKey)
    if info and info.isCommodity ~= nil then return info.isCommodity and "unit" or "batch" end
    return self:HouseData().stackFixed[id] and "batch" or "unit"
end

function ns:ReadOwned()
    if not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions) then return end
    -- What was still on the market at the last read, to spot auctions that sold since (fully, or part
    -- of a stack). When part of a stack sells, the AH keeps the rest as an active auction and adds a
    -- "sold" entry with the same auction ID, so only active entries are matched by ID.
    local before = {}
    for _, a in ipairs(self.owned.list or {}) do
        if a.auctionID and not a.sold then before[a.auctionID] = a end
    end
    local raws = {}
    for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
        local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if a and a.itemKey then raws[#raws + 1] = a end
    end
    local list, activeUnit = {}, {}
    -- Active auctions first: their per-unit price is the reference for their sold parts.
    for pass = 1, 2 do
        for _, a in ipairs(raws) do
            local sold = a.status == 1
            if (pass == 1) ~= sold then
                local secs = a.timeLeftSeconds or (a.timeLeft and TIME_LEFT_SECS[a.timeLeft])
                local qty = math.max(1, a.quantity or 1)
                local raw = a.buyoutAmount or a.bidAmount
                local mode
                if sold then
                    -- A sold entry reports what that part fetched in total; check against the listing.
                    mode = self:OwnedPriceMode(a.itemKey, qty, raw, nil, activeUnit[a.auctionID], true)
                else
                    mode = self:OwnedPriceMode(a.itemKey, qty, raw, before[a.auctionID])
                end
                local price = (raw and mode == "batch") and raw / qty or raw
                if not sold and a.auctionID then activeUnit[a.auctionID] = price end
                list[#list + 1] = {
                    auctionID = a.auctionID,
                    id = a.itemKey.itemID,
                    link = a.itemLink,
                    qty = qty,
                    unit = price, -- always per unit
                    priceMode = mode, -- "unit" or "batch": how the AH reported this auction's price
                    isBid = not a.buyoutAmount,
                    timeLeft = secs,
                    sold = sold,
                }
            end
        end
    end
    -- Sales since the last read, counted once per auction: a stack that got smaller, or an auction
    -- that's no longer active and now has a sold entry. (Also catches sales made while you were offline.)
    if self.AddPendingSale then
        -- Sales the mailbox already logged since the last read must not be counted again.
        local since = self.owned.t or 0
        local mailed = {}
        for _, r in ipairs(self.trades or {}) do
            if r.type == "ahsell" and not r.pending and r.itemID and (r.loggedAt or r.t or 0) >= since then
                mailed[r.itemID] = (mailed[r.itemID] or 0) + (r.qty or 1)
            end
        end
        local soldIDs = {}
        for _, a in ipairs(list) do if a.sold and a.auctionID then soldIDs[a.auctionID] = a end end
        for auctionID, old in pairs(before) do
            local now = nil
            for _, a in ipairs(list) do
                if a.auctionID == auctionID and not a.sold then now = a; break end
            end
            local soldQty = 0
            if now then
                soldQty = (old.qty or 0) > now.qty and (old.qty - now.qty) or 0
            elseif soldIDs[auctionID] then
                soldQty = old.qty or 0 -- the rest of the auction sold
            end
            local already = math.min(soldQty, mailed[old.id] or 0)
            if already > 0 then
                mailed[old.id] = mailed[old.id] - already
                soldQty = soldQty - already
            end
            if soldQty > 0 then
                self:AddPendingSale({ itemID = old.id, link = old.link,
                    name = old.link and self.LinkName(old.link) or self:ItemName(old.id),
                    qty = soldQty, unit = old.unit, auctionID = auctionID, via = "list", since = self.owned.t })
            end
        end
    end
    self.owned.t = time()
    self.owned.list = list
    self:OnAuctionsUpdated()
end

---------------------------------------------------------------------------
-- Projections
---------------------------------------------------------------------------
-- Units listed cheaper than `price` in the latest scan of this item (buyers take those first).
-- Returns count, and whether the scan was cut off before reaching your price (so there may be more).
function ns:UnitsAhead(id, price)
    local s = self.sales and self.sales[id]
    local snap = s and s.snaps[#s.snaps]
    if not snap then return nil end
    local ahead, lastPrice = 0, nil
    for i = 1, #snap.levels, 2 do
        local p, q = snap.levels[i], snap.levels[i + 1]
        if p < price then ahead = ahead + q end
        lastPrice = p
    end
    local cutOff = not snap.complete and lastPrice and lastPrice < price
    return ahead, cutOff, snap.t
end

-- Sell rate per day for an item: the displayed rate, or the early rate before 30 minutes of data.
function ns:SellRate(id)
    local est = self.SalesEstimate and self:SalesEstimate(id)
    if not est or est.observed == 0 then return nil end
    return est.perDay or (est.units / est.observed * 86400), est.perDay == nil
end

-- One row per auction with everything the tab shows.
function ns:GetAuctionRows()
    local rows = {}
    local now = time()
    local me = UnitName("player")
    for _, src in ipairs(self:ScopedOwned()) do
    local age = now - (src.owned.t or now)
    for _, a in ipairs(src.owned.list or {}) do
        local name, link = (C_Item and C_Item.GetItemInfo or GetItemInfo)(a.id)
        if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(a.id) end
        local r = {
            a = a, id = a.id, name = name or (self.MarketName and self:MarketName(a.id)) or ("Item " .. a.id),
            link = a.link or link, qty = a.qty, unit = a.unit, sold = a.sold,
            icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(a.id),
            char = src.char ~= me and src.char or nil, realm = src.realm, readAt = src.owned.t,
        }
        r.house = src.house
        if src.house ~= "home" then r.houseLabel = self:HouseLabel(src.house, true) end
        r.gross = (a.unit or 0) * a.qty
        r.net = math.floor(r.gross * (1 - self:AHCut(src.house)))
        if a.sold then
            r.status, r.projected = "sold", r.net
        else
          -- compare against prices from the auction house the auction is listed in
          self:WithHouse(src.house, function()
            r.left = a.timeLeft and math.max(0, a.timeLeft - age) or nil
            local cur = self:GetAHPrice(a.id)
            r.lowest = cur and cur.price
            if a.unit and r.lowest then
                if r.lowest < a.unit then
                    r.status, r.undercut = "undercut", (a.unit - r.lowest) / a.unit
                else
                    r.status = "lowest"
                end
            else
                r.status = "unknown"
            end
            r.ahead, r.cutOff = self:UnitsAhead(a.id, a.unit or 0)
            r.rate, r.early = self:SellRate(a.id)
            if r.rate and r.ahead then
                if r.rate > 0 then
                    r.sellsIn = (r.ahead + a.qty) / r.rate * 86400 -- time until your whole stack is bought
                    if r.left then
                        -- Units the market will buy before your auction expires, after the cheaper ones ahead of you.
                        local yours = math.max(0, math.min(a.qty, r.rate * r.left / 86400 - r.ahead))
                        r.projected = math.floor(r.net * yours / a.qty)
                        r.willSell = yours / a.qty
                    end
                else
                    r.projected, r.willSell = 0, 0
                end
            end
          end)
        end
        rows[#rows + 1] = r
    end
    end
    return rows
end

function ns:AuctionTotals(rows)
    local t = { listed = 0, units = 0, gross = 0, net = 0, soldNet = 0, projected = 0, unknown = 0, undercut = 0 }
    for _, r in ipairs(rows) do
        if r.sold then
            t.soldNet = t.soldNet + r.net
        else
            t.listed = t.listed + 1
            t.units = t.units + r.qty
            t.gross = t.gross + r.gross
            t.net = t.net + r.net
            if r.projected then t.projected = t.projected + r.projected else t.unknown = t.unknown + r.net end
            if r.status == "undercut" then t.undercut = t.undercut + 1 end
        end
    end
    return t
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local refreshTimer
function ns:OnAuctionsUpdated()
    if refreshTimer then return end
    refreshTimer = C_Timer.NewTimer(0.2, function()
        refreshTimer = nil
        if ns.frame and ns.frame:IsShown() and ns.tab == "auctions" and ns.RefreshAuctions then ns:RefreshAuctions() end
        if ns.frame and ns.frame:IsShown() and ns.tab == "history" and ns.RefreshHistory then ns:RefreshHistory() end
    end)
end

-- A sale logged from the mailbox: take it off the "sold, waiting in your mail" list.
hooksecurefunc(ns, "AddTrade", function(self, rec)
    if not (rec and rec.type == "ahsell" and self.owned) then return end
    for i, a in ipairs(self.owned.list) do
        if a.sold and (a.id == rec.itemID) and (a.qty == rec.qty or not rec.qty) then
            table.remove(self.owned.list, i)
            break
        end
    end
    self:OnAuctionsUpdated()
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("OWNED_AUCTIONS_UPDATED")
ev:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
ev:RegisterEvent("AUCTION_CANCELED")
ev:SetScript("OnEvent", function(_, event)
    if not ns.owned then return end
    if event == "OWNED_AUCTIONS_UPDATED" then
        ns:ReadOwned()
    else
        -- Give the AH a moment (and our own price scans a turn) before asking for your auctions.
        C_Timer.After(event == "AUCTION_HOUSE_SHOW" and 2 or 1, function() ns:QueryOwned() end)
    end
end)
