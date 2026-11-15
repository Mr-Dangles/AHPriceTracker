-- AH Price Tracker: sales estimates
-- The game never tells addons what other players buy. What we *can* see is the listings at each scan.
-- Buyers always take the cheapest units first, so when the cheapest price levels shrink or vanish
-- between two scans, those units were (almost certainly) bought. Units disappearing from higher
-- price levels while cheaper ones are untouched are cancellations/expiries and are ignored.
--
-- Scans ("snapshots") from every player running the addon are merged into one timeline per item
-- (see Sync.lua), and sales are worked out across that combined timeline. Two players watching at the
-- same time therefore never double-count a sale, and each player's AH time fills the others' gaps.
local ADDON, ns = ...

local MERGE_WINDOW = 30          -- results arriving this soon after a scan are the same scan loading more
local MAX_GAP      = 2 * 3600    -- don't compare scans further apart than this (auctions expiring in bulk look like sales)
local KEEP_SECS    = 14 * 86400  -- snapshots kept
local MAX_SNAPS    = 4000        -- per item
local MIN_OBSERVED = 30 * 60     -- need this much watched time before showing a per-day rate
ns.SNAP_LEVELS     = 8           -- cheapest price levels kept per snapshot (buys always come from the bottom)
ns.SALES_KEEP_SECS = KEEP_SECS

local Now = GetServerTime or time -- shared timestamps use the server clock so players' snapshots line up

function ns:InitSales()
    self.realmData.sales = self.realmData.sales or {}
    self.sales = self.realmData.sales
    self.realmData.syncBuys = self.realmData.syncBuys or {}
    self.syncBuys = self.realmData.syncBuys
    self.salesCache = {}
    self:PruneSales(self.sales, self.syncBuys)
    for _, h in pairs(self.realmData.houses or {}) do self:PruneSales(h.sales, h.syncBuys) end -- other auction houses
end

function ns:PruneSales(sales, syncBuys)
    local cutoff = Now() - KEEP_SECS
    for id, s in pairs(sales) do
        -- v1.3 stored one snapshot plus sale events; keep the snapshot, rebuild the rest.
        if s.snap and not s.snaps then s.snaps = { s.snap } end
        s.snap, s.ev, s.obs, s.base, s.lastEv = nil, nil, nil, nil, nil
        s.snaps = s.snaps or {}
        local keep = {}
        for _, sn in ipairs(s.snaps) do
            if sn.t >= cutoff and sn.levels then keep[#keep + 1] = sn end
        end
        s.snaps = keep
        if #keep == 0 then sales[id] = nil end
    end
    for id, list in pairs(syncBuys) do
        local keep = {}
        for _, b in ipairs(list) do if b[1] >= cutoff then keep[#keep + 1] = b end end
        syncBuys[id] = #keep > 0 and keep or nil
    end
end

-- listings: array of { unitPrice, quantity } -> flat ascending { price, qty, ... }, cheapest `max` levels
local function Levels(listings, max)
    local byPrice = {}
    for _, l in ipairs(listings) do byPrice[l[1]] = (byPrice[l[1]] or 0) + l[2] end
    local prices = {}
    for p in pairs(byPrice) do prices[#prices + 1] = p end
    table.sort(prices)
    local out = {}
    for i = 1, math.min(#prices, max) do out[#out + 1] = prices[i]; out[#out + 1] = byPrice[prices[i]] end
    return out, #prices > max
end

-- A scan that found nothing listed. A single empty scan between non-empty ones is almost always a
-- search that came back before it finished loading, so it only counts once the next scan agrees.
local function IsEmpty(s) return (s.total or 0) == 0 and #s.levels == 0 end
ns.IsEmptySnap = IsEmpty
local function UsableSnaps(list)
    local out = {}
    for i, s in ipairs(list) do
        if not IsEmpty(s) then
            out[#out + 1] = s
        else
            local nxt = list[i + 1]
            if nxt and IsEmpty(nxt) then out[#out + 1] = s end -- confirmed sell-out
        end
    end
    return out
end

-- Units bought from the bottom of `old`, judged against `new`.
local function Consumed(old, new)
    local newQty, newMax = {}, nil
    for i = 1, #new.levels, 2 do
        newQty[new.levels[i]] = new.levels[i + 1]
        newMax = new.levels[i]
    end
    local units, value = 0, 0
    for i = 1, #old.levels, 2 do
        local p, q = old.levels[i], old.levels[i + 1]
        -- A partial snapshot can't tell us about prices above what it holds.
        if not new.complete and (not newMax or p > newMax) then break end
        local left = newQty[p] or 0
        if left >= q then break end       -- cheapest surviving level untouched: buying stopped below it
        units = units + (q - left)
        value = value + (q - left) * p
        if left > 0 then break end        -- level only partly bought
    end
    return units, value
end

-- Insert a snapshot into an item's timeline. `snap` = { t, levels, complete, min, market, total, src }
-- Returns true if it was new (not a duplicate).
function ns:AddSnapshot(id, snap)
    if not self.sales then return false end
    local s = self.sales[id]
    if not s then s = { snaps = {} }; self.sales[id] = s end
    local list = s.snaps
    -- Same source within the merge window = the same scan loading more results: replace it.
    for i = #list, 1, -1 do
        local o = list[i]
        if o.t < snap.t - MERGE_WINDOW then break end
        if o.src == snap.src and math.abs(o.t - snap.t) < MERGE_WINDOW then
            if o.t == snap.t and o.total == snap.total and #o.levels == #snap.levels then return false end
            table.remove(list, i)
            break
        end
    end
    local pos = #list + 1
    while pos > 1 and list[pos - 1].t > snap.t do pos = pos - 1 end
    table.insert(list, pos, snap)
    while #list > MAX_SNAPS do table.remove(list, 1) end
    self.salesCache[id] = nil
    return true
end

-- Called with every search result for a tracked or vendor item (your own scans).
function ns:RecordSales(id, listings, total)
    if not self.sales then return end
    local loaded = 0
    for _, l in ipairs(listings) do loaded = loaded + l[2] end
    local levels, truncated = Levels(listings, ns.SNAP_LEVELS)
    local snap = {
        t = Now(), levels = levels,
        complete = (not truncated) and loaded >= (total or loaded),
        min = levels[1] or false, total = total or loaded,
        market = self.MarketPrice and self.MarketPrice(listings) or nil,
        src = self.SyncID and self:SyncID() or "me",
    }
    -- Keep the first timestamp of a scan that is still loading, so the merge window works.
    local s = self.sales[id]
    local prev = s and s.snaps[#s.snaps]
    if prev and prev.src == snap.src and snap.t - prev.t < MERGE_WINDOW then snap.t = prev.t end
    if self:AddSnapshot(id, snap) and self.ShareSnapshot then self:ShareSnapshot(id, snap) end
end

-- AH purchases (yours from the trade log, other players' from sync) in (t0, t1].
local function Buys(id, t0, t1)
    local n = 0
    for _, r in ipairs(ns.trades or {}) do
        if r.type == "ahbuy" and r.itemID == id and r.t > t0 and r.t <= t1 then n = n + (r.qty or 1) end
    end
    for _, b in ipairs(ns.syncBuys and ns.syncBuys[id] or {}) do
        if b[1] > t0 and b[1] <= t1 then n = n + b[2] end
    end
    return n
end

-- { units, value, observed, perDay, last, sources } over the last `window` seconds (default 7 days).
function ns:SalesEstimate(id, window)
    if self.unitPending and self.unitPending[id] then return nil end -- old scans not yet re-checked
    local s = self.sales and self.sales[id]
    if not s or #s.snaps < 2 then return s and { units = 0, value = 0, observed = 0, sources = 1 } or nil end
    window = window or 7 * 86400
    local key = math.floor(Now() / 60) .. ":" .. window
    local c = self.salesCache[id]
    if c and c.key == key then return c.est end

    local cutoff = Now() - window
    local units, value, observed, last = 0, 0, 0, nil
    local sources = {}
    local hourObs, hourUnits = {}, {} -- per hour of the day (0-23), for the time-of-day correction
    local list = UsableSnaps(s.snaps)
    for i = 2, #list do
        local a, b = list[i - 1], list[i]
        if b.t >= cutoff then sources[a.src or "?"] = true; sources[b.src or "?"] = true end
        local gap = b.t - a.t
        if b.t >= cutoff and gap > 0 and gap <= MAX_GAP then
            observed = observed + gap
            -- Spread the watched time over the hours it covers
            local t = a.t
            while t < b.t do
                local h = tonumber(date("%H", t))
                local nextHour = t - (t % 3600) + 3600
                local seg = math.min(b.t, nextHour) - t
                hourObs[h] = (hourObs[h] or 0) + seg
                t = t + seg
            end
            local u, v = Consumed(a, b)
            if u > 0 then
                local mine = Buys(id, a.t, b.t)
                if mine > 0 then
                    local avg = v / u
                    u = math.max(0, u - mine)
                    v = math.floor(avg * u + 0.5)
                end
                if u > 0 then
                    units, value, last = units + u, value + v, b.t
                    local h = tonumber(date("%H", math.floor((a.t + b.t) / 2)))
                    hourUnits[h] = (hourUnits[h] or 0) + u
                end
            end
        end
    end
    local n = 0
    for _ in pairs(sources) do n = n + 1 end
    local est = { units = units, value = value, observed = observed, last = last, sources = n }
    if observed >= MIN_OBSERVED then
        est.perDayRaw = units / observed * 86400
        est.perDay = est.perDayRaw
        -- Time-of-day correction: average the sales rate of each hour of the day that was watched
        -- (at least 10 minutes), instead of letting heavily watched hours dominate. With 3+ hours
        -- covered this replaces the raw rate; hours never watched are assumed to be average.
        local covered, rateSum = 0, 0
        for h = 0, 23 do
            local o = hourObs[h] or 0
            if o >= 600 then
                covered = covered + 1
                rateSum = rateSum + (hourUnits[h] or 0) / o
            end
        end
        est.hoursCovered = covered
        if covered >= 3 then est.perDay = rateSum / covered * 86400 end
    end
    self.salesCache[id] = { key = key, est = est }
    return est
end

-- Sales over time, for the graph's volume bars.
-- Returns events { {t, units}, ... } and watched intervals { {from, to}, ... } between tMin and tMax.
function ns:SalesTimeline(id, tMin, tMax)
    local s = self.sales and self.sales[id]
    local events, watched = {}, {}
    if not s then return events, watched end
    local list = UsableSnaps(s.snaps)
    for i = 2, #list do
        local a, b = list[i - 1], list[i]
        local gap = b.t - a.t
        if b.t >= tMin and a.t <= tMax and gap > 0 and gap <= MAX_GAP then
            local last = watched[#watched]
            if last and a.t <= last[2] then last[2] = b.t else watched[#watched + 1] = { a.t, b.t } end
            local u = Consumed(a, b)
            if u > 0 then
                u = math.max(0, u - Buys(id, a.t, b.t))
                if u > 0 then events[#events + 1] = { b.t, u } end
            end
        end
    end
    return events, watched
end

local function Rate(d) return d >= 10 and string.format("%.0f", d) or string.format("%.1f", d) end

-- Short text for tables: "~12", "0", "watching"
function ns:SalesShort(id)
    local est = self:SalesEstimate(id)
    if not est or est.observed == 0 then return nil end
    if not est.perDay then return "|cff808080watching|r" end
    if est.units == 0 then return "|cffff50500|r" end
    return "~" .. Rate(est.perDay)
end

function ns:SalesLong(id)
    local est = self:SalesEstimate(id)
    if not est or est.observed == 0 then
        return "|cff808080Sold: needs 2 scans|r"
    end
    local watched = self.Duration(est.observed)
    local who = (est.sources or 1) > 1 and (", " .. est.sources .. " players") or ""
    if not est.perDay then
        return string.format("|cff808080Sold: %d in %s%s (need 30m)|r", est.units, watched, who)
    end
    local tod = (est.hoursCovered or 0) >= 3 and string.format(", %d/24 hours of the day", est.hoursCovered) or ""
    return string.format("|cffffd100Sold ~%s/day|r (%d in %s%s%s%s)", Rate(est.perDay), est.units, watched, who, tod,
        est.last and (", last " .. self.Ago(est.last)) or "")
end
