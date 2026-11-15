-- AH Price Tracker: window, item list and price history graph
local ADDON, ns = ...

local ROW_H = 30
local NUM_ROWS = 12
-- Time windows for the graph. ma = moving-average window for that view ("All" uses a tenth of the span).
local RANGES = {
    { label = "1h",  secs = 3600,       ma = 10 * 60 },
    { label = "6h",  secs = 6 * 3600,   ma = 3600 },
    { label = "12h", secs = 12 * 3600,  ma = 2 * 3600 },
    { label = "24h", secs = 86400,      ma = 3 * 3600 },
    { label = "7d",  secs = 7 * 86400,  ma = 86400 },
    { label = "30d", secs = 30 * 86400, ma = 3 * 86400 },
    { label = "All", secs = nil },
}
local COLOR_MIN = { 1, 0.82, 0 }      -- lowest buyout
local COLOR_MKT = { 0.35, 0.7, 1 }    -- market (cheapest 15%)
local WHITE = "Interface\\Buttons\\WHITE8X8"

ns.range = 5 -- 7d
ns.scroll = 0

-- Graph legend entries. key = the setting it toggles (nil = can't be hidden).
-- show(mode, gs) decides whether the entry applies right now (mode = price data source).
ns.LEGEND = {
    { key = "lowest", label = "Lowest", shape = "line", color = { 1, 0.82, 0 }, title = "Lowest buyout",
        help = "The cheapest price per unit listed at each scan. This is the price a buyer pays for the first unit.",
        read = "One cheap listing can make it jump, so compare it with Market.",
        show = function(m) return m ~= "online" end },
    { key = "market", label = "Market", shape = "line", color = { 0.35, 0.7, 1 }, title = "Market (cheapest 15%)",
        help = "The average price of the cheapest 15% of all units listed. It's what you'd really pay for a normal amount, and the price you compete with when you list a stack.",
        read = "Close to Lowest: deep, stable supply. Well above Lowest: only a few cheap units at the bottom, and the price jumps once they sell.",
        show = function(m) return m ~= "online" end },
    { key = "ma", label = "Avg", shape = "line", color = { 0.78, 0.5, 1 }, title = "Moving average",
        help = "The average lowest buyout over a sliding window. The window grows with the view: 10 minutes on 1h, 1 hour on 6h, 2 hours on 12h, 3 hours on 24h, 1 day on 7d, 3 days on 30d.",
        read = "Price above the average: rising or expensive right now. Below it: falling or cheap.",
        show = function(m) return m ~= "online" end },
    { key = "bands", label = "Bands", shape = "line", color = { 0.6, 0.6, 0.75 }, title = "Bollinger bands",
        help = "The moving average plus and minus two standard deviations: the price's normal recent range.",
        read = "Near the top band: expensive compared with recent history, a good time to sell. Near the bottom band: cheap, a good time to buy. Wide bands mean a volatile price.",
        show = function(m) return m ~= "online" end },
    { key = nil, label = "Site daily", shape = "line", color = { 0.55, 0.9, 0.45 }, title = "auctionhouse.fyi daily close",
        help = "The lowest buyout at the end of each day, from scans other players uploaded to auctionhouse.fyi. Shown when Price data is Online or Mixed.",
        read = "One point per day. It can be stale if nobody has uploaded a recent scan of your auction house.",
        show = function(m) return m ~= "local" end },
    { key = "volume", label = "Sold", shape = "bar", color = { 0.2, 0.8, 0.7 }, title = "Volume: units sold",
        help = "Bars in the lower pane: estimated units bought in each time slice, from scans by you and other addon users. Buyers take the cheapest units first, so when cheap listings shrink between scans, those units count as sold.",
        read = "Tall bars: real demand. No bars over watched time: nobody is buying.",
        show = function(m) return m ~= "online" end },
    { key = "listed", label = "Listed", shape = "line", color = { 1, 0.55, 0.15 }, title = "Listed (supply)",
        help = "Orange line in the lower pane: how many units were on the AH at each scan.",
        read = "Falling with steady prices: buyers are taking stock. Rising with falling prices: more sellers are arriving and undercutting.",
        show = function(m) return m ~= "online" end },
    { key = nil, label = "Not watched", shape = "box", color = { 0.5, 0.5, 0.5, 0.35 }, title = "Not watched",
        help = "Grey columns in the lower pane: nobody running the addon was scanning this item then, so sales are unknown, not zero.",
        show = function(m, gs) return m ~= "online" and (gs.volume or gs.listed) end },
    { key = "trades", label = "Your buys / sales", shape = "square", color = { 0.25, 1, 0.35 }, color2 = { 1, 0.25, 0.25 },
        title = "Your trades",
        help = "Squares at the price you paid (green) or sold at (red), per unit. Hover a square for the details.",
        show = function() return true end },
}


StaticPopupDialogs["AHPT_REMOVE"] = {
    text = "Stop tracking %s and delete its price history?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data) ns:RemoveItem(data) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Prices list sorting: key, label, value function (nil values go last), ascending by default?
ns.LIST_SORTS = {
    { "name", "Name", function(e) return (e.name or ""):lower() end, true },
    { "price", "Price", function(e) local p = ns:DisplayPrice(e.id); return p and p.price end, false },
    { "chg24", "24h change", function(e) return ns:Change(e, 86400) end, false },
    { "chg7", "7d change", function(e) return ns:Change(e, 7 * 86400) end, false },
    { "sold", "Sold per day", function(e)
        -- Uses the early rate before the 30 minutes needed for a displayed rate, so sorting works right away.
        local s = ns.SalesEstimate and ns:SalesEstimate(e.id)
        if not s or s.observed == 0 then return nil end
        return s.perDay or (s.units / s.observed * 86400)
    end, false },
    { "listed", "Listed now", function(e) local p = ns:DisplayPrice(e.id); return p and p.qty end, false },
    { "added", "Recently added", function(e) return e.added end, false },
    { "scanned", "Last scanned", function(e) return e.lastScan end, false },
}

local function SortedIDs()
    local ids = {}
    for id in pairs(ns.items or {}) do ids[#ids + 1] = id end
    local key = ns.settings and ns.settings.listSort or "name"
    local spec = ns.LIST_SORTS[1]
    for _, s in ipairs(ns.LIST_SORTS) do if s[1] == key then spec = s end end
    local asc = ns.settings.listAsc
    if asc == nil then asc = spec[4] end
    local vals = {}
    for _, id in ipairs(ids) do vals[id] = spec[3](ns.items[id]) end
    table.sort(ids, function(a, b)
        local va, vb = vals[a], vals[b]
        if va == nil or vb == nil or va == vb then
            if (va == nil) ~= (vb == nil) then return vb == nil end -- unknowns last
            local na, nb = ns.items[a].name or tostring(a), ns.items[b].name or tostring(b)
            if na == nb then return a < b end
            return na < nb
        end
        if asc then return va < vb end
        return va > vb
    end)
    return ids
end

local function ChangeText(pct)
    if not pct then return "" end
    local color = pct > 0.05 and "|cff40ff40" or pct < -0.05 and "|cffff5050" or "|cffaaaaaa"
    return string.format("%s%+.1f%%|r", color, pct)
end

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
function ns:CreateUI()
    if self.frame then return end

    local f = CreateFrame("Frame", "AHPriceTrackerFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(880, 490)
    f:SetPoint("CENTER")
    f:SetFrameStrata("MEDIUM") -- same layer as game windows (mailbox, AH): never hides them
    f:SetToplevel(true)       -- clicking it brings it to the front, clicking them brings them forward
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, f:GetName())
    if f.TitleText then
        f.TitleText:SetText("AH Price Tracker")
    else
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
        title:SetText("AH Price Tracker")
    end
    self.frame = f

    -- Price data source (applies to every page): title bar, left of the close button
    self.sourceBtn = Button(f, "", 170, 18)
    self.sourceBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -3)
    self.sourceBtn:SetScript("OnClick", function(btn)
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(btn, function(_, root)
                root:CreateTitle("Price data for every page")
                for _, s in ipairs(ns.PRICE_SOURCES) do
                    local r = root:CreateRadio(s[2], function() return ns:PriceSource() == s[1] end,
                        function() ns:SetPriceSource(s[1]) end)
                    if r.SetTooltip then
                        r:SetTooltip(function(tip) GameTooltip_SetTitle(tip, s[2]); GameTooltip_AddNormalLine(tip, s[3]) end)
                    end
                end
            end)
        else
            local cur, nextKey = ns:PriceSource(), ns.PRICE_SOURCES[1][1]
            for i, s in ipairs(ns.PRICE_SOURCES) do
                if s[1] == cur then nextKey = ns.PRICE_SOURCES[i % #ns.PRICE_SOURCES + 1][1] end
            end
            ns:SetPriceSource(nextKey)
        end
    end)
    self.sourceBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Price data")
        for _, s in ipairs(ns.PRICE_SOURCES) do
            local on = ns:PriceSource() == s[1]
            GameTooltip:AddLine((on and "> " or "  ") .. s[2] .. ": " .. s[3], on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7, true)
        end
        GameTooltip:Show()
    end)
    self.sourceBtn:SetScript("OnLeave", GameTooltip_Hide)
    self:UpdateSourceButton()

    -- Character scope (Trade History, Profit, My Auctions): this character / realm / whole account
    self.scopeBtn = Button(f, "", 150, 18)
    self.scopeBtn:SetPoint("RIGHT", self.sourceBtn, "LEFT", -4, 0)
    self.scopeBtn:SetScript("OnClick", function(btn)
        local function choose(k)
            ns.settings.scope = (k ~= "realm") and k or nil
            ns.profitCache = nil
            ns:UpdateScopeButton()
            ns:RefreshAll()
        end
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(btn, function(_, root)
                root:CreateTitle("Show records from")
                for _, s in ipairs(ns.SCOPES) do
                    root:CreateRadio(s[2], function() return ns:Scope() == s[1] end, function() choose(s[1]) end)
                end
            end)
        else
            local cur, nextKey = ns:Scope(), ns.SCOPES[1][1]
            for i, s in ipairs(ns.SCOPES) do if s[1] == cur then nextKey = ns.SCOPES[i % #ns.SCOPES + 1][1] end end
            choose(nextKey)
        end
    end)
    self.scopeBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Characters")
        GameTooltip:AddLine("Whose trades, profit and auctions to show: just this character, every character on this realm, or your whole account across realms.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    self.scopeBtn:SetScript("OnLeave", GameTooltip_Hide)
    self:UpdateScopeButton()

    -- Auction house whose data every page shows (title bar, left). Picked automatically when you open
    -- an auction house; switch here to look at another one.
    self.houseBtn = Button(f, "", 150, 18)
    self.houseBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -3)
    self.houseBtn:SetScript("OnClick", function(btn)
        local houses = ns:KnownHouses()
        if not (MenuUtil and MenuUtil.CreateContextMenu) then
            local nextKey = houses[1]
            for i, k in ipairs(houses) do if k == ns.house then nextKey = houses[i % #houses + 1] end end
            ns:SetHouse(nextKey)
            return
        end
        MenuUtil.CreateContextMenu(btn, function(_, root)
            root:CreateTitle("Show data for")
            for _, k in ipairs(houses) do
                root:CreateRadio(ns:HouseLabel(k), function() return ns.house == k end, function() ns:SetHouse(k) end)
            end
        end)
    end)
    self.houseBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Auction house")
        GameTooltip:AddLine("Each auction house has its own listings: your faction's cities share one, and the neutral goblin auctioneers (Booty Bay, Gadgetzan, Everlook, Auctioneer Quickcoin at the Crossroads and in Redridge) share another, with a 15% cut.", 1, 1, 1, true)
        GameTooltip:AddLine("Prices, sales, Flip Finder and Crafting use the house shown here. It switches when you open an auction house.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    self.houseBtn:SetScript("OnLeave", GameTooltip_Hide)
    self:UpdateHouseButton()

    -- Schedule of the rotating goblin auctioneer / bank / mail at the trade camps
    local campBtn = Button(f, "Camp schedule", 110, 18)
    campBtn:SetPoint("LEFT", self.houseBtn, "RIGHT", 4, 0)
    campBtn:SetScript("OnClick", function() ns:ShowCamp() end)
    campBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Neutral camp schedule")
        GameTooltip:AddLine("When Auctioneer Quickcoin, the goblin bank and the courier take their turn at the camp west of the Crossroads (and Three Corners in Redridge), from sightings by you and other addon users.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    campBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- In-game manual
    local helpBtn = Button(f, "?", 24, 18)
    helpBtn:SetPoint("RIGHT", self.scopeBtn, "LEFT", -4, 0)
    helpBtn:SetScript("OnClick", function() ns:ShowHelp() end)
    helpBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Manual")
        GameTooltip:AddLine("How every page and command works. Also /aht help.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    helpBtn:SetScript("OnLeave", GameTooltip_Hide)

    local pp = CreateFrame("Frame", nil, f)
    pp:SetAllPoints()
    self.pricesPanel = pp

    -- Left: add box + item list --------------------------------------------
    local left = CreateFrame("Frame", nil, pp)
    left:SetPoint("TOPLEFT", 12, -32)
    left:SetPoint("BOTTOMLEFT", 12, 40)
    left:SetWidth(200)

    local addBox = CreateFrame("EditBox", nil, left, "InputBoxTemplate")
    addBox:SetSize(136, 22)
    addBox:SetPoint("TOPLEFT", 6, -2)
    addBox:SetAutoFocus(false)
    local hint = addBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 2, 0)
    hint:SetText("Item name, link or ID")

    -- Suggestions as you type a name (from the full item catalogue)
    local sugg = CreateFrame("Frame", nil, f, "BackdropTemplate")
    sugg:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", -6, -2)
    sugg:SetWidth(260)
    sugg:SetFrameStrata("DIALOG")
    sugg:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    sugg:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
    sugg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    sugg:Hide()
    sugg.buttons = {}
    local function pick(id)
        sugg:Hide()
        addBox:SetText("")
        addBox:ClearFocus()
        ns:AddItem(id)
    end
    for i = 1, 8 do
        local b = CreateFrame("Button", nil, sugg)
        b:SetHeight(18)
        b:SetPoint("TOPLEFT", 3, -3 - (i - 1) * 18)
        b:SetPoint("RIGHT", -3, 0)
        b:SetHighlightTexture(WHITE)
        b:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.12)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 2, 0)
        b.text:SetPoint("RIGHT", -2, 0)
        b.text:SetJustifyH("LEFT")
        b.text:SetWordWrap(false)
        b:SetScript("OnClick", function(btn) if btn.id then pick(btn.id) end end)
        sugg.buttons[i] = b
    end
    local function updateSuggestions()
        local text = addBox:GetText() or ""
        local hits = {}
        if addBox:HasFocus() and not text:find("|H") and not text:match("^%s*%d+%s*$") then
            hits = ns:SearchItems(text, 8)
        end
        for i, b in ipairs(sugg.buttons) do
            local h = hits[i]
            b.id = h and h.id
            if h then
                local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(h.id)
                b.text:SetText((icon and ("|T" .. icon .. ":14:14|t ") or "") .. h.name
                    .. (ns.items[h.id] and " |cff808080(tracked)|r" or ""))
                b:Show()
            else
                b:Hide()
            end
        end
        sugg:SetHeight(6 + #hits * 18)
        sugg:SetShown(#hits > 0)
        sugg.top = hits[1]
    end
    self.addSuggestions = sugg

    local function updateHint() hint:SetShown(addBox:GetText() == "" and not addBox:HasFocus()) end
    addBox:SetScript("OnEditFocusGained", function() updateHint(); updateSuggestions() end)
    addBox:SetScript("OnEditFocusLost", function()
        updateHint()
        C_Timer.After(0.2, function() if not addBox:HasFocus() then sugg:Hide() end end) -- let a click land first
    end)
    addBox:SetScript("OnTextChanged", function() updateHint(); updateSuggestions() end)
    addBox:SetScript("OnEscapePressed", function(self) sugg:Hide(); self:ClearFocus() end)
    addBox:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        -- Enter picks the top suggestion when what you typed isn't an exact item already
        if sugg:IsShown() and sugg.top and not ns.ParseItemID(text) then
            pick(sugg.top.id)
            return
        end
        sugg:Hide()
        ns:AddItem(text)
        self:SetText("")
        self:ClearFocus()
    end)
    addBox:SetScript("OnReceiveDrag", function() ns:AddFromCursor() end)
    addBox:HookScript("OnMouseDown", function() ns:AddFromCursor() end)
    self.addBox = addBox

    local addBtn = Button(left, "Add", 50)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
    addBtn:SetScript("OnClick", function()
        if not ns:AddFromCursor() then
            ns:AddItem(addBox:GetText())
            addBox:SetText("")
            addBox:ClearFocus()
        end
    end)
    addBtn:SetScript("OnReceiveDrag", function() ns:AddFromCursor() end)

    -- Shift-clicking an item while the add box has focus inserts its link.
    local lastLink, lastTime
    local function onInsertLink(link)
        if not link or not addBox:HasFocus() then return end
        if link == lastLink and GetTime() - lastTime < 0.2 then return end
        lastLink, lastTime = link, GetTime()
        addBox:SetText(link)
    end
    if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", onInsertLink) end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", onInsertLink) end

    -- Sort control
    local sortLabel = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sortLabel:SetPoint("TOPLEFT", 4, -34)
    sortLabel:SetText("Sort by")
    self.sortBtn = Button(left, "", 110, 20)
    self.sortBtn:SetPoint("LEFT", sortLabel, "RIGHT", 6, 0)
    self.sortBtn:SetScript("OnClick", function(btn)
        local function choose(k)
            ns.settings.listSort = k
            ns.settings.listAsc = nil -- each sort starts in its natural direction
            ns:RefreshList()
        end
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(btn, function(_, root)
                root:CreateTitle("Sort tracked items by")
                for _, s in ipairs(ns.LIST_SORTS) do
                    root:CreateRadio(s[2], function() return (ns.settings.listSort or "name") == s[1] end,
                        function() choose(s[1]) end)
                end
            end)
        else
            local cur, nextKey = ns.settings.listSort or "name", ns.LIST_SORTS[1][1]
            for i, s in ipairs(ns.LIST_SORTS) do
                if s[1] == cur then nextKey = ns.LIST_SORTS[i % #ns.LIST_SORTS + 1][1] end
            end
            choose(nextKey)
        end
    end)
    self.sortDirBtn = Button(left, "", 38, 20)
    self.sortDirBtn:SetPoint("LEFT", self.sortBtn, "RIGHT", 2, 0)
    self.sortDirBtn:SetScript("OnClick", function()
        ns.settings.listAsc = not ns:ListSortAsc()
        ns:RefreshList()
    end)

    local list = CreateFrame("Frame", nil, left, "BackdropTemplate")
    list:SetPoint("TOPLEFT", 0, -54)
    list:SetPoint("BOTTOMRIGHT", 0, 0)
    list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        ns.scroll = ns.scroll - delta
        ns:RefreshList()
    end)
    self.listEmpty = list:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    self.listEmpty:SetPoint("CENTER")
    self.listEmpty:SetWidth(176)
    self.listEmpty:SetText("No items tracked yet.\n\nShift-click or drag an item into the box above, or type /aht add <item>.")

    self.rows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(194, ROW_H - 2)
        row:SetPoint("TOPLEFT", 3, -3 - (i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.15)
        row:SetHighlightTexture(WHITE)
        row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", 2, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0)
        row.name:SetPoint("RIGHT", -4, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.price:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 0)
        row.change = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.change:SetPoint("BOTTOMRIGHT", -4, 2)
        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                ns:ShowItemMenu(self, self.id)
            else
                ns:Select(self.id)
            end
        end)
        row:SetScript("OnEnter", function(self)
            local e = ns.items[self.id]
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if e and e.link then GameTooltip:SetHyperlink(e.link) else GameTooltip:SetItemByID(self.id) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Left-click: show history   Right-click: menu", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        self.rows[i] = row
    end

    -- Right: header + graph ------------------------------------------------
    local right = CreateFrame("Frame", nil, pp)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 12, 0)
    right:SetPoint("BOTTOMRIGHT", -12, 40)

    local icon = CreateFrame("Button", nil, right)
    icon:SetSize(38, 38)
    icon:SetPoint("TOPLEFT", 0, -2)
    icon.tex = icon:CreateTexture(nil, "ARTWORK")
    icon.tex:SetAllPoints()
    icon:SetScript("OnEnter", function(self)
        local e = ns.selected and ns.items[ns.selected]
        if e and e.link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(e.link)
            GameTooltip:Show()
        end
    end)
    icon:SetScript("OnLeave", GameTooltip_Hide)
    self.hIcon = icon

    self.hName = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.hName:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
    self.hName:SetPoint("RIGHT", right, "RIGHT", -290, 0)
    self.hName:SetJustifyH("LEFT")
    self.hName:SetWordWrap(false)
    self.hStats = right:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.hStats:SetPoint("TOPLEFT", self.hName, "BOTTOMLEFT", 0, -4)
    self.hSub = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.hSub:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -6)

    self.rangeButtons = {}
    for i = #RANGES, 1, -1 do
        local b = Button(right, RANGES[i].label, 38, 20)
        if i == #RANGES then
            b:SetPoint("TOPRIGHT", 0, -2)
        else
            b:SetPoint("RIGHT", self.rangeButtons[i + 1], "LEFT", -2, 0)
        end
        b:SetScript("OnClick", function() ns.range = i; ns.yPan, ns.yZoom = 0, 1; ns:RefreshDetail() end)
        self.rangeButtons[i] = b
    end

    local graph = CreateFrame("Frame", nil, right, "BackdropTemplate")
    graph:SetPoint("TOPLEFT", 0, -64)
    graph:SetPoint("BOTTOMRIGHT", 0, 0)
    graph:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    graph:SetBackdropColor(0, 0, 0, 0.45)
    graph:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    local plot = CreateFrame("Frame", nil, graph)
    plot:SetPoint("TOPLEFT", 70, -26)
    plot:SetPoint("BOTTOMRIGHT", -16, 24)
    plot:EnableMouse(true)
    plot:EnableMouseWheel(true)
    self.plot = plot
    -- Price lines live on a canvas inside a clipping frame, so panning/zooming never spills
    -- them over the axes or into the volume pane.
    local priceClip = CreateFrame("Frame", nil, plot)
    priceClip:SetClipsChildren(true)
    priceClip:SetPoint("TOPLEFT")
    priceClip:SetPoint("BOTTOMRIGHT")
    local priceCanvas = CreateFrame("Frame", nil, priceClip)
    priceCanvas:SetAllPoints(plot)
    self.priceClip, self.priceCanvas = priceClip, priceCanvas
    self.lines, self.vlines, self.dots, self.grid, self.yLabels, self.xLabels = {}, {}, {}, {}, {}, {}
    for i = 0, 4 do
        local g = plot:CreateTexture(nil, "BACKGROUND")
        g:SetColorTexture(1, 1, 1, i == 0 and 0.25 or 0.08)
        g:SetHeight(1)
        self.grid[i] = g
        local yl = graph:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        yl:SetJustifyH("RIGHT")
        self.yLabels[i] = yl
        local xl = graph:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        self.xLabels[i] = xl
    end

    self.graphFrame = graph
    -- Legend: one entry per series, drawn like it appears on the graph. Hover to learn what it means,
    -- click to show or hide it (like the indicator legends on exchange charts).
    self.settings.graph = self.settings.graph or {}
    local gs = self.settings.graph
    for k, v in pairs({ lowest = true, market = true, volume = true, listed = true, ma = false, bands = false, trades = true }) do
        if gs[k] == nil then gs[k] = v end
    end
    self.legendHolder = CreateFrame("Frame", nil, graph)
    self.legendHolder:SetPoint("TOPLEFT", 8, -5)
    self.legendHolder:SetPoint("RIGHT", graph, "RIGHT", -8, 0)
    self.legendHolder:SetHeight(18)
    self.legendItems = {}
    for _, def in ipairs(ns.LEGEND) do
        local b = CreateFrame("Button", nil, self.legendHolder)
        b:SetHeight(16)
        b.def = def
        -- Swatch: a short line, a bar, a square, or a pair of squares
        b.sw = b:CreateTexture(nil, "ARTWORK")
        b.sw2 = b:CreateTexture(nil, "ARTWORK")
        local c = def.color
        if def.shape == "line" then
            b.sw:SetSize(14, 3)
        elseif def.shape == "bar" then
            b.sw:SetSize(6, 11)
        elseif def.shape == "box" then
            b.sw:SetSize(12, 12)
        else -- square(s)
            b.sw:SetSize(8, 8)
        end
        b.sw:SetPoint("LEFT", 2, 0)
        b.sw:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
        if def.color2 then
            b.sw2:SetSize(8, 8)
            b.sw2:SetPoint("LEFT", b.sw, "RIGHT", 2, 0)
            b.sw2:SetColorTexture(def.color2[1], def.color2[2], def.color2[3], 1)
        else
            b.sw2:Hide()
        end
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", def.color2 and b.sw2 or b.sw, "RIGHT", 4, 0)
        b.text:SetText(def.label)
        b:SetWidth((def.color2 and 30 or (def.shape == "line" and 20 or 16)) + b.text:GetStringWidth() + 4)
        b:SetHighlightTexture(WHITE)
        b:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
        b:SetScript("OnClick", function(btn)
            if not btn.def.key then return end
            gs[btn.def.key] = not gs[btn.def.key]
            ns:DrawGraph()
            btn:GetScript("OnEnter")(btn)
        end)
        b:SetScript("OnEnter", function(btn)
            local d = btn.def
            GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
            GameTooltip:AddLine(d.title or d.label, c[1], c[2], c[3])
            GameTooltip:AddLine(d.help, 1, 1, 1, true)
            if d.read then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(d.read, 0.8, 0.8, 0.8, true)
            end
            if d.key then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(gs[d.key] and "Shown. Click to hide." or "Hidden. Click to show.", 0.5, 0.5, 0.5)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        self.legendItems[#self.legendItems + 1] = b
    end

    -- Volume pane: tinted background, title, divider you can drag to resize it
    self.volBg = plot:CreateTexture(nil, "BACKGROUND", nil, -2)
    self.volBg:SetColorTexture(0.2, 0.8, 0.7, 0.06)
    self.volSep = plot:CreateTexture(nil, "BORDER")
    self.volSep:SetColorTexture(1, 1, 1, 0.3)
    self.volSep:SetHeight(1)
    self.volTitle = plot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.volTitle:SetTextColor(0.35, 0.85, 0.75)
    self.volLabel = graph:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.volLabel:SetJustifyH("RIGHT")
    self.bars, self.gaps = {}, {}
    self.volTickLabels, self.volTickLines = {}, {}

    local handle = CreateFrame("Frame", nil, plot)
    handle:SetHeight(8)
    handle:EnableMouse(true)
    handle:SetFrameLevel(plot:GetFrameLevel() + 6)
    handle.grip = handle:CreateTexture(nil, "OVERLAY")
    handle.grip:SetColorTexture(1, 1, 1, 0.5)
    handle.grip:SetSize(40, 3)
    handle.grip:SetPoint("CENTER")
    handle.grip:Hide()
    handle:SetScript("OnEnter", function(h)
        h.grip:Show()
        GameTooltip:SetOwner(h, "ANCHOR_TOP")
        GameTooltip:AddLine("Drag to resize the volume pane")
        GameTooltip:Show()
    end)
    handle:SetScript("OnLeave", function(h) if not h.dragging then h.grip:Hide() end; GameTooltip:Hide() end)
    handle:SetScript("OnMouseDown", function(h) h.dragging = true; GameTooltip:Hide() end)
    handle:SetScript("OnMouseUp", function(h) h.dragging = false; if not h:IsMouseOver() then h.grip:Hide() end end)
    handle:SetScript("OnUpdate", function(h)
        if not h.dragging then return end
        local _, cy = GetCursorPosition()
        local rel = cy / plot:GetEffectiveScale() - plot:GetBottom()
        local frac = math.max(0.08, math.min(0.6, (rel - 4) / plot:GetHeight()))
        local gs2 = ns.settings.graph
        if math.abs((gs2.volFrac or 0.24) - frac) > 0.004 then
            gs2.volFrac = frac
            ns:DrawGraph()
        end
    end)
    self.volHandle = handle

    self.graphEmpty = graph:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.graphEmpty:SetPoint("CENTER")
    self.graphEmpty:SetWidth(420)

    self.cursorLine = plot:CreateTexture(nil, "OVERLAY")
    self.cursorLine:SetColorTexture(1, 1, 1, 0.35)
    self.cursorLine:SetWidth(1)
    self.cursorLine:Hide()

    -- View: drag to pan the price scale, mouse wheel to zoom it, double-click or Reset view to restore.
    self.resetViewBtn = Button(graph, "Reset view", 80, 18)
    self.resetViewBtn:SetPoint("TOPRIGHT", plot, "TOPRIGHT", -2, -2)
    self.resetViewBtn:SetFrameLevel(plot:GetFrameLevel() + 8)
    self.resetViewBtn:SetScript("OnClick", function() ns:ResetGraphView() end)
    self.resetViewBtn:Hide()

    plot:SetScript("OnSizeChanged", function() ns:DrawGraph() end)
    plot:SetScript("OnEnter", function(self) self.hovering = true end)
    plot:SetScript("OnLeave", function(self)
        self.hovering = false
        self.hoverIndex = nil
        ns.cursorLine:Hide()
        GameTooltip:Hide()
    end)
    plot:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local now = GetTime()
        if self.lastDown and now - self.lastDown < 0.3 then
            self.lastDown = nil
            ns:ResetGraphView()
            return
        end
        self.lastDown = now
        local _, cy = GetCursorPosition()
        self.pan = { y = cy / self:GetEffectiveScale(), start = ns.yPan or 0 }
    end)
    plot:SetScript("OnMouseUp", function(self) self.pan = nil end)
    plot:SetScript("OnMouseWheel", function(_, delta)
        ns.yZoom = math.max(0.2, math.min(50, (ns.yZoom or 1) * (1.2 ^ delta)))
        ns:DrawGraph()
    end)
    plot:SetScript("OnUpdate", function(self)
        if self.pan then
            if not IsMouseButtonDown("LeftButton") then self.pan = nil; return end
            local _, cy = GetCursorPosition()
            local dy = cy / self:GetEffectiveScale() - self.pan.y
            local ph = math.max(1, ns.viewPH or self:GetHeight())
            local pan = self.pan.start - dy / ph / (ns.yZoom or 1)
            if math.abs(pan - (ns.yPan or 0)) > 0.002 then
                ns.yPan = pan
                GameTooltip:Hide()
                ns.cursorLine:Hide()
                ns:DrawGraph()
            end
        elseif self.hovering then
            ns:UpdateHover()
        end
    end)

    -- Footer --------------------------------------------------------------
    self.status = pp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    self.status:SetPoint("RIGHT", f, "RIGHT", -330, 0)
    self.status:SetJustifyH("LEFT")
    self.status:SetWordWrap(false)

    local exportBtn = Button(pp, "Export CSV", 96)
    exportBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 10)
    exportBtn:SetScript("OnClick", function() ns:ShowExport(ns:BuildCSV(ns.selected)) end)
    local scanBtn = Button(pp, "Scan Now", 96)
    scanBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
    scanBtn:SetScript("OnClick", function() ns:ScanNow() end)
    scanBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:AddLine("Scan Now")
        GameTooltip:AddLine("Searches the Auction House for every tracked item right away.", 1, 1, 1, true)
        if ns.ahOpen then
            GameTooltip:AddLine("Auction House is open.", 0.25, 1, 0.35)
        else
            GameTooltip:AddLine("You need to have the Auction House open (talk to an auctioneer) for this to work.", 1, 0.3, 0.3, true)
        end
        GameTooltip:Show()
    end)
    scanBtn:SetScript("OnLeave", GameTooltip_Hide)
    self.autoBtn = Button(pp, "", 116)
    self.autoBtn:SetPoint("RIGHT", scanBtn, "LEFT", -4, 0)
    self.autoBtn:SetScript("OnClick", function()
        ns.settings.autoScan = not ns.settings.autoScan
        ns:UpdateStatus()
    end)

    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then
            elapsed = 0
            ns:UpdateStatus()
            ns:RefreshSubline()
        end
    end)
    f:SetScript("OnShow", function() ns:RefreshAll() end)

    -- Tabs below the window --------------------------------------------------
    if self.CreateHistoryUI then self:CreateHistoryUI(f) end
    if self.CreateFlipUI then self:CreateFlipUI(f) end
    if self.CreateMarketUI then self:CreateMarketUI(f) end
    if self.CreateAuctionsUI then self:CreateAuctionsUI(f) end
    if self.CreateProfitUI then self:CreateProfitUI(f) end
    if self.CreateCraftingUI then self:CreateCraftingUI(f) end
    self.tabs = {}
    local tabDefs = {
        { key = "prices", label = "Prices" },
        { key = "auctions", label = "My Auctions" },
        { key = "profit", label = "Profit" },
        { key = "history", label = "Trade History" },
        { key = "flips", label = "Flip Finder" },
        { key = "crafting", label = "Crafting" },
        { key = "market", label = "Market Data" },
    }
    for i, def in ipairs(tabDefs) do
        local b = Button(f, def.label, 116, 24)
        if i == 1 then
            b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2)
        else
            b:SetPoint("LEFT", self.tabs[i - 1], "RIGHT", 4, 0)
        end
        b:SetScript("OnClick", function() ns:ShowTab(def.key) end)
        b.key = def.key
        self.tabs[i] = b
    end
    self:ShowTab(self.tab or "prices")
end

function ns:ShowTab(key)
    self.tab = key
    self.pricesPanel:SetShown(key == "prices")
    if self.historyPanel then self.historyPanel:SetShown(key == "history") end
    if self.flipsPanel then self.flipsPanel:SetShown(key == "flips") end
    if self.marketPanel then self.marketPanel:SetShown(key == "market") end
    if self.auctionsPanel then self.auctionsPanel:SetShown(key == "auctions") end
    if self.profitPanel then self.profitPanel:SetShown(key == "profit") end
    if self.craftPanel then self.craftPanel:SetShown(key == "crafting") end
    if key == "profit" and self.RefreshProfit then self:RefreshProfit() end
    if key == "crafting" and self.RefreshCrafting then self:RefreshCrafting() end
    if key == "auctions" and self.RefreshAuctions then self:RefreshAuctions() end
    for _, b in ipairs(self.tabs or {}) do
        if b.key == key then b:LockHighlight() else b:UnlockHighlight() end
    end
    if key == "history" and self.RefreshHistory then self:RefreshHistory() end
    if key == "flips" and self.RefreshFlips then self:RefreshFlips() end
    if key == "market" and self.RefreshMarket then self:RefreshMarket() end
end

function ns:UpdateSourceButton()
    if not self.sourceBtn then return end
    for _, s in ipairs(self.PRICE_SOURCES) do
        if s[1] == self:PriceSource() then self.sourceBtn:SetText("Price data: " .. s[2]) end
    end
end

function ns:UpdateHouseButton()
    if not self.houseBtn then return end
    self.houseBtn:SetText("AH: " .. self:HouseLabel(nil, true))
end

function ns:UpdateScopeButton()
    if not self.scopeBtn then return end
    local labels = { char = "Chars: This one", realm = "Chars: This realm", account = "Chars: Whole account" }
    self.scopeBtn:SetText(labels[self:Scope()] or "Chars")
end

function ns:SetPriceSource(key)
    self.settings.priceSource = (key ~= "mix") and key or nil
    self.mktCache = nil
    self:UpdateSourceButton()
    self:RefreshAll()
end

---------------------------------------------------------------------------
-- Right-click item menu (used on every page)
---------------------------------------------------------------------------
function ns:SearchAH(id)
    local name = (C_Item and C_Item.GetItemInfo or GetItemInfo)(id) or (self.MarketName and self:MarketName(id))
    local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
    if not (self.ahOpen and bar and name) then
        self.Print("Open the Auction House to search for it.")
        return
    end
    if AuctionHouseFrame.SetDisplayMode and AuctionHouseFrameDisplayMode then
        pcall(AuctionHouseFrame.SetDisplayMode, AuctionHouseFrame, AuctionHouseFrameDisplayMode.Buy)
    end
    pcall(function()
        bar:SetSearchText(name)
        bar:StartSearch()
    end)
end

function ns:LinkInChat(id)
    local _, link = (C_Item and C_Item.GetItemInfo or GetItemInfo)(id)
    if not link then self.Print("Item not loaded yet. Try again in a moment."); return end
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    if not (insert and insert(link)) and ChatFrame_OpenChat then ChatFrame_OpenChat(link) end
end

-- extras: { { "Label", func }, ... } page-specific actions shown under a divider.
function ns:ShowItemMenu(owner, id, extras)
    if not id then return end
    local tracked = self.items[id] ~= nil
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- No modern menu: right-click just toggles tracking.
        if tracked then self:Select(id); self:ShowTab("prices") else self:AddItem(id) end
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local name = (C_Item and C_Item.GetItemInfo or GetItemInfo)(id)
            or (self.MarketName and self:MarketName(id)) or ("Item " .. id)
        root:CreateTitle(name)
        if tracked then
            root:CreateButton("Show price history", function() self:Select(id); self:ShowTab("prices") end)
            root:CreateButton("Stop tracking", function()
                StaticPopup_Show("AHPT_REMOVE", name, nil, id)
            end)
        else
            root:CreateButton("Track price", function() self:AddItem(id) end)
            root:CreateButton("Track and show history", function()
                self:AddItem(id)
                self:Select(id)
                self:ShowTab("prices")
            end)
        end
        root:CreateCheckbox("Fast watch (scan every minute)", function() return self:IsFastWatched(id) end,
            function() self:ToggleFastWatch(id) end)
        local search = root:CreateButton("Search on the Auction House", function() self:SearchAH(id) end)
        if not self.ahOpen and search.SetEnabled then search:SetEnabled(false) end
        root:CreateButton("Link in chat", function() self:LinkInChat(id) end)
        if extras and #extras > 0 then
            root:CreateDivider()
            for _, x in ipairs(extras) do root:CreateButton(x[1], x[2]) end
        end
    end)
end

function ns:ToggleUI()
    if not self.items then return end
    self:CreateUI()
    self.frame:SetShown(not self.frame:IsShown())
end

function ns:AttachToAuctionHouse()
    if self.ahButton or not AuctionHouseFrame then return end
    local b = Button(AuctionHouseFrame, "Price Tracker", 110)
    b:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, -30)
    b:SetScript("OnClick", function() ns:ToggleUI() end)
    self.ahButton = b
end

---------------------------------------------------------------------------
-- Refreshing
---------------------------------------------------------------------------
function ns:ResetGraphView()
    self.yPan, self.yZoom = 0, 1
    self:DrawGraph()
end

function ns:Select(id)
    if id ~= self.selected then self.yPan, self.yZoom = 0, 1 end
    self.selected = id
    if self.frame and self.frame:IsShown() then
        self:RefreshList()
        self:RefreshDetail()
    end
end

-- Data changes can arrive in bursts (scan results loading, shared scans, item info). Batch them so
-- the window redraws at most a few times a second instead of once per event.
function ns:OnDataUpdated(id)
    if not (self.frame and self.frame:IsShown()) then return end
    self.dirtyIDs = self.dirtyIDs or {}
    if id then self.dirtyIDs[id] = true else self.dirtyAll = true end
    if self.dataTimer then return end
    self.dataTimer = C_Timer.NewTimer(0.25, function()
        ns.dataTimer = nil
        if not (ns.frame and ns.frame:IsShown()) then wipe(ns.dirtyIDs); ns.dirtyAll = nil; return end
        ns:RefreshList()
        local sel = ns.selected
        if ns.dirtyAll or not sel or ns.dirtyIDs[sel] or not ns.items[sel] then ns:RefreshDetail() end
        wipe(ns.dirtyIDs)
        ns.dirtyAll = nil
        ns:UpdateStatus()
    end)
end

function ns:RefreshAll()
    self:RefreshList()
    self:RefreshDetail()
    self:UpdateStatus()
    if self.tab == "history" and self.RefreshHistory then self:RefreshHistory() end
    if self.tab == "flips" and self.RefreshFlips then self:RefreshFlips() end
    if self.tab == "market" and self.RefreshMarket then self:RefreshMarket() end
    if self.tab == "auctions" and self.RefreshAuctions then self:RefreshAuctions() end
    if self.tab == "profit" and self.RefreshProfit then self:RefreshProfit() end
    if self.tab == "crafting" and self.RefreshCrafting then self:RefreshCrafting() end
end

function ns:OnTradesUpdated(rec)
    if not (self.frame and self.frame:IsShown()) then return end
    -- Opening a mailbox can log many sales at once; redraw once afterwards.
    if self.selected and rec and (rec.itemID == self.selected
        or (rec.name and self.items[self.selected] and rec.name == self.items[self.selected].name)) then
        self.tradeGraphDirty = true
    end
    if self.tradeTimer then return end
    self.tradeTimer = C_Timer.NewTimer(0.3, function()
        ns.tradeTimer = nil
        if not (ns.frame and ns.frame:IsShown()) then ns.tradeGraphDirty = nil; return end
        if ns.tab == "history" and ns.RefreshHistory then ns:RefreshHistory() end
        if ns.tab == "profit" and ns.RefreshProfit then ns:RefreshProfit() end
        if ns.tradeGraphDirty then ns:DrawGraph() end
        ns.tradeGraphDirty = nil
    end)
end

function ns:ListSortAsc()
    if self.settings.listAsc ~= nil then return self.settings.listAsc end
    local key = self.settings.listSort or "name"
    for _, s in ipairs(self.LIST_SORTS) do if s[1] == key then return s[4] end end
    return true
end

function ns:RefreshList()
    if not self.frame then return end
    local key = self.settings.listSort or "name"
    for _, s in ipairs(self.LIST_SORTS) do if s[1] == key then self.sortBtn:SetText(s[2]) end end
    self.sortDirBtn:SetText(self:ListSortAsc() and "Asc" or "Desc")
    local ids = SortedIDs()
    if not self.selected or not self.items[self.selected] then self.selected = ids[1] end
    self.scroll = math.max(0, math.min(self.scroll, #ids - NUM_ROWS))
    self.listEmpty:SetShown(#ids == 0)
    for i, row in ipairs(self.rows) do
        local id = ids[i + self.scroll]
        if id then
            local e = self.items[id]
            local p = self:DisplayPrice(id)
            row.id = id
            row.icon:SetTexture(e.icon or 134400)
            row.name:SetText(e.link or e.name or ("Item " .. id))
            row.price:SetText((p and (p.price and self.Money(p.price) or "|cff808080none listed|r") or "|cff808080no price|r")
                .. (self:IsFastWatched(id) and " |cff33ccb3fast|r" or ""))
            row.change:SetText(ChangeText(self:Change(e, 86400)))
            row.sel:SetShown(id == self.selected)
            row:Show()
        else
            row:Hide()
        end
    end
end

function ns:RefreshSubline()
    if not self.frame then return end
    local e = self.selected and self.items[self.selected]
    if not e then self.hSub:SetText(""); return end
    local parts = { self:SalesLong(e.id), "Last scan: " .. self.Ago(e.lastScan) }
    local c24, c7 = self:Change(e, 86400), self:Change(e, 7 * 86400)
    if c24 then parts[#parts + 1] = "24h: " .. ChangeText(c24) end
    if c7 then parts[#parts + 1] = "7d: " .. ChangeText(c7) end
    self.hSub:SetText(table.concat(parts, "   "))
end

function ns:RefreshDetail()
    if not self.frame then return end
    for i, b in ipairs(self.rangeButtons) do
        if i == self.range then b:LockHighlight() else b:UnlockHighlight() end
    end
    local e = self.selected and self.items[self.selected]
    if not e then
        self.hIcon.tex:SetTexture(nil)
        self.hName:SetText("No item selected")
        self.hStats:SetText("")
    else
        local p = self:Latest(e)
        self.hIcon.tex:SetTexture(e.icon or 134400)
        self.hName:SetText(e.link or e.name or ("Item " .. e.id))
        local site = self:PriceSource() == "online" and self:GetSitePrice(e.id)
        if self:PriceSource() == "online" then
            self.hStats:SetText(site and site.t and string.format("auctionhouse.fyi: %s    Listed: %s    Seen %s",
                site.none and "none listed" or self.Money(site.price), site.qty or 0, self.Ago(site.t))
                or "|cff808080auctionhouse.fyi has no price for this item.|r")
        elseif p then
            self.hStats:SetText(string.format("Lowest: %s    Market: %s    Available: %s",
                self.Money(p[2] or nil), self.Money(p[3] or nil), BreakUpLargeNumbers and BreakUpLargeNumbers(p[4] or 0) or (p[4] or 0)))
        else
            self.hStats:SetText("|cff808080Waiting for first scan - open the Auction House.|r")
        end
    end
    self:RefreshSubline()
    self:DrawGraph()
end

function ns:UpdateStatus()
    if not self.frame then return end
    local s = self.settings
    self.autoBtn:SetText(s.autoScan and "Auto-scan: |cff40ff40On|r" or "Auto-scan: |cffff5050Off|r")
    local count = 0
    for _ in pairs(self.items) do count = count + 1 end
    local text
    if self.ahOpen and self.flipQueue and #self.flipQueue > 0 then
        text = string.format("Flip Finder scan: %d item%s left.", #self.flipQueue, #self.flipQueue == 1 and "" or "s")
    elseif count == 0 then
        text = "Add items to start tracking."
    elseif not s.autoScan then
        text = "Auto-scan is off. Use Scan Now while at the Auction House."
    elseif not self.ahOpen then
        text = string.format("Open the Auction House to log prices (each item every %s).", self.Duration(s.interval))
    elseif self.pending then
        local e = self.items[self.pending]
        text = "Scanning " .. (e and (e.name or ("item " .. e.id)) or "...") .. "..."
    elseif s.pauseWhileTrading and self:IsBusyAtAH() then
        text = "Paused while a buy/sell screen is open."
    else
        local _, wait = self:NextDue()
        text = string.format("Logging %d item%s. Next scan in %s.", count, count == 1 and "" or "s",
            self.Duration(math.max(0, wait or 0)))
    end
    self.status:SetText(text)
end

---------------------------------------------------------------------------
-- Graph
---------------------------------------------------------------------------
local function Bucket(pts, tMin, tMax, maxB)
    local buckets, span = {}, tMax - tMin
    for _, p in ipairs(pts) do
        local b = math.min(maxB, math.floor((p[1] - tMin) / span * maxB) + 1)
        local B = buckets[b]
        if not B then
            B = { tsum = 0, n = 0, msum = 0, mn = 0 }
            buckets[b] = B
        end
        B.tsum, B.n, B.qty = B.tsum + p[1], B.n + 1, p[4]
        if p[2] then B.min = B.min and math.min(B.min, p[2]) or p[2] end
        if p[3] then B.msum, B.mn = B.msum + p[3], B.mn + 1 end
    end
    local out = {}
    for b = 1, maxB do
        local B = buckets[b]
        if B then
            out[#out + 1] = { math.floor(B.tsum / B.n), B.min or false,
                B.mn > 0 and math.floor(B.msum / B.mn + 0.5) or false, B.qty, B.n }
        end
    end
    return out
end

local COLOR_MA   = { 0.78, 0.5, 1 }     -- moving average
local COLOR_BAND = { 0.6, 0.6, 0.75 }   -- Bollinger bands
local COLOR_LIST = { 1, 0.55, 0.15 }    -- listed quantity (supply)
local COLOR_SITE = { 0.55, 0.9, 0.45 }  -- auctionhouse.fyi daily close

-- Rounds a count up to a clean axis maximum: 1, 2, 5, 10, 20, 50, 100 ...
local function NiceCeil(n)
    if not n or n <= 1 then return 1 end
    local mag = 10 ^ math.floor(math.log10(n))
    for _, m in ipairs({ 1, 2, 5, 10 }) do
        if m * mag >= n then return m * mag end
    end
    return 10 * mag
end

-- Time-window moving average and standard deviation of the lowest buyout, per point.
local function Indicators(pts, window)
    local out = {}
    local j = 1
    local sum, sq, n = 0, 0, 0
    for i, p in ipairs(pts) do
        if p[2] then sum, sq, n = sum + p[2], sq + p[2] * p[2], n + 1 end
        while pts[j][1] <= p[1] - window do
            local v = pts[j][2]
            if v then sum, sq, n = sum - v, sq - v * v, n - 1 end
            j = j + 1
        end
        if n > 0 then
            local mean = sum / n
            local var = math.max(0, sq / n - mean * mean)
            out[i] = { mean, math.sqrt(var), n }
        end
    end
    return out
end

-- Lays out the legend entries that apply right now, wrapping to a second row if needed,
-- and moves the chart down to make room. Returns nothing.
function ns:LayoutLegend()
    if not self.legendItems then return end
    local gs = self.settings.graph
    local mode = self:PriceSource()
    local width = self.legendHolder:GetWidth()
    if not width or width < 50 then width = 560 end
    local x, row = 0, 0
    for _, b in ipairs(self.legendItems) do
        local d = b.def
        if d.show(mode, gs) then
            local w = b:GetWidth()
            if x > 0 and x + w > width then x, row = 0, row + 1 end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self.legendHolder, "TOPLEFT", x, -row * 18)
            b:SetAlpha((not d.key or gs[d.key]) and 1 or 0.35)
            b:Show()
            x = x + w + 10
        else
            b:Hide()
        end
    end
    local top = 26 + row * 18
    if self.legendTop ~= top then
        self.legendTop = top
        self.plot:ClearAllPoints()
        self.plot:SetPoint("TOPLEFT", self.graphFrame, "TOPLEFT", 70, -top)
        self.plot:SetPoint("BOTTOMRIGHT", self.graphFrame, "BOTTOMRIGHT", -16, 24)
    end
end

function ns:DrawGraph()
    if not self.plot then return end
    local plot = self.plot
    local W, H = plot:GetWidth(), plot:GetHeight()
    local gs = self.settings.graph or {}
    local nLines, nVLines, nDots, nMarks, nBars, nGaps = 0, 0, 0, 0, 0, 0
    local canvas = self.priceCanvas
    self.plotted = {}
    self.marks = self.marks or {}
    self.volInfo = nil
    self.cursorLine:Hide()

    self:LayoutLegend()
    W, H = plot:GetWidth(), plot:GetHeight() -- the legend may have moved the chart down

    local function finish(emptyText)
        for i = nLines + 1, #self.lines do self.lines[i]:Hide() end
        for i = nVLines + 1, #self.vlines do self.vlines[i]:Hide() end
        for i = nDots + 1, #self.dots do self.dots[i]:Hide() end
        for i = nMarks + 1, #self.marks do self.marks[i]:Hide() end
        for i = nBars + 1, #self.bars do self.bars[i]:Hide() end
        for i = nGaps + 1, #self.gaps do self.gaps[i]:Hide() end
        local showAxes = not emptyText
        for i = 0, 4 do
            self.grid[i]:SetShown(showAxes)
            self.yLabels[i]:SetShown(showAxes)
            self.xLabels[i]:SetShown(showAxes)
        end
        if emptyText then
            self.volSep:Hide(); self.volLabel:Hide(); self.volBg:Hide(); self.volTitle:Hide(); self.volHandle:Hide()
            for _, t in ipairs(self.volTickLabels) do t:Hide() end
            for _, t in ipairs(self.volTickLines) do t:Hide() end
            self.resetViewBtn:Hide()
        end
        self.graphEmpty:SetText(emptyText or "")
        self.graphEmpty:SetShown(emptyText ~= nil)
    end

    if W < 10 or H < 10 then return finish("") end
    local e = self.selected and self.items[self.selected]
    if not e then return finish("Select an item on the left.") end
    -- Price data setting: game scans (local history), online (auctionhouse.fyi daily closes), or both.
    local mode = self:PriceSource()
    local useLocal, useOnline = mode ~= "online", mode ~= "local"
    local site = useOnline and self:GetSitePrice(e.id)
    local siteAll = {}
    for _, d in ipairs(site and site.days or {}) do
        if d.close then siteAll[#siteAll + 1] = { d.day * 86400 + 43200, d.close, d.qty } end
    end
    local pending = self.unitPending and self.unitPending[e.id]
    local history = (useLocal and not pending) and e.history or {}
    if #history == 0 and #siteAll == 0 then
        if pending and useLocal then
            return finish("Waiting for a fresh scan to confirm per-unit prices.\n(Older versions saved stack totals for items sold in stacks.)\nOpen the Auction House and this item is rescanned automatically.")
        end
        return finish(useLocal and "No prices logged yet.\nOpen the Auction House and prices will be logged automatically."
            or "auctionhouse.fyi has no daily prices for this item on your auction house.\nSwitch Price data to Game scans or Mixed.")
    end

    local secs = RANGES[self.range].secs
    local now = time()
    local first = math.min(history[1] and history[1][1] or math.huge, siteAll[1] and siteAll[1][1] or math.huge)
    local tMin = secs and (now - secs) or first
    local pts, sitePts = {}, {}
    for _, p in ipairs(history) do
        if p[1] >= tMin then pts[#pts + 1] = p end
    end
    for _, p in ipairs(siteAll) do
        if p[1] >= tMin then sitePts[#sitePts + 1] = p end
    end
    if #pts == 0 and #sitePts == 0 then return finish("No prices in this time range.") end
    local last = math.max(pts[#pts] and pts[#pts][1] or 0, sitePts[#sitePts] and sitePts[#sitePts][1] or 0)
    local tMax = secs and math.max(now, last) or last
    if tMax - tMin < 60 then tMin = tMax - 60 end
    local tSpan = tMax - tMin

    local maxB = math.max(20, math.floor(W / 4))
    if #pts > maxB then pts = Bucket(pts, tMin, tMax, maxB) end

    -- Indicators
    local ind
    if gs.ma or gs.bands then
        ind = Indicators(pts, RANGES[self.range].ma or math.max(3600, tSpan / 10))
    end

    -- Layout: price pane on top, volume pane underneath.
    local showVol = (gs.volume or gs.listed) and useLocal
    local volH = showVol and math.floor(H * (gs.volFrac or 0.24)) or 0
    local priceBase = showVol and (volH + 8) or 0
    local PH = H - priceBase

    local marks = gs.trades and self:GetTradeMarks(e, tMin, tMax) or {}
    local vMin, vMax
    local function extend(v)
        if v then
            vMin = vMin and math.min(vMin, v) or v
            vMax = vMax and math.max(vMax, v) or v
        end
    end
    for _, m in ipairs(marks) do extend(m.unit) end
    for _, p in ipairs(sitePts) do extend(p[2]) end
    for i, p in ipairs(pts) do
        if gs.lowest ~= false or gs.market == false then extend(p[2]) end
        if gs.market ~= false then extend(p[3]) end
        local s = ind and ind[i]
        if s and gs.bands and s[3] > 1 then extend(s[1] + 2 * s[2]); extend(math.max(0, s[1] - 2 * s[2])) end
    end
    if not vMin then return finish("No listings were found for this item in this time range.") end
    if vMax == vMin then
        local pad = math.max(1, vMin * 0.1)
        vMin, vMax = vMin - pad, vMax + pad
    else
        local pad = (vMax - vMin) * 0.08
        vMin, vMax = vMin - pad, vMax + pad
    end
    if vMin < 0 then vMin = 0 end

    -- View: pan (drag) and zoom (mouse wheel) the price scale. Prices can't go below zero.
    local baseSpan = vMax - vMin
    local zoom = self.yZoom or 1
    local center = (vMin + vMax) / 2 + (self.yPan or 0) * baseSpan
    local span = baseSpan / zoom
    vMin, vMax = center - span / 2, center + span / 2
    if vMin < 0 then
        vMax, vMin = vMax - vMin, 0
        self.yPan = ((vMin + vMax) / 2 - (center - (self.yPan or 0) * baseSpan)) / baseSpan
    end
    self.viewPH = PH
    local viewChanged = math.abs(self.yPan or 0) > 0.001 or math.abs(zoom - 1) > 0.001
    self.resetViewBtn:SetShown(viewChanged)
    self.priceClip:ClearAllPoints()
    self.priceClip:SetPoint("TOPLEFT", plot, "TOPLEFT", 0, 0)
    self.priceClip:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, priceBase)

    local vSpan = vMax - vMin
    local function X(t) return (t - tMin) / tSpan * W end
    local function Y(v) return priceBase + (v - vMin) / vSpan * PH end

    -- Axes
    local timeFmt = tSpan <= 2 * 86400 and "%H:%M" or "%m/%d"
    for i = 0, 4 do
        local y = priceBase + PH * i / 4
        local g = self.grid[i]
        g:ClearAllPoints()
        g:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
        g:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y)
        local yl = self.yLabels[i]
        yl:ClearAllPoints()
        yl:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y)
        yl:SetText(self.ShortMoney(vMin + vSpan * i / 4))
        local xl = self.xLabels[i]
        xl:ClearAllPoints()
        xl:SetPoint("TOP", plot, "BOTTOMLEFT", W * i / 4, -6)
        xl:SetText(date(timeFmt, math.floor(tMin + tSpan * i / 4)))
    end

    -- Price lines go on the clipped price canvas; volume-pane lines go on the plot itself.
    local function line(x1, y1, x2, y2, c, thick, alpha, vol)
        local l
        if vol then
            nVLines = nVLines + 1
            l = self.vlines[nVLines]
            if not l then
                l = plot:CreateLine(nil, "ARTWORK")
                self.vlines[nVLines] = l
            end
        else
            nLines = nLines + 1
            l = self.lines[nLines]
            if not l then
                l = canvas:CreateLine(nil, "ARTWORK")
                self.lines[nLines] = l
            end
        end
        l:SetThickness(thick or 2)
        l:SetColorTexture(c[1], c[2], c[3], alpha or 1)
        l:SetStartPoint("BOTTOMLEFT", plot, x1, y1)
        l:SetEndPoint("BOTTOMLEFT", plot, x2, y2)
        l:Show()
    end
    local function dot(x, y, c)
        nDots = nDots + 1
        local d = self.dots[nDots]
        if not d then
            d = canvas:CreateTexture(nil, "OVERLAY")
            d:SetSize(5, 5)
            self.dots[nDots] = d
        end
        d:SetColorTexture(c[1], c[2], c[3], 1)
        d:ClearAllPoints()
        d:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
        d:Show()
    end
    local function box(pool, x, y, w, h, r, g, b, a)
        local t = pool.list[pool.n + 1]
        if not t then
            t = plot:CreateTexture(nil, pool.layer)
            pool.list[pool.n + 1] = t
        end
        pool.n = pool.n + 1
        t:SetColorTexture(r, g, b, a)
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, y)
        t:SetSize(math.max(1, w), math.max(1, h))
        t:Show()
    end

    -- Volume pane -----------------------------------------------------------
    if showVol then
        self.volSep:ClearAllPoints()
        self.volSep:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, volH + 4)
        self.volSep:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, volH + 4)
        self.volSep:Show()
        local NB = math.max(12, math.min(48, math.floor(W / 10)))
        local bw = tSpan / NB
        local sold, watchedSecs = {}, {}
        local events, watched = self:SalesTimeline(e.id, tMin, tMax)
        for _, ev in ipairs(events) do
            local b = math.min(NB, math.max(1, math.floor((ev[1] - tMin) / bw) + 1))
            sold[b] = (sold[b] or 0) + ev[2]
        end
        for _, w in ipairs(watched) do
            for b = 1, NB do
                local s0, s1 = tMin + (b - 1) * bw, tMin + b * bw
                local o = math.min(s1, w[2]) - math.max(s0, w[1])
                if o > 0 then watchedSecs[b] = (watchedSecs[b] or 0) + o end
            end
        end
        local maxSold = 0
        for b = 1, NB do maxSold = math.max(maxSold, sold[b] or 0) end
        local maxListed = 0
        if gs.listed then
            for _, p in ipairs(pts) do maxListed = math.max(maxListed, p[4] or 0) end
        end

        -- Volume axis: units, rounded up to a clean number (1, 2, 5, 10, 20, 50 ...). Bars are drawn
        -- against it so their height reads directly as units sold. The axis follows Sold, or Listed
        -- when Sold is hidden.
        local axisListed = not gs.volume and gs.listed
        local axisMax = NiceCeil(axisListed and maxListed or maxSold)
        local usable = math.max(4, volH - 14) -- headroom at the top for the pane title
        local function VY(units, scaleMax) return units / scaleMax * usable end
        local ticks = (axisMax >= 2 and axisMax % 2 == 0) and { 0, axisMax / 2, axisMax } or { 0, axisMax }
        local tickColor = axisListed and COLOR_LIST or { 0.2, 0.8, 0.7 }
        for i, v in ipairs(ticks) do
            local lab = self.volTickLabels[i]
            if not lab then
                lab = self.graphFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                lab:SetJustifyH("RIGHT")
                self.volTickLabels[i] = lab
            end
            local y = VY(v, axisMax)
            lab:ClearAllPoints()
            lab:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y)
            lab:SetText(BreakUpLargeNumbers and BreakUpLargeNumbers(v) or tostring(v))
            lab:SetTextColor(tickColor[1], tickColor[2], tickColor[3])
            lab:Show()
            local g = self.volTickLines[i]
            if not g then
                g = plot:CreateTexture(nil, "BACKGROUND", nil, -1)
                g:SetHeight(1)
                self.volTickLines[i] = g
            end
            g:SetColorTexture(1, 1, 1, v == 0 and 0.25 or 0.08)
            g:ClearAllPoints()
            g:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
            g:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y)
            g:Show()
        end
        for i = #ticks + 1, #self.volTickLabels do self.volTickLabels[i]:Hide() end
        for i = #ticks + 1, #self.volTickLines do self.volTickLines[i]:Hide() end

        local barPool = { list = self.bars, n = 0, layer = "ARTWORK" }
        local gapPool = { list = self.gaps, n = 0, layer = "BACKGROUND" }
        local colW = W / NB
        local barMax = NiceCeil(maxSold)
        for b = 1, NB do
            local x = (b - 1) * colW
            if not watchedSecs[b] then
                box(gapPool, x, 0, colW, volH, 0.5, 0.5, 0.5, 0.12) -- nobody was watching
            elseif gs.volume and (sold[b] or 0) > 0 then
                box(barPool, x + 1, 0, colW - 2, VY(sold[b], barMax), 0.2, 0.8, 0.7, 0.85)
            end
        end
        nBars, nGaps = barPool.n, gapPool.n
        self.volInfo = { tMin = tMin, bw = bw, NB = NB, sold = sold, watched = watchedSecs }

        if gs.listed and maxListed > 0 then
            local listMax = axisListed and axisMax or NiceCeil(maxListed)
            local px, py
            for _, p in ipairs(pts) do
                local x, y = X(p[1]), VY(p[4] or 0, listMax)
                if px then line(px, py, x, y, COLOR_LIST, 1.5, 0.9, true) end
                px, py = x, y
            end
        end
        self.volLabel:Hide()

        -- Make the pane read as volume: tinted background, title, resize handle on the divider.
        self.volBg:ClearAllPoints()
        self.volBg:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, 0)
        self.volBg:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, volH + 4)
        self.volBg:Show()
        local title = {}
        if gs.volume then title[#title + 1] = "VOLUME" end
        if gs.listed then
            if axisListed then
                title[#title + 1] = "|cffff8c26LISTED|r"
            elseif maxListed > 0 then
                title[#title + 1] = string.format("|cffff8c26LISTED (own scale, top = %s)|r",
                    BreakUpLargeNumbers and BreakUpLargeNumbers(NiceCeil(maxListed)) or NiceCeil(maxListed))
            end
        end
        self.volTitle:SetText(table.concat(title, "   "))
        self.volTitle:ClearAllPoints()
        self.volTitle:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 4, volH + 2)
        self.volTitle:Show()
        self.volHandle:ClearAllPoints()
        self.volHandle:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, volH + 4)
        self.volHandle:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, volH + 4)
        self.volHandle:Show()
    else
        self.volSep:Hide()
        self.volLabel:Hide()
        self.volBg:Hide()
        self.volTitle:Hide()
        self.volHandle:Hide()
        for _, t in ipairs(self.volTickLabels) do t:Hide() end
        for _, t in ipairs(self.volTickLines) do t:Hide() end
    end

    -- Price lines -------------------------------------------------------------
    if ind then
        local prev
        for i, p in ipairs(pts) do
            local s = ind[i]
            if s then
                local x = X(p[1])
                local cur = { x, Y(s[1]), Y(s[1] + 2 * s[2]), Y(math.max(vMin, s[1] - 2 * s[2])) }
                if prev then
                    if gs.bands and s[3] > 1 then
                        line(prev[1], prev[3], x, cur[3], COLOR_BAND, 1, 0.8)
                        line(prev[1], prev[4], x, cur[4], COLOR_BAND, 1, 0.8)
                    end
                    if gs.ma then line(prev[1], prev[2], x, cur[2], COLOR_MA, 1.5, 1) end
                end
                prev = cur
            end
        end
    end

    local showDots = #pts <= 60
    local series = {}
    if gs.market ~= false then series[#series + 1] = { 3, COLOR_MKT } end
    if gs.lowest ~= false then series[#series + 1] = { 2, COLOR_MIN } end
    for _, spec in ipairs(series) do
        local k, c = spec[1], spec[2]
        local px, py
        for _, p in ipairs(pts) do
            local v = p[k]
            if v then
                local x, y = X(p[1]), Y(v)
                if px then line(px, py, x, y, c) end
                if showDots then dot(x, y, c) end
                px, py = x, y
            else
                px = nil
            end
        end
    end

    for i, p in ipairs(pts) do
        self.plotted[#self.plotted + 1] = { x = X(p[1]), p = p, ind = ind and ind[i] }
    end

    -- auctionhouse.fyi daily closes (Online / Mixed)
    do
        local px, py
        for _, p in ipairs(sitePts) do
            local x, y = X(p[1]), Y(p[2])
            if px then line(px, py, x, y, COLOR_SITE, 1.5, 0.85) end
            dot(x, y, COLOR_SITE)
            px, py = x, y
            self.plotted[#self.plotted + 1] = { x = x, site = p }
        end
    end

    -- Your own buys (green) and sells (red) for this item.
    for _, m in ipairs(marks) do
        nMarks = nMarks + 1
        local b = self.marks[nMarks]
        if not b then
            b = CreateFrame("Button", nil, canvas)
            b:SetSize(10, 10)
            b:SetFrameLevel(plot:GetFrameLevel() + 5)
            b.tex = b:CreateTexture(nil, "OVERLAY")
            b.tex:SetAllPoints()
            b:SetScript("OnEnter", function(btn)
                plot.hovering = false
                ns.cursorLine:Hide()
                local r = btn.rec
                GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
                GameTooltip:AddLine((r.type == "ahsell" and "You sold" or "You bought") .. " - " .. date("%b %d %H:%M", r.t), 1, 1, 1)
                GameTooltip:AddDoubleLine("Quantity", tostring(r.qty or 1), 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:AddDoubleLine("Per unit", ns.Money(btn.unit), 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:AddDoubleLine("Total", ns.Money(r.total or r.net), 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide(); plot.hovering = plot:IsMouseOver() end)
            self.marks[nMarks] = b
        end
        b.rec, b.unit = m.rec, m.unit
        if m.rec.type == "ahsell" then b.tex:SetColorTexture(1, 0.25, 0.25, 1) else b.tex:SetColorTexture(0.25, 1, 0.35, 1) end
        b:ClearAllPoints()
        b:SetPoint("CENTER", plot, "BOTTOMLEFT", X(m.t), Y(m.unit))
        b:Show()
    end
    finish(nil)
end

-- Your AH buys/sells for an item inside a time window, as { t, unit, rec }.
function ns:GetTradeMarks(e, tMin, tMax)
    local marks = {}
    for _, r in ipairs(self.trades or {}) do
        if (r.type == "ahbuy" or r.type == "ahwon" or r.type == "ahsell") and r.t >= tMin and r.t <= tMax
            and (r.itemID == e.id or (r.name and r.name == e.name)) then
            local amount = r.total or r.net
            if amount and amount > 0 then
                marks[#marks + 1] = { t = r.t, unit = amount / math.max(1, r.qty or 1), rec = r }
            end
        end
    end
    return marks
end

function ns:UpdateHover()
    local plot = self.plot
    if not self.plotted or #self.plotted == 0 then return end
    local cx = GetCursorPosition() / plot:GetEffectiveScale() - plot:GetLeft()
    local best, bestD
    for i, pt in ipairs(self.plotted) do
        local d = math.abs(pt.x - cx)
        if not bestD or d < bestD then best, bestD = i, d end
    end
    if best == plot.hoverIndex then return end
    plot.hoverIndex = best
    local pt = self.plotted[best]
    local p = pt.p
    local gs = self.settings.graph or {}
    self.cursorLine:ClearAllPoints()
    self.cursorLine:SetPoint("TOPLEFT", plot, "TOPLEFT", pt.x, 0)
    self.cursorLine:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", pt.x, 0)
    self.cursorLine:Show()

    GameTooltip:SetOwner(plot, "ANCHOR_CURSOR")
    if pt.site then
        GameTooltip:AddLine(date("%a %b %d %Y", pt.site[1]), 1, 1, 1)
        GameTooltip:AddDoubleLine("auctionhouse.fyi daily close", self.Money(pt.site[2]), COLOR_SITE[1], COLOR_SITE[2], COLOR_SITE[3], 1, 1, 1)
        GameTooltip:AddDoubleLine("Listed", tostring(pt.site[3] or 0), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:Show()
        return
    end
    GameTooltip:AddLine(date("%a %b %d %Y, %H:%M", p[1]), 1, 1, 1)
    if p[5] and p[5] > 1 then
        GameTooltip:AddLine(string.format("(%d scans combined)", p[5]), 0.6, 0.6, 0.6)
    end
    GameTooltip:AddDoubleLine("Lowest buyout", self.Money(p[2] or nil), COLOR_MIN[1], COLOR_MIN[2], COLOR_MIN[3], 1, 1, 1)
    GameTooltip:AddDoubleLine("Market (cheapest 15%)", self.Money(p[3] or nil), COLOR_MKT[1], COLOR_MKT[2], COLOR_MKT[3], 1, 1, 1)
    local s = pt.ind
    if s and gs.ma then
        GameTooltip:AddDoubleLine("Moving average", self.Money(s[1]), COLOR_MA[1], COLOR_MA[2], COLOR_MA[3], 1, 1, 1)
    end
    if s and gs.bands and s[3] > 1 then
        GameTooltip:AddDoubleLine("Bands", self.Money(math.max(0, s[1] - 2 * s[2])) .. " - " .. self.Money(s[1] + 2 * s[2]),
            COLOR_BAND[1], COLOR_BAND[2], COLOR_BAND[3], 1, 1, 1)
        if p[2] and s[2] > 0 then
            local z = (p[2] - s[1]) / s[2]
            local where = z >= 1.5 and "|cffff5050expensive|r" or z <= -1.5 and "|cff40ff40cheap|r" or "normal"
            GameTooltip:AddDoubleLine("Price vs recent range", where, 0.8, 0.8, 0.8, 1, 1, 1)
        end
    end
    GameTooltip:AddDoubleLine("Listed", tostring(p[4] or 0), COLOR_LIST[1], COLOR_LIST[2], COLOR_LIST[3], 1, 1, 1)
    local v = self.volInfo
    if v and gs.volume then
        local b = math.min(v.NB, math.max(1, math.floor((p[1] - v.tMin) / v.bw) + 1))
        local from = v.tMin + (b - 1) * v.bw
        local fmt = v.bw >= 86400 and "%m/%d" or "%H:%M"
        local label = string.format("Sold %s-%s", date(fmt, from), date(fmt, from + v.bw))
        if v.watched[b] then
            GameTooltip:AddDoubleLine(label, "~" .. (v.sold[b] or 0), 0.2, 0.8, 0.7, 1, 1, 1)
        else
            GameTooltip:AddDoubleLine(label, "not watched", 0.2, 0.8, 0.7, 0.6, 0.6, 0.6)
        end
    end
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Export window
---------------------------------------------------------------------------
function ns:ShowExport(text)
    if not self.exportFrame then
        local ef = CreateFrame("Frame", "AHPriceTrackerExport", UIParent, "BasicFrameTemplateWithInset")
        ef:SetSize(640, 420)
        ef:SetPoint("CENTER")
        ef:SetFrameStrata("DIALOG")
        ef:SetMovable(true)
        ef:EnableMouse(true)
        ef:RegisterForDrag("LeftButton")
        ef:SetScript("OnDragStart", ef.StartMoving)
        ef:SetScript("OnDragStop", ef.StopMovingOrSizing)
        tinsert(UISpecialFrames, ef:GetName())
        local title = ef.TitleText or ef:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        if not ef.TitleText then title:SetPoint("TOP", 0, -5) end
        title:SetText("Export CSV - Ctrl+A then Ctrl+C to copy")

        local sf = CreateFrame("ScrollFrame", nil, ef, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 14, -32)
        sf:SetPoint("BOTTOMRIGHT", -34, 14)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(580)
        eb:SetScript("OnEscapePressed", function() ef:Hide() end)
        sf:SetScrollChild(eb)
        ef.eb = eb
        self.exportFrame = ef
    end
    local ef = self.exportFrame
    ef.eb:SetText(text)
    ef:Show()
    ef.eb:SetFocus()
    ef.eb:HighlightText()
end
