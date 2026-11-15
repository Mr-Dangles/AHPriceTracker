-- AH Price Tracker: Trade History tab
local ADDON, ns = ...

local ROW_H = 20
local NUM_ROWS = 17
local WHITE = "Interface\\Buttons\\WHITE8X8"
local FILTERS = {
    { key = "all",    label = "All" },
    { key = "trade",  label = "Trades" },
    { key = "buy",    label = "AH Buys" },
    { key = "ahsell", label = "AH Sales" },
    { key = "listed", label = "Listed" },
    { key = "vendor", label = "Vendor Buys" },
}
local TYPE_COLOR = { trade = "|cffd0a0ff", ahbuy = "|cff40ff59", ahwon = "|cff40ff59", ahsell = "|cffff6060", listed = "|cffffb347", vendorbuy = "|cff59d9cc" }
local COLUMNS = { -- key, title, width
    { "date", "Date", 100 }, { "type", "Type", 86 }, { "item", "Item(s)", 300 },
    { "qty", "Qty", 44 }, { "who", "With", 104 }, { "amount", "Gold", 186 },
}

ns.historyFilter = "all"
ns.historyScroll = 0
ns.historySearch = ""

StaticPopupDialogs["AHPT_DELETE_TRADE"] = {
    text = "Delete this trade history entry?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data) ns:DeleteTrade(data) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

local function Signed(c, positiveIsGain)
    if not c or c == 0 then return "" end
    if c > 0 then
        return (positiveIsGain and "|cff40ff40+|r" or "|cffff5050-|r") .. ns.Money(c)
    end
    return (positiveIsGain and "|cffff5050-|r" or "|cff40ff40+|r") .. ns.Money(-c)
end

-- Money in (+) / out (-) for a record.
local function GoldDelta(r)
    if r.type == "ahsell" then return r.net or r.total or 0 end
    if r.type == "listed" then return -(r.deposit or 0) end -- the deposit is what left your bags
    if r.type == "vendorbuy" then return -(r.total or 0) end
    if r.type == "ahbuy" or r.type == "ahwon" then return -(r.total or 0) end
    return (r.gotMoney or 0) - (r.gaveMoney or 0)
end

local function ItemCell(r)
    if r.type ~= "trade" then return r.link or r.name or "?" end
    local function first(list)
        if not list or #list == 0 then return nil end
        local s = list[1].link .. ((list[1].count or 1) > 1 and (" x" .. list[1].count) or "")
        if #list > 1 then s = s .. string.format(" |cff808080+%d more|r", #list - 1) end
        return s
    end
    local gave, got = first(r.gave), first(r.got)
    if gave and got then return "Gave " .. gave .. "  Got " .. got end
    if got then return "Got " .. got end
    if gave then return "Gave " .. gave end
    return "|cff808080gold only|r"
end

local function Matches(r, filter, search)
    if filter == "trade" and r.type ~= "trade" then return false end
    if filter == "buy" and r.type ~= "ahbuy" and r.type ~= "ahwon" then return false end
    if filter == "vendor" and r.type ~= "vendorbuy" then return false end
    if filter == "ahsell" and r.type ~= "ahsell" then return false end
    if filter == "listed" and r.type ~= "listed" then return false end
    if search == "" then return true end
    local hay = { r.who or "", r.char or "", r.name or "", ns.LinkName(r.link) }
    for _, list in ipairs({ r.gave or {}, r.got or {} }) do
        for _, it in ipairs(list) do hay[#hay + 1] = ns.LinkName(it.link) end
    end
    return table.concat(hay, "\n"):lower():find(search, 1, true) ~= nil
end

function ns:FilteredTrades()
    local out = {}
    local search = (self.historySearch or ""):lower()
    -- Logged trades plus sales seen live but not collected from the mailbox yet, for the chosen characters
    for _, r in ipairs(self:ScopedTrades(true)) do
        if Matches(r, self.historyFilter, search) then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    return out
end

function ns:CreateHistoryUI(f)
    local hp = CreateFrame("Frame", nil, f)
    hp:SetAllPoints()
    hp:Hide()
    self.historyPanel = hp

    -- Filters + search
    self.filterButtons = {}
    for i, def in ipairs(FILTERS) do
        local b = Button(hp, def.label, 84, 22)
        if i == 1 then
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
        else
            b:SetPoint("LEFT", self.filterButtons[i - 1], "RIGHT", 4, 0)
        end
        b:SetScript("OnClick", function()
            ns.historyFilter = def.key
            ns.historyScroll = 0
            ns:RefreshHistory()
        end)
        b.key = def.key
        self.filterButtons[i] = b
    end

    local search = CreateFrame("EditBox", nil, hp, "InputBoxTemplate")
    search:SetSize(200, 22)
    search:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -32)
    search:SetAutoFocus(false)
    local hint = search:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 2, 0)
    hint:SetText("Search item or player")
    search:SetScript("OnTextChanged", function(box)
        hint:SetShown(box:GetText() == "" and not box:HasFocus())
        ns.historySearch = box:GetText()
        ns.historyScroll = 0
        ns:RefreshHistory()
    end)
    search:SetScript("OnEditFocusGained", function() hint:Hide() end)
    search:SetScript("OnEditFocusLost", function(box) hint:SetShown(box:GetText() == "") end)
    search:SetScript("OnEscapePressed", search.ClearFocus)
    search:SetScript("OnEnterPressed", search.ClearFocus)

    self.historySummary = hp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.historySummary:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -62)
    self.historySummary:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    self.historySummary:SetJustifyH("LEFT")

    -- List
    local list = CreateFrame("Frame", nil, hp, "BackdropTemplate")
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -84)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        ns.historyScroll = ns.historyScroll - delta * 3
        ns:RefreshHistory()
    end)

    local x = 6
    for _, col in ipairs(COLUMNS) do
        local h = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", x, -6)
        h:SetWidth(col[3] - 6)
        h:SetJustifyH(col[1] == "amount" and "RIGHT" or "LEFT")
        h:SetText(col[2])
        x = x + col[3]
    end
    local sep = list:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.15)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 4, -22)
    sep:SetPoint("TOPRIGHT", -4, -22)

    self.historyEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.historyEmpty:SetPoint("CENTER")
    self.historyEmpty:SetWidth(520)

    self.historyRows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 4, -24 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", list, "RIGHT", -4, 0)
        row:RegisterForClicks("RightButtonUp")
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
            fs:SetJustifyH(col[1] == "amount" and "RIGHT" or "LEFT")
            fs:SetWordWrap(false)
            row.cells[col[1]] = fs
            cx = cx + col[3]
        end
        row:SetScript("OnClick", function(btn)
            local rec = btn.rec
            if not rec then return end
            local del = { "Delete this entry", function() StaticPopup_Show("AHPT_DELETE_TRADE", nil, nil, rec) end }
            -- Items in this entry: one for AH records, possibly several for a player trade.
            local ids, seen = {}, {}
            local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
            add(rec.itemID)
            for _, it in ipairs(rec.gave or {}) do add(ns.LinkID(it.link)) end
            for _, it in ipairs(rec.got or {}) do add(ns.LinkID(it.link)) end
            if #ids == 1 then
                ns:ShowItemMenu(btn, ids[1], { del })
            elseif #ids > 1 and MenuUtil and MenuUtil.CreateContextMenu then
                MenuUtil.CreateContextMenu(btn, function(_, root)
                    root:CreateTitle("Items in this trade")
                    for _, id in ipairs(ids) do
                        local name = (C_Item and C_Item.GetItemInfo or GetItemInfo)(id) or ("Item " .. id)
                        if ns.items[id] then
                            root:CreateButton("Show " .. name, function() ns:Select(id); ns:ShowTab("prices") end)
                        else
                            root:CreateButton("Track " .. name, function() ns:AddItem(id) end)
                        end
                    end
                    root:CreateDivider()
                    root:CreateButton(del[1], del[2])
                end)
            else
                del[2]()
            end
        end)
        row:SetScript("OnEnter", function(btn) ns:ShowTradeTooltip(btn, btn.rec) end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        self.historyRows[i] = row
    end

    -- Footer
    self.historyCount = hp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.historyCount:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    local exportBtn = Button(hp, "Export CSV", 96)
    exportBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 10)
    exportBtn:SetScript("OnClick", function() ns:ShowExport(ns:BuildTradesCSV(ns:FilteredTrades())) end)

    local refreshBtn = Button(hp, "Refresh", 80)
    refreshBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
    refreshBtn:SetScript("OnClick", function() ns:RefreshTradeSources() end)
    refreshBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:AddLine("Refresh")
        GameTooltip:AddLine("Re-reads your mailbox (if it's open) for AH sales and won bids, re-checks your auctions (if the Auction House is open), and redraws the list. New trades also appear on their own as they're logged.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("AH sales are logged from the mail, so they appear once you open a mailbox.", 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    refreshBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- Sold auctions whose gold is still in the mailbox (not logged until the mail is opened)
    self.historyPending = hp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.historyPending:SetPoint("RIGHT", refreshBtn, "LEFT", -10, 0)
    self.historyPending:SetJustifyH("RIGHT")
end

function ns:RefreshTradeSources()
    local did = {}
    if MailFrame and MailFrame:IsShown() and self.ScanMail then
        self:ScanMail()
        did[#did + 1] = "mailbox"
    end
    if self.ahOpen and self.QueryOwned then
        self:QueryOwned()
        did[#did + 1] = "your auctions"
    end
    self:RefreshHistory()
    if #did == 0 then
        self.Print("Trade History refreshed. To log AH sales, open a mailbox; they're read from the sale mail.")
    else
        self.Print("Refreshed %s.", table.concat(did, " and "))
    end
end

function ns:ShowTradeTooltip(owner, r)
    if not r then return end
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    GameTooltip:AddLine((self.TYPE_LABEL[r.type] or r.type) .. " - " .. date("%a %b %d %Y, %H:%M", r.t), 1, 1, 1)
    if r.pending then
        GameTooltip:AddLine("Sold. The gold is waiting in your mailbox.", 0.25, 1, 0.35, true)
        GameTooltip:AddLine("The amount is estimated from your listing price (after the AH cut). The exact figures replace it when you open the mail.", 0.7, 0.7, 0.7, true)
    end
    if r.char then GameTooltip:AddDoubleLine("Character", r.char .. (r.realm and (" - " .. r.realm) or ""), 0.7, 0.7, 0.7, 1, 1, 1) end
    if r.who then GameTooltip:AddDoubleLine(r.type == "trade" and "Traded with" or "Other player", r.who, 0.7, 0.7, 0.7, 1, 1, 1) end
    if r.type == "trade" then
        for _, side in ipairs({ { "You gave", r.gave, r.gaveMoney }, { "You received", r.got, r.gotMoney } }) do
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(side[1] .. ":", 1, 0.82, 0)
            local any = false
            for _, it in ipairs(side[2] or {}) do
                GameTooltip:AddLine("  " .. it.link .. " x" .. (it.count or 1), 1, 1, 1)
                any = true
            end
            if (side[3] or 0) > 0 then
                GameTooltip:AddLine("  " .. self.Money(side[3]), 1, 1, 1)
                any = true
            end
            if not any then GameTooltip:AddLine("  nothing", 0.5, 0.5, 0.5) end
        end
    elseif r.type == "listed" then
        GameTooltip:AddLine(r.link or r.name or "?", 1, 1, 1)
        GameTooltip:AddDoubleLine("Quantity", tostring(r.qty or 1), 0.7, 0.7, 0.7, 1, 1, 1)
        if r.unit then GameTooltip:AddDoubleLine("Your price per unit", self.Money(r.unit), 0.7, 0.7, 0.7, 1, 1, 1) end
        if r.total then
            GameTooltip:AddDoubleLine("Listing value", self.Money(r.total), 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine("After the AH cut if it all sells", self.Money(math.floor(r.total * (1 - self:AHCut()))), 0.7, 0.7, 0.7, 1, 1, 1)
        end
        GameTooltip:AddDoubleLine("Deposit paid", self.Money(r.deposit or 0), 0.7, 0.7, 0.7, 1, 1, 1)
        if r.hours then GameTooltip:AddDoubleLine("Duration", r.hours .. " hours", 0.7, 0.7, 0.7, 1, 1, 1) end
        GameTooltip:AddLine("The deposit comes back with the sale mail if it sells; it's lost if the auction expires or you cancel it.", 0.6, 0.6, 0.6, true)
    else
        GameTooltip:AddLine(r.link or r.name or "?", 1, 1, 1)
        local qty = r.qty or 1
        GameTooltip:AddDoubleLine("Quantity", tostring(qty), 0.7, 0.7, 0.7, 1, 1, 1)
        if r.total then
            GameTooltip:AddDoubleLine("Price", self.Money(r.total), 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine("Per unit", self.Money(r.total / qty), 0.7, 0.7, 0.7, 1, 1, 1)
        end
        if r.cut then GameTooltip:AddDoubleLine("AH cut", self.Money(r.cut), 0.7, 0.7, 0.7, 1, 1, 1) end
        if r.deposit and r.deposit > 0 then GameTooltip:AddDoubleLine("Deposit returned", self.Money(r.deposit), 0.7, 0.7, 0.7, 1, 1, 1) end
        if r.type == "ahsell" and r.net then GameTooltip:AddDoubleLine("You received", self.Money(r.net), 0.7, 0.7, 0.7, 1, 1, 1) end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: track the item, search the AH, or delete this entry", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function ns:RefreshHistory()
    if not (self.historyPanel and self.historyRows and self.historyCount) then return end
    for _, b in ipairs(self.filterButtons) do
        if b.key == self.historyFilter then b:LockHighlight() else b:UnlockHighlight() end
    end

    local recs = self:FilteredTrades()
    local spent, earned, cut = 0, 0, 0
    for _, r in ipairs(recs) do
        if not r.pending then -- uncollected sales aren't counted until the mail confirms the amount
            local d = GoldDelta(r)
            if d > 0 then earned = earned + d else spent = spent - d end
            cut = cut + (r.cut or 0)
        end
    end
    local net = earned - spent
    self.historySummary:SetText(string.format("Spent: %s     Received: %s     Net: %s%s",
        self.Money(spent), self.Money(earned), net == 0 and self.Money(0) or Signed(net, true),
        cut > 0 and ("     |cffaaaaaaAH cut paid: " .. self.Money(cut) .. "|r") or ""))

    -- Sold auctions not logged yet: their gold (and sale details) is still in the mailbox.
    local soldN, soldNet = #(self.pendingSales or {}), 0
    for _, p in ipairs(self.pendingSales or {}) do soldNet = soldNet + (p.net or 0) end
    if soldN == 0 then -- nothing seen live; fall back to what the AH said last time
        for _, a in ipairs(self.owned and self.owned.list or {}) do
            if a.sold then
                soldN = soldN + 1
                soldNet = soldNet + math.floor((a.unit or 0) * (a.qty or 1) * 0.95)
            end
        end
    end
    self.historyPending:SetText(soldN > 0 and string.format("|cff40ff40%d in mailbox (~%s)|r", soldN, self.Money(soldNet)) or "")

    self.historyScroll = math.max(0, math.min(self.historyScroll, #recs - NUM_ROWS))
    self.historyEmpty:SetShown(#recs == 0)
    if #recs == 0 then
        self.historyEmpty:SetText(#self:ScopedTrades(true) == 0
            and "No trades logged yet.\n\nPlayer trades and AH purchases are logged as they happen.\nAH sales and won bids are logged when you open a mailbox."
            or "Nothing matches this filter.")
    end
    for i, row in ipairs(self.historyRows) do
        local r = recs[i + self.historyScroll]
        if r then
            row.rec = r
            local c = row.cells
            c.date:SetText(date("%m/%d/%y %H:%M", r.t))
            if r.pending then
                c.type:SetText("|cff40ff40AH Sale|r |cff808080(in mail)|r")
                c.qty:SetText(r.qty and tostring(r.qty) or "?")
                c.amount:SetText(r.net and ("|cff808080~" .. self.Money(r.net) .. "|r") or "|cff808080?|r")
            else
                c.type:SetText((TYPE_COLOR[r.type] or "") .. (self.TYPE_LABEL[r.type] or r.type) .. "|r")
                c.qty:SetText(r.type ~= "trade" and tostring(r.qty or 1) or "")
                if r.type == "listed" then
                    -- Deposit paid, plus what the listing is worth
                    c.amount:SetText((r.total and ("|cff808080" .. self.Money(r.total) .. "|r  ") or "")
                        .. (r.deposit and r.deposit > 0 and Signed(-r.deposit, true) or "|cff808080no deposit|r"))
                else
                    c.amount:SetText(Signed(GoldDelta(r), true))
                end
            end
            c.item:SetText(ItemCell(r))
            c.who:SetText(r.who or "")
            row:Show()
        else
            row.rec = nil
            row:Hide()
        end
    end
    self.historyCount:SetText(string.format("%d shown of %d",
        #recs, #self:ScopedTrades(true)))
end
