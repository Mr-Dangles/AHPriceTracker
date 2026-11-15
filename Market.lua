-- AH Price Tracker: imported market data (auctionhouse.fyi, written by "Update Market Data.bat")
-- Forever has six separate auction houses: Normal / PvP / RP, each with Horde and Alliance.
local ADDON, ns = ...

ns.MARKETS = { "normal.horde", "normal.alliance", "pvp.horde", "pvp.alliance", "rp.horde", "rp.alliance" }
local LABEL = { normal = "Normal", pvp = "PvP", rp = "RP", horde = "Horde", alliance = "Alliance" }

LABEL.neutral = "Neutral (goblin)"
function ns.MarketLabel(key)
    local rules, side = (key or ""):match("^(%a+)%.(%w+)$")
    if not rules then return "?" end
    return (LABEL[rules] or rules) .. " " .. (LABEL[side] or ns:HouseLabel(side))
end

-- Your own market, guessed from the realm name and your faction.
function ns:AutoMarket()
    local realm = (GetRealmName() or ""):lower()
    local rules = "normal"
    if realm:find("%f[%a]pvp%f[%A]") then
        rules = "pvp"
    elseif realm:find("%f[%a]rp%f[%A]") or realm:find("roleplay") then
        rules = "rp"
    end
    local side = (UnitFactionGroup("player") or "Horde"):lower()
    if side ~= "alliance" then side = "horde" end
    return rules .. "." .. side
end

-- The auction house's key, used to match shared scans and auctionhouse.fyi data. The neutral goblin
-- house is shared by both factions ("normal.neutral"); auctionhouse.fyi has no data for it.
function ns:MarketKey(house)
    local base = self.settings.market or self:AutoMarket()
    house = house or self.house or "home"
    if house == "home" then return base end
    return (base:match("^(%a+)%.") or "normal") .. "." .. house
end

-- Which of this realm's houses a market key belongs to (nil if none we keep).
function ns:HouseForKey(key)
    if key == self:MarketKey("home") then return "home" end
    if key == self:MarketKey("neutral") then return "neutral" end
    for k in pairs(self.realmData.houses or {}) do
        if key == self:MarketKey(k) then return k end
    end
end

function ns:MarketData()
    local d = _G.AHPT_MarketData
    if type(d) ~= "table" or type(d.markets) ~= "table" then return nil end
    return d
end

function ns:MarketItems(key)
    local d = self:MarketData()
    local m = d and d.markets[key or self:MarketKey()]
    return m and m.items, m and m.scan
end

function ns:MarketName(key)
    local d = self:MarketData()
    local n = d and d.names and d.names[key]
    if n then return n[1], n[2], n[3] or key end
    local name, _, quality = (C_Item and C_Item.GetItemInfo or GetItemInfo)(key)
    return name, quality, key
end

-- Site price for an item in your market: { price, qty, t, days = { {day, low, close, qty}, ... } }
function ns:GetSitePrice(id)
    local items = self:MarketItems()
    local r = items and items[id]
    if not r then return nil end
    local out = { price = r[1] or nil, qty = r[2] or 0, t = r[3], none = r[1] == false, days = {} }
    local d = r[4]
    for i = 1, #d, 4 do
        out.days[#out.days + 1] = { day = d[i], low = d[i + 1] or nil, close = d[i + 2] or nil, qty = d[i + 3] or 0 }
    end
    return out
end

-- Low / high of daily closes and the change from the first to the last day, over the last `n` days.
function ns.DayStats(days, n)
    local today = math.floor(time() / 86400)
    local lo, hi, first, last
    for _, d in ipairs(days) do
        if d.close and d.day > today - (n or 7) then
            lo = lo and math.min(lo, d.low or d.close) or (d.low or d.close)
            hi = hi and math.max(hi, d.close) or d.close
            first = first or d.close
            last = d.close
        end
    end
    local change = (first and last and first > 0 and first ~= last) and (last - first) / first * 100 or nil
    return lo, hi, change
end
