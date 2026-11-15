-- AH Price Tracker: My Auctions tab
local ADDON, ns = ...

local ROW_H = 20
local NUM_ROWS = 15
local WHITE = "Interface\\Buttons\\WHITE8X8"
local COLUMNS = { -- key, title, width
    { "item", "Item", 196 }, { "qty", "Qty", 40 }, { "unit", "Your price", 80 }, { "lowest", "Lowest now", 80 },
    { "status", "Status", 96 }, { "left", "Time left", 62 }, { "sellsIn", "Sells in", 70 },
    { "net", "Value (after cut)", 104 }, { "projected", "Projected", 88 },
}

ns.aucSort = "net"
ns.aucAsc = false
ns.aucScroll = 0

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

local STATUS_ORDER = { undercut = 1, unknown = 2, lowest = 3, sold = 4 }
local function SortValue(r, key)
    if key == "item" then return r.name:lower() end
    if key == "status" then return STATUS_ORDER[r.status] end
    if key == "unit" then return r.unit end
    return r[key]
end

function ns:CreateAuctionsUI(f)
    local ap = CreateFrame("Frame", nil, f)
    ap:SetAllPoints()
    ap:Hide()
    self.auctionsPanel = ap

    local refresh = Button(ap, "Refresh", 90)
    refresh:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    refresh:SetScript("OnClick", function()
        if ns.ahOpen then ns:QueryOwned() else ns.Print("Open the Auction House to refresh your auctions.") end
    end)
    refresh:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Refresh")
        GameTooltip:AddLine("Reads your current auctions. This happens automatically whenever you open the Auction House or post or cancel an auction.", 1, 1, 1, true)
        if not ns.ahOpen then
            GameTooltip:AddLine("You need to have the Auction House open (talk to an auctioneer) for this to work.", 1, 0.3, 0.3, true)
        end
        GameTooltip:Show()
    end)
    refresh:SetScript("OnLeave", GameTooltip_Hide)

    self.aucAsOf = ap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.aucAsOf:SetPoint("LEFT", refresh, "RIGHT", 10, 0)

    -- Summary cards
    self.aucCards = {}
    local cardDefs = {
        { "units", "On the market" }, { "gross", "Listed value" }, { "net", "After AH cut" },
        { "projected", "Projected earnings" }, { "sold", "Sold, in your mail" },
    }
    local cw = 164
    for i, d in ipairs(cardDefs) do
        local c = CreateFrame("Frame", nil, ap, "BackdropTemplate")
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
        c.value:SetWordWrap(false)
        c:EnableMouse(true)
        c:SetScript("OnEnter", function(card) ns:ShowAuctionCardTooltip(card, d[1]) end)
        c:SetScript("OnLeave", GameTooltip_Hide)
        self.aucCards[d[1]] = c
    end

    local list = CreateFrame("Frame", nil, ap, "BackdropTemplate")
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -108)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        ns.aucScroll = ns.aucScroll - delta * 3
        ns:RefreshAuctions()
    end)

    self.aucHeaders = {}
    local x = 4
    for _, col in ipairs(COLUMNS) do
        local key = col[1]
        local h = CreateFrame("Button", nil, list)
        h:SetSize(col[3] - 4, 18)
        h:SetPoint("TOPLEFT", x, -3)
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.text:SetAllPoints()
        h.text:SetJustifyH(key == "item" and "LEFT" or "RIGHT")
        h.title, h.key = col[2], key
        h:SetHighlightTexture(WHITE)
        h:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)
        h:SetScript("OnClick", function()
            if ns.aucSort == key then ns.aucAsc = not ns.aucAsc else ns.aucSort, ns.aucAsc = key, (key == "item") end
            ns:RefreshAuctions()
        end)
        self.aucHeaders[#self.aucHeaders + 1] = h
        x = x + col[3]
    end
    local sep = list:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.15)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 4, -22)
    sep:SetPoint("TOPRIGHT", -4, -22)

    self.aucEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.aucEmpty:SetPoint("CENTER")
    self.aucEmpty:SetWidth(560)

    self.aucRows = {}
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
            fs:SetJustifyH(col[1] == "item" and "LEFT" or "RIGHT")
            fs:SetWordWrap(false)
            row.cells[col[1]] = fs
            cx = cx + col[3]
        end
        row:SetScript("OnClick", function(btn, button)
            local r = btn.rec
            if not r then return end
            if button == "RightButton" then
                ns:ShowItemMenu(btn, r.id)
            elseif IsModifiedClick("CHATLINK") then
                ns:LinkInChat(r.id)
            end
        end)
        row:SetScript("OnEnter", function(btn) ns:ShowAuctionTooltip(btn, btn.rec) end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        self.aucRows[i] = row
    end

    self.aucFoot = ap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.aucFoot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    self.aucFoot:SetPoint("RIGHT", f, "RIGHT", -18, 0)
    self.aucFoot:SetJustifyH("LEFT")
end

function ns:ShowAuctionCardTooltip(card, key)
    GameTooltip:SetOwner(card, "ANCHOR_BOTTOMRIGHT")
    local text = {
        units = "Auctions and units you have listed right now (not counting ones that already sold).",
        gross = "What your active auctions are worth at your listed prices.",
        net = "What you'd receive if every active auction sold, after the AH cut (5%, or 15% at the neutral goblin auction house). Deposits are already paid and aren't refunded on a sale.",
        projected = "Expected earnings before your auctions expire: for each listing, how many cheaper units are ahead of yours and how fast the item sells. Listings with no sales data yet aren't counted (shown separately).",
        sold = "Auctions that sold and are waiting in your mailbox (after the AH cut). They're logged in Trade History when you open the mail.",
    }
    GameTooltip:AddLine(card.label:GetText())
    GameTooltip:AddLine(text[key], 1, 1, 1, true)
    GameTooltip:Show()
end

function ns:ShowAuctionTooltip(owner, r)
    if not r then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if r.link then GameTooltip:SetHyperlink(r.link) else GameTooltip:SetItemByID(r.id) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Quantity", tostring(r.qty), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Your price per unit", self.Money(r.unit), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Total / after AH cut", self.Money(r.gross) .. " / " .. self.Money(r.net), 0.8, 0.8, 0.8, 1, 1, 1)
    if r.sold then
        GameTooltip:AddLine("Sold. Collect the gold from your mailbox.", 0.25, 1, 0.35, true)
        GameTooltip:Show()
        return
    end
    if r.lowest then
        GameTooltip:AddDoubleLine("Lowest on the AH now", self.Money(r.lowest), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.status == "undercut" then
        GameTooltip:AddLine(string.format("Undercut by %.0f%%. Buyers will take the cheaper units first.", r.undercut * 100), 1, 0.35, 0.35, true)
    end
    if r.left then GameTooltip:AddDoubleLine("Expires in", self.Duration(r.left), 0.8, 0.8, 0.8, 1, 1, 1) end
    GameTooltip:AddLine(" ")
    if r.ahead then
        GameTooltip:AddDoubleLine("Cheaper units ahead of yours", r.ahead .. (r.cutOff and "+" or ""), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.rate then
        GameTooltip:AddDoubleLine("Market buys per day", string.format("~%.1f%s", r.rate, r.early and " (early estimate)" or ""),
            0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.sellsIn then
        GameTooltip:AddDoubleLine("Whole stack sold in about", self.Duration(r.sellsIn), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.willSell then
        GameTooltip:AddDoubleLine("Expected to sell before expiry", string.format("%.0f%%", r.willSell * 100), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Projected earnings", self.Money(r.projected), 0.8, 0.8, 0.8, 1, 1, 1)
    else
        GameTooltip:AddLine("No sales data for this item yet, so no projection. It's scanned automatically while the AH is open.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: track, search the AH, link in chat", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function ns:RefreshAuctions()
    if not (self.auctionsPanel and self.aucRows and self.owned) then return end
    local rows = self:GetAuctionRows()
    local key, asc = self.aucSort, self.aucAsc
    table.sort(rows, function(a, b)
        local va, vb = SortValue(a, key), SortValue(b, key)
        if va == nil or vb == nil or va == vb then
            if (va == nil) ~= (vb == nil) then return vb == nil end
            return a.name < b.name
        end
        if asc then return va < vb end
        return va > vb
    end)
    for _, h in ipairs(self.aucHeaders) do
        h.text:SetText(h.title .. ((h.key == key) and (asc and " ^" or " v") or ""))
    end

    local t = self:AuctionTotals(rows)
    local c = self.aucCards
    c.units.value:SetText(string.format("%d auction%s, %d unit%s", t.listed, t.listed == 1 and "" or "s", t.units, t.units == 1 and "" or "s"))
    c.gross.value:SetText(self.Money(t.gross))
    c.net.value:SetText(self.Money(t.net))
    c.projected.value:SetText(self.Money(t.projected) .. (t.unknown > 0 and " |cff808080+?|r" or ""))
    c.sold.value:SetText(self.Money(t.soldNet))

    if self.owned.t and self.owned.t > 0 then
        self.aucAsOf:SetText((self.ahOpen and "|cff40ff40Live|r - " or "") .. "read from the Auction House " .. self.Ago(self.owned.t))
    else
        self.aucAsOf:SetText("|cffff9900Not read yet. Open the Auction House.|r")
    end

    self.aucScroll = math.max(0, math.min(self.aucScroll, #rows - NUM_ROWS))
    self.aucEmpty:SetShown(#rows == 0)
    if #rows == 0 then
        self.aucEmpty:SetText((self.owned.t or 0) > 0 and "You have no auctions up." or
            "Your auctions haven't been read yet.\n\nOpen the Auction House once and they'll appear here (and stay here after you leave).")
    end

    for i, row in ipairs(self.aucRows) do
        local r = rows[i + self.aucScroll]
        row.rec = r
        if r then
            local cl = row.cells
            local icon = r.icon and ("|T" .. r.icon .. ":14:14|t ") or ""
            local who = r.char and r.houseLabel and (r.char .. ", " .. r.houseLabel) or r.char or r.houseLabel
            cl.item:SetText(icon .. (r.link or r.name) .. (who and (" |cff808080(" .. who .. ")|r") or ""))
            cl.qty:SetText(tostring(r.qty))
            cl.unit:SetText(self.Money(r.unit))
            cl.lowest:SetText(r.sold and "" or (r.lowest and self.Money(r.lowest) or "|cff808080?|r"))
            if r.status == "sold" then
                cl.status:SetText("|cff40ff40Sold - in mail|r")
            elseif r.status == "undercut" then
                cl.status:SetText(string.format("|cffff5050Undercut %.0f%%|r", r.undercut * 100))
            elseif r.status == "lowest" then
                cl.status:SetText("|cff40ff40Lowest price|r")
            else
                cl.status:SetText("|cff808080No price data|r")
            end
            cl.left:SetText(r.left and ((r.left < 2 * 3600 and "|cffff9900" or "") .. self.Duration(r.left) .. (r.left < 2 * 3600 and "|r" or "")) or "")
            if r.sellsIn then
                local late = r.left and r.sellsIn > r.left
                cl.sellsIn:SetText((late and "|cffff9900" or "") .. self.Duration(r.sellsIn) .. (late and "|r" or ""))
            else
                cl.sellsIn:SetText(r.sold and "" or (r.rate == 0 and "|cffff5050no buyers|r" or "|cff808080?|r"))
            end
            cl.net:SetText(self.Money(r.net))
            cl.projected:SetText(r.projected and self.Money(r.projected) or "|cff808080?|r")
            row:Show()
        else
            row:Hide()
        end
    end

    local foot = string.format("%d listing%s.", #rows, #rows == 1 and "" or "s")
    if t.undercut > 0 then foot = foot .. string.format("  |cffff5050%d undercut.|r", t.undercut) end
    if t.unknown > 0 then
        foot = foot .. string.format("  %s of listings have no sales data yet, so they aren't in the projection.", self.Money(t.unknown))
    end
    self.aucFoot:SetText(foot)
end
