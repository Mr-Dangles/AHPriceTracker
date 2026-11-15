-- AH Price Tracker: crafting profit for every profession (recipe data in Recipes.lua), plus the market
-- value of what gathering professions collect. Answers "is this profession worth starting?".
local ADDON, ns = ...

ns.BRACKETS = { { 1, 75 }, { 75, 150 }, { 150, 225 }, { 225, 300 }, { 300, 1000 } }

-- Gathering professions: what they collect, picked out of the item catalogue by type and name.
-- { label, test(name, class, subclass) }. Trade Goods subclasses: 5 cloth, 6 leather, 7 metal & stone, 8 meat, 9 herb.
local FISH = { "fish", "snapper", "eel", "albacore", "squid", "salmon", "catfish", "mackerel", "lobster",
    "sagefish", "yellowtail", "grouper", "smallfish", "mightfish", "firefin", "blackmouth", "cod", "loach" }
ns.GATHERING = {
    { key = "herbalism", label = "Herbalism", test = function(n, c, sc) return c == 7 and sc == 9 end },
    { key = "mining", label = "Mining (ore and stone)", test = function(n, c, sc)
        return c == 7 and sc == 7 and (n:find("Ore") or n:find("Stone") or n == "Coal") and not n:find("Bar") end },
    { key = "skinning", label = "Skinning", test = function(n, c, sc)
        return c == 7 and sc == 6 and (n:find("Leather") or n:find("Hide") or n:find("Scale")) and not n:find("Cured") end },
    { key = "fishing", label = "Fishing", test = function(n, c, sc)
        if not (c == 7 or c == 0) then return false end
        local l = n:lower()
        if not l:find("^raw ") and c ~= 7 then return false end
        for _, w in ipairs(FISH) do if l:find(w) then return true end end
        return false
    end },
}

function ns:RecipeData()
    local d = _G.AHPT_Recipes
    return type(d) == "table" and d.professions and d or nil
end

function ns:ItemName(id)
    local name = (C_Item and C_Item.GetItemInfo or GetItemInfo)(id)
    if name then return name end
    local r = self:RecipeData()
    if r and r.names and r.names[id] then return r.names[id] end
    return (self.MarketName and self:MarketName(id)) or ("Item " .. id)
end

-- Cheapest known way to get one unit: from a vendor (if one is known to sell it) or the AH.
-- Returns price, source ("vendor" / "AH"), or nil if unknown.
function ns:UnitCost(id)
    local v = self.vendor and self.vendor[id]
    local ah = self:GetAHPrice(id)
    local ahp = ah and ah.price
    if v and v.price and (not ahp or v.price <= ahp) then
        local d = _G.AHPT_MarketData
        local c = d and d.names and d.names[id]
        local bundle = v.stack or (c and c[9]) or nil
        return v.price, bundle and string.format("vendor, %d for %s", bundle, ns.Money(v.price * bundle)) or "vendor"
    end
    if ahp then return ahp, "AH" end
    return nil
end

-- What a vendor pays for one unit (game data, or the catalogue until the item is cached).
function ns:VendorSell(id)
    local sell = select(11, (C_Item and C_Item.GetItemInfo or GetItemInfo)(id))
    if sell and sell > 0 then return sell end
    local d = _G.AHPT_MarketData
    local c = d and d.names and d.names[id]
    return c and c[5] or nil
end

-- One row per recipe for a profession.
function ns:CraftingRows(profId)
    local data = self:RecipeData()
    local prof = data and data.professions[profId]
    if not prof then return {}, nil end
    local rows = {}
    for _, rc in ipairs(prof.recipes) do
        local spell, name, _, low, high, item, count, recipeItem, reagents = unpack(rc)
        local r = {
            spell = spell, name = name, item = item, count = count, low = low, high = high,
            recipeItem = recipeItem or nil, reagents = {}, known = self.db.knownRecipes and self.db.knownRecipes[spell],
        }
        local cost, missing = 0, false
        for i = 1, #reagents, 2 do
            local id, n = reagents[i], reagents[i + 1]
            local unit, src = self:UnitCost(id)
            r.reagents[#r.reagents + 1] = { id = id, n = n, unit = unit, src = src }
            if unit then cost = cost + unit * n else missing = true end
        end
        r.cost = (not missing) and cost or nil
        r.partialCost = missing and cost or nil
        local ah = self:GetAHPrice(item)
        r.ahPrice = ah and ah.price
        r.ahQty = ah and ah.qty
        r.sells = r.ahPrice and (r.ahPrice * count * (1 - ns:AHCut())) or nil
        r.vendorSell = self:VendorSell(item)
        if r.sells and r.cost then
            r.profit = r.sells - r.cost
            r.margin = r.cost > 0 and r.profit / r.cost or nil
        end
        local s = self.SalesEstimate and self:SalesEstimate(item)
        r.soldDay = s and s.perDay
        if r.profit and r.soldDay then r.profitDay = r.profit * math.min(r.soldDay / count, 1e9) end
        if recipeItem then
            local rp = self:GetAHPrice(recipeItem)
            r.recipePrice = rp and rp.price
        end
        rows[#rows + 1] = r
    end
    return rows, prof.name
end

-- Gathering view: items the profession collects, with their market value.
function ns:GatheringRows(key)
    local def
    for _, g in ipairs(self.GATHERING) do if g.key == key then def = g end end
    local d = _G.AHPT_MarketData
    if not (def and d and d.names) then return {}, def and def.label end
    local rows = {}
    for id, c in pairs(d.names) do
        if c[3] == id and def.test(c[1], c[6], c[7]) then
            local ah = self:GetAHPrice(id)
            local s = self.SalesEstimate and self:SalesEstimate(id)
            local price = ah and ah.price
            rows[#rows + 1] = {
                item = id, name = c[1], low = c[8] or 0, ahPrice = price, ahQty = ah and ah.qty,
                sells = price and math.floor(price * (1 - ns:AHCut())) or nil, soldDay = s and s.perDay,
                profit = price and math.floor(price * (1 - ns:AHCut())) or nil, gather = true,
                profitDay = (price and s and s.perDay) and math.floor(price * (1 - ns:AHCut()) * s.perDay) or nil,
            }
        end
    end
    return rows, def.label
end

-- Per skill bracket: how many recipes are profitable and the best one. For gathering, brackets use item level.
function ns:BracketSummary(rows, gathering)
    local out = {}
    for i, b in ipairs(self.BRACKETS) do
        local s = { from = b[1], to = b[2], total = 0, priced = 0, profitable = 0 }
        local lo, hi = b[1], b[2]
        if gathering then lo, hi = math.floor(b[1] / 5), math.floor(b[2] / 5) end -- item level ~ skill / 5
        for _, r in ipairs(rows) do
            local lvl = r.low or 0
            if lvl >= lo and lvl < hi then
                s.total = s.total + 1
                if r.profit then
                    s.priced = s.priced + 1
                    if r.profit > 0 then s.profitable = s.profitable + 1 end
                    if not s.best or r.profit > s.best.profit then s.best = r end
                    if r.profitDay and (not s.bestDay or r.profitDay > s.bestDay.profitDay) then s.bestDay = r end
                end
            end
        end
        out[i] = s
    end
    return out
end

-- Remember which recipes you know, from your profession windows.
function ns:RememberKnownRecipes()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then return end
    self.db.knownRecipes = self.db.knownRecipes or {}
    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    for _, rid in ipairs(ok and ids or {}) do
        local ok2, info = pcall(C_TradeSkillUI.GetRecipeInfo, rid)
        if ok2 and info and info.learned then self.db.knownRecipes[rid] = true end
    end
end
hooksecurefunc(ns, "ScanProfession", function(self) self:RememberKnownRecipes() end)
