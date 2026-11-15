-- AH Price Tracker: profit per item. Pairs what you paid (AH buys, won bids, vendor purchases) with what
-- you sold for on the AH, first-in-first-out, and subtracts AH cuts and lost deposits.
local ADDON, ns = ...

ns.TYPE_LABEL.vendorbuy = "Vendor Buy"

---------------------------------------------------------------------------
-- Logging vendor purchases (needed to know the cost of Vendor > AH flips)
---------------------------------------------------------------------------
local function MerchantInfo(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local i = C_MerchantFrame.GetItemInfo(index)
        if i then return i.price, i.stackCount, i.hasExtendedCost end
    elseif GetMerchantItemInfo then
        local _, _, price, stack, _, _, _, ext = GetMerchantItemInfo(index)
        return price, stack, ext
    end
end

hooksecurefunc("BuyMerchantItem", function(index, quantity)
    local price, stack, ext = MerchantInfo(index)
    if not price or price <= 0 or ext then return end -- gold purchases only
    local unit = price / math.max(1, stack or 1)
    local qty = quantity or stack or 1
    local total = math.floor(unit * qty + 0.5)
    if GetMoney() < total then return end -- can't afford it: the purchase fails
    local id = GetMerchantItemID and GetMerchantItemID(index)
    local link = GetMerchantItemLink and GetMerchantItemLink(index)
    ns:AddTrade({
        type = "vendorbuy", itemID = id or ns.LinkID(link), link = link, name = ns.LinkName(link),
        qty = qty, total = total, who = UnitName("npc"),
    })
end)

---------------------------------------------------------------------------
-- Profit calculation
---------------------------------------------------------------------------
local function Key(r) return r.itemID or ("name:" .. (r.name or ns.LinkName(r.link) or "?")) end

-- rows per item, for sales/purchases made at or after `since` (0 = all time).
-- Cost basis is first-in-first-out over ALL your purchases, so older stock is used up first.
function ns:ProfitRows(since)
    since = since or 0
    local recs = self:ScopedTrades(false)
    table.sort(recs, function(a, b) return a.t < b.t end)
    local items = {}
    local function Item(r)
        local k = Key(r)
        local it = items[k]
        if not it then
            it = { key = k, id = r.itemID, name = r.name or ns.LinkName(r.link), link = r.link, lots = {},
                bought = 0, spent = 0, sold = 0, revenue = 0, cogs = 0, uncosted = 0, cut = 0, deposits = 0, refunds = 0 }
            items[k] = it
        end
        if not it.link and r.link then it.link = r.link end
        return it
    end
    for _, r in ipairs(recs) do
        local inWindow = r.t >= since
        if r.type == "ahbuy" or r.type == "ahwon" or r.type == "vendorbuy" then
            local it = Item(r)
            local qty = math.max(1, r.qty or 1)
            local total = r.total or 0
            it.lots[#it.lots + 1] = { qty = qty, unit = total / qty }
            if inWindow then
                it.bought = it.bought + qty
                it.spent = it.spent + total
                it.last = math.max(it.last or 0, r.t)
            end
        elseif r.type == "ahsell" and not r.pending then
            local it = Item(r)
            local qty = math.max(1, r.qty or 1)
            -- Use up the oldest stock first
            local left, cost = qty, 0
            while left > 0 and #it.lots > 0 do
                local lot = it.lots[1]
                local take = math.min(left, lot.qty)
                cost = cost + take * lot.unit
                lot.qty = lot.qty - take
                left = left - take
                if lot.qty <= 0 then table.remove(it.lots, 1) end
            end
            if inWindow then
                local gross = r.total or ((r.net or 0) - (r.deposit or 0) + (r.cut or 0))
                it.sold = it.sold + qty
                it.revenue = it.revenue + gross - (r.cut or 0)
                it.cut = it.cut + (r.cut or 0)
                it.cogs = it.cogs + cost
                it.uncosted = it.uncosted + left -- sold units with no purchase on record (farmed, crafted, looted)
                it.refunds = it.refunds + (r.deposit or 0)
                it.last = math.max(it.last or 0, r.t)
            end
        elseif r.type == "listed" and inWindow then
            local it = Item(r)
            it.deposits = it.deposits + (r.deposit or 0)
            it.last = math.max(it.last or 0, r.t)
        end
    end
    local rows = {}
    for _, it in pairs(items) do
        if it.bought > 0 or it.sold > 0 or it.deposits > 0 then
            it.held = 0
            for _, lot in ipairs(it.lots) do it.held = it.held + lot.qty end
            it.depositsLost = math.max(0, it.deposits - it.refunds)
            it.profit = math.floor(it.revenue - it.cogs - it.depositsLost + 0.5)
            it.avgBuy = it.bought > 0 and it.spent / it.bought or nil
            it.avgSell = it.sold > 0 and it.revenue / it.sold or nil
            it.margin = (it.cogs > 0) and (it.revenue - it.cogs) / it.cogs or nil
            rows[#rows + 1] = it
        end
    end
    return rows
end

function ns:ProfitTotals(rows)
    local t = { profit = 0, revenue = 0, cogs = 0, spent = 0, depositsLost = 0, cut = 0, items = #rows, uncosted = 0 }
    for _, r in ipairs(rows) do
        t.profit = t.profit + r.profit
        t.revenue = t.revenue + r.revenue
        t.cogs = t.cogs + r.cogs
        t.spent = t.spent + r.spent
        t.depositsLost = t.depositsLost + r.depositsLost
        t.cut = t.cut + r.cut
        t.uncosted = t.uncosted + r.uncosted
    end
    return t
end
