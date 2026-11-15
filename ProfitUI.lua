-- AH Price Tracker: Profit tab (realized profit per item over a time window)
local ADDON, ns = ...

local ROW_H = 20
local NUM_ROWS = 14
local WHITE = "Interface\\Buttons\\WHITE8X8"
local COLUMNS = { -- key, title, width
    { "name", "Item", 200 }, { "bought", "Bought", 54 }, { "avgBuy", "Avg cost", 80 }, { "sold", "Sold", 50 },
    { "avgSell", "Avg sale", 80 }, { "revenue", "Revenue", 92 }, { "profit", "Profit", 98 }, { "margin", "Margin", 56 },
    { "held", "Still held", 62 }, { "last", "Last", 74 },
}
local WINDOWS = { { "24h", 86400 }, { "7d", 7 * 86400 }, { "30d", 30 * 86400 }, { "All", nil } }

ns.profitWindow = 2
ns.profitSort = "profit"
ns.profitAsc = false
ns.profitScroll = 0

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

local function Signed(c)
    if not c then return "" end
    c = math.floor(c + 0.5)
    local col = c > 0 and "|cff40ff40+" or (c < 0 and "|cffff5050-" or "")
    return col .. ns.Money(math.abs(c)) .. ((c ~= 0) and "|r" or "")
end

local function SortValue(r, key)
    if key == "name" then return (r.name or ""):lower() end
    return r[key]
end

function ns:CreateProfitUI(f)
    local pp = CreateFrame("Frame", nil, f)
    pp:SetAllPoints()
    pp:Hide()
    self.profitPanel = pp

    self.profitWinButtons = {}
    for i, w in ipairs(WINDOWS) do
        local b = Button(pp, w[1], 48)
        if i == 1 then b:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32) else b:SetPoint("LEFT", self.profitWinButtons[i - 1], "RIGHT", 3, 0) end
        b:SetScript("OnClick", function() ns.profitWindow = i; ns.profitScroll = 0; ns:RefreshProfit() end)
        self.profitWinButtons[i] = b
    end
    local note = pp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -38)
    note:SetText("Sales after the AH cut, minus what you paid (oldest stock first) and lost deposits.")

    -- Summary cards
    self.profitCards = {}
    local defs = {
        { "profit", "Profit" }, { "revenue", "Sales (after cut)" }, { "cogs", "Cost of what sold" },
        { "spent", "Spent buying" }, { "deposits", "Deposits lost" },
    }
    local tips = {
        profit = "Sales after the AH cut, minus what those units cost you and any deposits you lost on auctions that expired or were cancelled.",
        revenue = "What your AH sales brought in after the AH cut.",
        cogs = "What you paid for the units you sold, using your oldest purchases first. Units with no purchase on record (farmed, crafted, looted) count as free.",
        spent = "Everything you bought in this period (AH and vendors), including stock you haven't sold yet.",
        deposits = "Deposits on listings that didn't sell. A sale returns its deposit.",
    }
    local cw = 166
    for i, d in ipairs(defs) do
        local c = CreateFrame("Frame", nil, pp, "BackdropTemplate")
        c:SetSize(cw - 6, 40)
        c:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * cw, -60)
        c:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        c:SetBackdropColor(1, 1, 1, 0.04)
        c:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        c.label = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        c.label:SetPoint("TOPLEFT", 6, -5)
        c.label:SetText(d[2])
        c.value = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        c.value:SetPoint("BOTTOMLEFT", 6, 6)
        c.value:SetPoint("RIGHT", -6, 0)
        c.value:SetJustifyH("LEFT")
        c:EnableMouse(true)
        c:SetScript("OnEnter", function(card)
            GameTooltip:SetOwner(card, "ANCHOR_BOTTOMRIGHT")
            GameTooltip:AddLine(d[2])
            GameTooltip:AddLine(tips[d[1]], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", GameTooltip_Hide)
        self.profitCards[d[1]] = c
    end

    local list = CreateFrame("Frame", nil, pp, "BackdropTemplate")
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -108)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        ns.profitScroll = ns.profitScroll - delta * 3
        ns:RefreshProfit(true)
    end)

    self.profitHeaders = {}
    local x = 4
    for _, col in ipairs(COLUMNS) do
        local key = col[1]
        local h = CreateFrame("Button", nil, list)
        h:SetSize(col[3] - 4, 18)
        h:SetPoint("TOPLEFT", x, -3)
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.text:SetAllPoints()
        h.text:SetJustifyH(key == "name" and "LEFT" or "RIGHT")
        h.title, h.key = col[2], key
        h:SetHighlightTexture(WHITE)
        h:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)
        h:SetScript("OnClick", function()
            if ns.profitSort == key then ns.profitAsc = not ns.profitAsc else ns.profitSort, ns.profitAsc = key, (key == "name") end
            ns:RefreshProfit()
        end)
        self.profitHeaders[#self.profitHeaders + 1] = h
        x = x + col[3]
    end
    local sep = list:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.15)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 4, -22)
    sep:SetPoint("TOPRIGHT", -4, -22)

    self.profitEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.profitEmpty:SetPoint("CENTER")
    self.profitEmpty:SetWidth(600)

    self.profitRows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 4, -24 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", list, "RIGHT", -4, 0)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
            fs:SetJustifyH(col[1] == "name" and "LEFT" or "RIGHT")
            fs:SetWordWrap(false)
            row.cells[col[1]] = fs
            cx = cx + col[3]
        end
        row:SetScript("OnClick", function(btn, button)
            local r = btn.rec
            if r and r.id and button == "RightButton" then ns:ShowItemMenu(btn, r.id) end
        end)
        row:SetScript("OnEnter", function(btn)
            local r = btn.rec
            if not r then return end
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            if r.link then GameTooltip:SetHyperlink(r.link) elseif r.id then GameTooltip:SetItemByID(r.id) else GameTooltip:AddLine(r.name) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Bought", string.format("%d for %s", r.bought, ns.Money(r.spent)), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("Sold", string.format("%d for %s after cut", r.sold, ns.Money(r.revenue)), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("Cost of units sold", ns.Money(r.cogs), 0.8, 0.8, 0.8, 1, 1, 1)
            if r.uncosted > 0 then
                GameTooltip:AddLine(string.format("%d sold with no purchase on record (farmed, crafted or looted), so they count as free.", r.uncosted), 1, 0.82, 0, true)
            end
            GameTooltip:AddDoubleLine("AH cut paid", ns.Money(r.cut), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("Deposits lost", ns.Money(r.depositsLost), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("Profit", Signed(r.profit), 0.8, 0.8, 0.8, 1, 1, 1)
            if r.held > 0 then GameTooltip:AddDoubleLine("Bought but not sold yet", tostring(r.held), 0.8, 0.8, 0.8, 1, 1, 1) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Right-click: track, search the AH, link in chat", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        self.profitRows[i] = row
    end

    self.profitFoot = pp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.profitFoot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    self.profitFoot:SetPoint("RIGHT", f, "RIGHT", -18, 0)
    self.profitFoot:SetJustifyH("LEFT")
end

function ns:RefreshProfit(scrollOnly)
    if not (self.profitPanel and self.profitRows) then return end
    for i, b in ipairs(self.profitWinButtons) do
        if i == self.profitWindow then b:LockHighlight() else b:UnlockHighlight() end
    end
    if not scrollOnly or not self.profitCache then
        local secs = WINDOWS[self.profitWindow][2]
        local rows = self:ProfitRows(secs and (time() - secs) or 0)
        local key, asc = self.profitSort, self.profitAsc
        table.sort(rows, function(a, b)
            local va, vb = SortValue(a, key), SortValue(b, key)
            if va == nil or vb == nil or va == vb then
                if (va == nil) ~= (vb == nil) then return vb == nil end
                return (a.name or "") < (b.name or "")
            end
            if asc then return va < vb end
            return va > vb
        end)
        self.profitCache = rows
    end
    local rows = self.profitCache
    for _, h in ipairs(self.profitHeaders) do
        h.text:SetText(h.title .. ((h.key == self.profitSort) and (self.profitAsc and " ^" or " v") or ""))
    end

    local t = self:ProfitTotals(rows)
    self.profitCards.profit.value:SetText(Signed(t.profit))
    self.profitCards.revenue.value:SetText(self.Money(t.revenue))
    self.profitCards.cogs.value:SetText(self.Money(t.cogs))
    self.profitCards.spent.value:SetText(self.Money(t.spent))
    self.profitCards.deposits.value:SetText(self.Money(t.depositsLost))

    self.profitScroll = math.max(0, math.min(self.profitScroll, #rows - NUM_ROWS))
    self.profitEmpty:SetShown(#rows == 0)
    if #rows == 0 then
        self.profitEmpty:SetText("No buys or sales in this period.\n\nAH buys, vendor buys, listings and AH sales are logged automatically.")
    end
    for i, row in ipairs(self.profitRows) do
        local r = rows[i + self.profitScroll]
        row.rec = r
        if r then
            local c = row.cells
            local icon = r.id and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(r.id)
            c.name:SetText((icon and ("|T" .. icon .. ":14:14|t ") or "") .. (r.link or r.name or "?"))
            c.bought:SetText(r.bought > 0 and tostring(r.bought) or "")
            c.avgBuy:SetText(r.avgBuy and self.Money(r.avgBuy) or "")
            c.sold:SetText(r.sold > 0 and tostring(r.sold) or "")
            c.avgSell:SetText(r.avgSell and self.Money(r.avgSell) or "")
            c.revenue:SetText(r.revenue > 0 and self.Money(r.revenue) or "")
            c.profit:SetText(Signed(r.profit) .. (r.uncosted > 0 and " |cffffd100*|r" or ""))
            c.margin:SetText(r.margin and string.format("%+.0f%%", r.margin * 100) or "")
            c.held:SetText(r.held > 0 and tostring(r.held) or "")
            c.last:SetText(r.last and self.Ago(r.last) or "")
            row:Show()
        else
            row:Hide()
        end
    end
    self.profitFoot:SetText(string.format("%d item%s.%s", #rows, #rows == 1 and "" or "s",
        t.uncosted > 0 and "  |cffffd100*|r = some units sold had no purchase on record, so they count as free." or ""))
end
