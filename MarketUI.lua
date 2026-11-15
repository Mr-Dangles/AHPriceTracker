-- AH Price Tracker: Market Data tab (imported auctionhouse.fyi prices for your auction house)
local ADDON, ns = ...

local ROW_H = 20
local NUM_ROWS = 16
local WHITE = "Interface\\Buttons\\WHITE8X8"
local COLUMNS = { -- key, title, width
    { "item", "Item", 226 }, { "price", "Lowest now", 86 }, { "qty", "Listed", 56 }, { "site", "Site price", 86 },
    { "diff", "Site vs now", 70 }, { "lo", "7d low", 76 }, { "hi", "7d high", 76 }, { "chg", "7d change", 62 },
    { "age", "Updated", 76 },
}
local STALE = 12 * 3600 -- prices older than this are flagged
local SOURCE_SHORT = { ["your scan"] = "you", ["price tracker"] = "you", ["another addon user"] = "shared",
    ["auctionhouse.fyi"] = "site", Auctionator = "Auctionator" }

ns.mktSort = "qty"
ns.mktAsc = false
ns.mktScroll = 0
ns.mktSearch = ""
ns.mktListedOnly = true

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

local function Pct(p)
    if not p then return "" end
    local s = string.format("%+.0f%%", p)
    if p > 0.5 then return "|cff40ff40" .. s .. "|r" end
    if p < -0.5 then return "|cffff5050" .. s .. "|r" end
    return s
end

-- Your own freshest price for an item: price, time
function ns:MyPrice(id)
    local best, t
    local e = self.items and self.items[id]
    local p = e and self:Latest(e)
    if p and p[2] then best, t = p[2], p[1] end
    local fp = self.flipPrices and self.flipPrices[id]
    if fp and fp.min and (not t or fp.t > t) then best, t = fp.min, fp.t end
    return best, t
end

local function SortValue(r, key)
    if key == "item" then return r.name:lower() end
    return r[key]
end

function ns:CreateMarketUI(f)
    local mp = CreateFrame("Frame", nil, f)
    mp:SetAllPoints()
    mp:Hide()
    self.marketPanel = mp

    self.mktMarketBtn = Button(mp, "", 150)
    self.mktMarketBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    self.mktMarketBtn:SetScript("OnClick", function(btn, button)
        -- Cycle through the six auction houses; right-click returns to your own.
        if button == "RightButton" then
            ns.settings.market = nil
        else
            local cur, nextKey = ns:MarketKey("home"), ns.MARKETS[1]
            for i, k in ipairs(ns.MARKETS) do
                if k == cur then nextKey = ns.MARKETS[i % #ns.MARKETS + 1] end
            end
            ns.settings.market = (nextKey ~= ns:AutoMarket()) and nextKey or nil
        end
        ns.mktScroll = 0
        ns:RefreshMarket()
        if ns.OnFlipsUpdated then ns:OnFlipsUpdated() end
    end)
    self.mktMarketBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    self.mktMarketBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Auction house")
        GameTooltip:AddLine("Forever has six separate auction houses (Normal, PvP and RP, each Horde and Alliance). Yours is picked from your realm and faction.", 1, 1, 1, true)
        GameTooltip:AddLine("Left-click: next auction house   Right-click: back to yours", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    self.mktMarketBtn:SetScript("OnLeave", GameTooltip_Hide)

    local search = CreateFrame("EditBox", nil, mp, "SearchBoxTemplate")
    search:SetSize(180, 20)
    search:SetPoint("LEFT", self.mktMarketBtn, "RIGHT", 14, 0)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(box)
        ns.mktSearch = strtrim(box:GetText() or ""):lower()
        ns.mktScroll = 0
        ns:RefreshMarket()
    end)

    local cb = CreateFrame("CheckButton", nil, mp, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("LEFT", search, "RIGHT", 10, 0)
    cb:SetChecked(ns.mktListedOnly)
    cb:SetScript("OnClick", function(btn)
        ns.mktListedOnly = btn:GetChecked() and true or false
        ns.mktScroll = 0
        ns:RefreshMarket()
    end)
    local cbLabel = mp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cbLabel:SetText("Only items listed now")

    self.mktSource = mp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.mktSource:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -38)
    self.mktSource:SetJustifyH("RIGHT")

    self.mktSummary = mp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.mktSummary:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -62)
    self.mktSummary:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    self.mktSummary:SetJustifyH("LEFT")
    self.mktSummary:SetWordWrap(false)

    local list = CreateFrame("Frame", nil, mp, "BackdropTemplate")
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -84)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        ns.mktScroll = ns.mktScroll - delta * 3
        ns:RefreshMarket(true)
    end)

    self.mktHeaders = {}
    local x = 4
    for _, col in ipairs(COLUMNS) do
        local key = col[1]
        local h = CreateFrame("Button", nil, list)
        h:SetSize(col[3] - 4, 18)
        h:SetPoint("TOPLEFT", x, -3)
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.text:SetAllPoints()
        h.text:SetJustifyH(key == "item" and "LEFT" or "RIGHT")
        h.title = col[2]
        h.key = key
        h:SetHighlightTexture(WHITE)
        h:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)
        h:SetScript("OnClick", function()
            if ns.mktSort == key then
                ns.mktAsc = not ns.mktAsc
            else
                ns.mktSort, ns.mktAsc = key, (key == "item")
            end
            ns:RefreshMarket()
        end)
        self.mktHeaders[#self.mktHeaders + 1] = h
        x = x + col[3]
    end
    local sep = list:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.15)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 4, -22)
    sep:SetPoint("TOPRIGHT", -4, -22)

    self.mktEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.mktEmpty:SetPoint("CENTER")
    self.mktEmpty:SetWidth(600)

    self.mktRows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 4, -24 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", list, "RIGHT", -4, 0)
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0)
        row:SetHighlightTexture(WHITE)
        row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
        row.cells = {}
        local cx = 2
        for _, col in ipairs(COLUMNS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", cx, 0)
            fs:SetWidth(col[3] - 6)
            fs:SetJustifyH(col[1] == "item" and "LEFT" or "RIGHT")
            fs:SetWordWrap(false)
            row.cells[col[1]] = fs
            cx = cx + col[3]
        end
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(btn, button)
            local r = btn.rec
            if not r then return end
            if button == "RightButton" then
                -- Random-suffix gear is tracked as its base item.
                ns:ShowItemMenu(btn, r.base)
            elseif IsModifiedClick("CHATLINK") then
                ns:LinkInChat(r.base)
            end
        end)
        row:SetScript("OnEnter", function(btn) ns:ShowMarketTooltip(btn, btn.rec) end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        self.mktRows[i] = row
    end

    self.mktCount = mp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.mktCount:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    self.mktHelp = mp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.mktHelp:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 16)
    self.mktHelp:SetText("Update: run \"Update Market Data.bat\" in the addon folder, then /reload")
end

function ns:ShowMarketTooltip(owner, r)
    if not r then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if r.key == r.base then GameTooltip:SetItemByID(r.base) else GameTooltip:AddLine(r.name, 1, 1, 1) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ns.MarketLabel(self:MarketKey()) .. " auction house", 1, 0.82, 0)
    if r.price or r.none then
        GameTooltip:AddDoubleLine("Lowest now (" .. (r.source or "?") .. ")", r.none and "none listed" or self.Money(r.price),
            0.8, 0.8, 0.8, 1, 1, 1)
        if not r.none then GameTooltip:AddDoubleLine("Listed", tostring(r.qty or 0), 0.8, 0.8, 0.8, 1, 1, 1) end
        if r.t then
            GameTooltip:AddDoubleLine("Seen", self.Ago(r.t), 0.8, 0.8, 0.8, r.stale and 1 or 1, r.stale and 0.6 or 1, r.stale and 0 or 1)
        end
    end
    if r.siteT then
        GameTooltip:AddDoubleLine("auctionhouse.fyi", (r.site and self.Money(r.site) or "none listed") .. "   x" .. (r.siteQty or 0)
            .. "   " .. self.Ago(r.siteT), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.stale then
        GameTooltip:AddLine("Stale: nobody has scanned this in over 12 hours. Prices on a new server move fast.", 1, 0.6, 0, true)
    end
    if #r.days > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("auctionhouse.fyi daily close (lowest buyout), listed", 0.6, 0.6, 0.6)
        for i = #r.days, math.max(1, #r.days - 9), -1 do
            local d = r.days[i]
            GameTooltip:AddDoubleLine(date("%a %d %b", d.day * 86400 + 43200),
                (d.close and self.Money(d.close) or "none") .. "   x" .. (d.qty or 0), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    end
    local sales = self.SalesLong and self:SalesLong(r.base)
    if sales then GameTooltip:AddLine(" "); GameTooltip:AddLine(sales, 1, 1, 1, true) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: track, search the AH, link in chat", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- Builds the full row list (cached until the data, market or filters change).
-- "Lowest now" is the freshest price from any source: your scans, other addon users' scans, or the site.
function ns:BuildMarketRows()
    local items, scan = self:MarketItems()
    items = items or {}
    local keys = {}
    for key in pairs(items) do keys[key] = true end
    for id in pairs(self.sales or {}) do keys[id] = true end
    for id in pairs(self.items or {}) do keys[id] = true end
    for id in pairs(self.flipPrices or {}) do keys[id] = true end

    local rows, now = {}, time()
    local q = self.mktSearch
    for key in pairs(keys) do
        local name, quality, base = self:MarketName(key)
        name = name or ("Item " .. key)
        if q == "" or name:lower():find(q, 1, true) then
            local site = self:GetSitePrice(key)
            local fresh = (key == base) and self:GetAHPrice(base) or nil
            if not fresh and site and self:PriceSource() ~= "local" then
                fresh = { price = site.price, qty = site.qty, t = site.t, none = site.none, source = "auctionhouse.fyi" }
            end
            if fresh and (fresh.price or not self.mktListedOnly) then
                local siteFresh = fresh.source == "auctionhouse.fyi"
                local lo, hi, chg
                if site then lo, hi, chg = ns.DayStats(site.days, 7) end
                rows[#rows + 1] = {
                    key = key, base = base, name = name, quality = quality,
                    price = fresh.price, qty = fresh.qty, none = fresh.none, t = fresh.t,
                    source = fresh.source, sourceShort = SOURCE_SHORT[fresh.source] or fresh.source,
                    stale = not fresh.t or now - fresh.t > STALE,
                    site = site and site.price, siteQty = site and site.qty, siteT = site and site.t,
                    siteStale = site and site.t and now - site.t > STALE,
                    diff = (not siteFresh and site and site.price and fresh.price and fresh.price > 0)
                        and (site.price - fresh.price) / fresh.price * 100 or nil,
                    days = site and site.days or {}, lo = lo, hi = hi, chg = chg,
                    age = fresh.t,
                }
            end
        end
    end
    return rows, scan
end

function ns:RefreshMarket(scrollOnly)
    if not (self.marketPanel and self.mktRows) then return end
    local key = self:MarketKey()
    self.mktMarketBtn:SetText(ns.MarketLabel(key) .. (self.settings.market and " *" or ""))

    local data = self:MarketData()
    if not scrollOnly or not self.mktCache then
        local rows, scan = self:BuildMarketRows()
        local sk, asc = self.mktSort, self.mktAsc
        table.sort(rows, function(a, b)
            local va, vb = SortValue(a, sk), SortValue(b, sk)
            if va == nil or vb == nil or va == vb then
                if (va == nil) ~= (vb == nil) then return vb == nil end
                return a.name < b.name
            end
            if asc then return va < vb end
            return va > vb
        end)
        self.mktCache, self.mktScan = rows, scan
    end
    local rows, scan = self.mktCache, self.mktScan

    for _, h in ipairs(self.mktHeaders) do
        h.text:SetText(h.title .. ((h.key == self.mktSort) and (self.mktAsc and " ^" or " v") or ""))
    end

    if data then
        self.mktSource:SetText(string.format("auctionhouse.fyi player scans · file made %s", self.Ago(data.generated)))
    else
        self.mktSource:SetText("")
    end
    local fresh, stale = 0, 0
    for _, r in ipairs(rows) do if r.stale then stale = stale + 1 else fresh = fresh + 1 end end
    local siteText
    if scan then
        local old = time() - scan > STALE
        siteText = string.format("site's last scan %s", old and ("|cffff9900" .. self.Ago(scan) .. "|r") or self.Ago(scan))
    else
        siteText = data and "no site scans for this auction house" or "no site data file"
    end
    self.mktSummary:SetText(string.format("%s:  %d prices seen in the last 12h,  |cffff9900%d stale|r   |   %s",
        ns.MarketLabel(key), fresh, stale, siteText))

    self.mktScroll = math.max(0, math.min(self.mktScroll, #rows - NUM_ROWS))
    self.mktEmpty:SetShown(#rows == 0)
    if #rows == 0 then
        if not data then
            self.mktEmpty:SetText("No market data file yet.\n\nClose the game or alt-tab, open the addon folder\n(Interface\\AddOns\\AHPriceTracker) and double-click \"Update Market Data.bat\".\nThen type /reload here.")
        elseif self.mktSearch ~= "" then
            self.mktEmpty:SetText("No items match your search.")
        else
            self.mktEmpty:SetText("No data for this auction house. Left-click the button at the top left to look at another one.")
        end
    end

    for i, row in ipairs(self.mktRows) do
        local r = rows[i + self.mktScroll]
        row.rec = r
        if r then
            local c = row.cells
            local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(r.base)
            local color = (r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]) and ITEM_QUALITY_COLORS[r.quality].hex or "|cffffffff"
            c.item:SetText((icon and ("|T" .. icon .. ":14:14|t ") or "") .. color .. r.name .. "|r")
            c.price:SetText(r.none and "|cffffd100none|r" or self.Money(r.price))
            c.qty:SetText(r.none and "" or tostring(r.qty or 0))
            if r.siteT then
                local txt = r.site and self.Money(r.site) or "none"
                c.site:SetText(r.siteStale and ("|cff808080" .. (r.site and ns.ShortMoney(r.site) or "none") .. "|r") or txt)
            else
                c.site:SetText("")
            end
            c.diff:SetText(Pct(r.diff))
            -- 7-day figures come from the site; grey them out when its data is stale.
            local grey = r.siteStale and "|cff808080" or ""
            local close = r.siteStale and "|r" or ""
            c.lo:SetText(r.lo and (grey .. ns.ShortMoney(r.lo) .. close) or "")
            c.hi:SetText(r.hi and (grey .. ns.ShortMoney(r.hi) .. close) or "")
            c.chg:SetText(r.siteStale and (r.chg and (grey .. string.format("%+.0f%%", r.chg) .. close) or "") or Pct(r.chg))
            local age = r.t and self.Ago(r.t) or "?"
            c.age:SetText((r.stale and "|cffff9900" or "") .. age .. (r.stale and "|r" or "")
                .. " |cff808080" .. (r.sourceShort or "") .. "|r")
            row:Show()
        else
            row:Hide()
        end
    end
    self.mktCount:SetText(string.format("%d items. Click a column to sort, click a row to track it.", #rows))
end
