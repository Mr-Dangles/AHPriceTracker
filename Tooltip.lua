-- AH Price Tracker: item tooltip lines (every item tooltip: the tracker's pages, bags, the AH, chat links)
--
-- The game's own "Sell Price" line is what a vendor pays YOU. For flipping you need the opposite: what a
-- vendor charges for the item. This adds that, plus the AH price and the flip margin after the cut.
local ADDON, ns = ...

local TAG = "|cff59d9cc"

local function AddLines(tip, id)
    if not (id and ns.vendor and ns.Money) then return end
    local v = ns.vendor[id]
    local d = _G.AHPT_MarketData
    local c = d and d.names and d.names[id]
    local price, confirmed = v and v.price, v ~= nil
    if not price and c and c[4] then price = c[4] end -- game data: what it costs if a vendor sells it
    if not price or price <= 0 then return end
    local bundle = (v and v.stack) or (c and c[9]) or nil

    local txt = ns.Money(price) .. " each"
    if bundle and bundle > 1 then txt = txt .. string.format(" (%d for %s)", bundle, ns.Money(price * bundle)) end
    if confirmed then
        tip:AddDoubleLine(TAG .. "Vendor sells it for|r", txt, 1, 1, 1, 1, 1, 1)
    else
        tip:AddDoubleLine(TAG .. "Vendor price, if sold|r", txt, 1, 1, 1, 0.7, 0.7, 0.7)
    end

    local ah = ns.GetAHPrice and ns:GetAHPrice(id)
    if ah and ah.price and ah.price > 0 then
        local cut = ns:AHCut()
        local profit = ah.price * (1 - cut) - price
        local pct = profit / price * 100
        tip:AddDoubleLine(TAG .. "AH lowest|r", ns.Money(ah.price) .. " each", 1, 1, 1, 1, 1, 1)
        tip:AddDoubleLine(TAG .. string.format("Flip after %d%% cut|r", cut * 100 + 0.5),
            string.format("%s%s each (%+.0f%%)|r", profit >= 0 and "|cff40ff40+" or "|cffff5050-",
                ns.Money(math.abs(profit)), pct), 1, 1, 1, 1, 1, 1)
    end
    if not confirmed then
        tip:AddLine("No vendor has been seen selling this; many items aren't sold by any vendor.", 0.6, 0.6, 0.6, true)
    end
end

local function ItemID(tip, data)
    if data and data.id and not (issecretvalue and issecretvalue(data.id)) then return data.id end
    if tip.GetItem then
        local ok, _, link = pcall(tip.GetItem, tip)
        local id = ok and link and tonumber(link:match("item:(%d+)"))
        return id
    end
end

-- Hide the game's "Sell Price" line (what a vendor pays you): for buying from vendors and selling on the
-- AH it only gets confused with the vendor's price. The line above shows what a vendor charges instead.
if TooltipDataProcessor and TooltipDataProcessor.AddLinePreCall and Enum.TooltipDataLineType
    and Enum.TooltipDataLineType.SellPrice then
    TooltipDataProcessor.AddLinePreCall(Enum.TooltipDataLineType.SellPrice, function(tip)
        if tip == GameTooltip or tip == ItemRefTooltip then return true end -- true = skip the game's line
    end)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip, data)
        if tip ~= GameTooltip and tip ~= ItemRefTooltip then return end
        -- The Flip Finder's own tooltip already shows all of this
        local owner = tip.GetOwner and tip:GetOwner()
        if ns.tab == "flips" and ns.frame and ns.frame:IsShown() and owner and owner.IsObjectType
            and owner:IsObjectType("Frame") and ns.frame:IsMouseOver() then return end
        local ok, err = pcall(AddLines, tip, ItemID(tip, data))
        if not ok then ns.tooltipError = err end
    end)
else
    GameTooltip:HookScript("OnTooltipSetItem", function(tip)
        pcall(AddLines, tip, ItemID(tip))
    end)
end
