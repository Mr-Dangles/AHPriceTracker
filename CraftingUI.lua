-- AH Price Tracker: Crafting tab (profession dropdown, skill-bracket summary, recipe profits)
local ADDON, ns = ...

local ROW_H = 20
local NUM_ROWS = 14
local WHITE = "Interface\\Buttons\\WHITE8X8"
local COLUMNS = { -- key, title, width
    { "name", "Recipe / item", 210 }, { "low", "Skill", 62 }, { "cost", "Materials", 92 }, { "sells", "Sells for", 92 },
    { "profit", "Profit", 92 }, { "margin", "Margin", 56 }, { "soldDay", "Sold/day", 60 }, { "profitDay", "Profit/day", 92 },
    { "source", "Learned from", 90 },
}
local GATHER_TITLES = { name = "Item", low = "Item lvl", cost = "", sells = "Sells for", profit = "Value", margin = "",
    profitDay = "Value/day", source = "Listed" }

ns.craftProf = 185 -- Cooking
ns.craftSort = "profit"
ns.craftAsc = false
ns.craftScroll = 0
ns.craftSearch = ""
ns.craftOnlyPriced = true

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

local function Signed(c)
    if not c then return "" end
    local col = c > 0 and "|cff40ff40+" or (c < 0 and "|cffff5050-" or "")
    return col .. ns.Money(math.abs(c)) .. ((c ~= 0) and "|r" or "")
end

local function ProfLabel(key)
    if type(key) == "string" then
        for _, g in ipairs(ns.GATHERING) do if g.key == key then return g.label end end
    end
    local d = ns:RecipeData()
    return d and d.professions[key] and d.professions[key].name or "?"
end

local function SortValue(r, key)
    if key == "name" then return r.name:lower() end
    if key == "source" then return r.recipeItem and 1 or 0 end
    return r[key]
end

function ns:CreateCraftingUI(f)
    local cp = CreateFrame("Frame", nil, f)
    cp:SetAllPoints()
    cp:Hide()
    self.craftPanel = cp

    -- Profession dropdown
    self.craftProfBtn = Button(cp, "", 200)
    self.craftProfBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    self.craftProfBtn:SetScript("OnClick", function(btn)
        local function choose(k) ns.craftProf = k; ns.craftScroll = 0; ns:RefreshCrafting() end
        if not (MenuUtil and MenuUtil.CreateContextMenu) then
            -- No modern menu: cycle through professions
            local keys = {}
            local d = ns:RecipeData()
            for _, id in ipairs({ 171, 164, 185, 333, 202, 129, 165, 186, 197, 40 }) do
                if d and d.professions[id] then keys[#keys + 1] = id end
            end
            for _, g in ipairs(ns.GATHERING) do keys[#keys + 1] = g.key end
            local nextKey = keys[1]
            for i, k in ipairs(keys) do if k == ns.craftProf then nextKey = keys[i % #keys + 1] end end
            choose(nextKey)
            return
        end
        MenuUtil.CreateContextMenu(btn, function(_, root)
            root:CreateTitle("Crafting professions")
            local d = ns:RecipeData()
            for _, id in ipairs({ 171, 164, 185, 333, 202, 129, 165, 186, 197, 40 }) do
                if d and d.professions[id] then
                    root:CreateRadio(d.professions[id].name, function() return ns.craftProf == id end, function() choose(id) end)
                end
            end
            root:CreateDivider()
            root:CreateTitle("Gathering professions")
            for _, g in ipairs(ns.GATHERING) do
                root:CreateRadio(g.label, function() return ns.craftProf == g.key end, function() choose(g.key) end)
            end
        end)
    end)

    local search = CreateFrame("EditBox", nil, cp, "SearchBoxTemplate")
    search:SetSize(170, 20)
    search:SetPoint("LEFT", self.craftProfBtn, "RIGHT", 14, 0)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(box)
        ns.craftSearch = strtrim(box:GetText() or ""):lower()
        ns.craftScroll = 0
        ns:RefreshCrafting()
    end)

    local cb = CreateFrame("CheckButton", nil, cp, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("LEFT", search, "RIGHT", 10, 0)
    cb:SetChecked(ns.craftOnlyPriced)
    cb:SetScript("OnClick", function(btn)
        ns.craftOnlyPriced = btn:GetChecked() and true or false
        ns.craftScroll = 0
        ns:RefreshCrafting()
    end)
    local cbl = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cbl:SetText("Only items with prices")

    self.craftNote = cp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.craftNote:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -38)
    self.craftNote:SetText("After the AH cut (5%; 15% at the neutral goblin auction house). Materials at the cheaper of vendor or AH.")

    -- Skill-bracket summary cards: "is this profession worth starting?"
    self.craftCards = {}
    local cw = 166
    for i = 1, #ns.BRACKETS do
        local c = CreateFrame("Frame", nil, cp, "BackdropTemplate")
        c:SetSize(cw - 6, 42)
        c:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * cw, -60)
        c:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        c:SetBackdropColor(1, 1, 1, 0.04)
        c:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        c.title:SetPoint("TOPLEFT", 6, -4)
        c.line1 = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.line1:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -2)
        c.line1:SetPoint("RIGHT", -4, 0)
        c.line1:SetJustifyH("LEFT")
        c.line1:SetWordWrap(false)
        c.line2 = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.line2:SetPoint("TOPLEFT", c.line1, "BOTTOMLEFT", 0, -1)
        c.line2:SetPoint("RIGHT", -4, 0)
        c.line2:SetJustifyH("LEFT")
        c.line2:SetWordWrap(false)
        c:EnableMouse(true)
        c:SetScript("OnEnter", function(card)
            local s = card.summary
            if not s then return end
            GameTooltip:SetOwner(card, "ANCHOR_BOTTOMRIGHT")
            GameTooltip:AddLine(card.title:GetText())
            GameTooltip:AddLine(string.format("%d %s, %d with prices, %d profitable.", s.total,
                card.gathering and "items" or "recipes", s.priced, s.profitable), 1, 1, 1, true)
            if s.best then
                GameTooltip:AddDoubleLine("Best per " .. (card.gathering and "unit" or "craft"), s.best.name, 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:AddDoubleLine(" ", Signed(s.best.profit), 0.8, 0.8, 0.8, 1, 1, 1)
            end
            if s.bestDay then
                GameTooltip:AddDoubleLine("Best per day (with sales volume)", s.bestDay.name, 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:AddDoubleLine(" ", Signed(s.bestDay.profitDay) .. "/day", 0.8, 0.8, 0.8, 1, 1, 1)
            end
            GameTooltip:AddLine(card.gathering and "Brackets use item level as a rough guide to the skill needed."
                or "Brackets use the skill where a recipe turns yellow.", 0.5, 0.5, 0.5, true)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", GameTooltip_Hide)
        self.craftCards[i] = c
    end

    local list = CreateFrame("Frame", nil, cp, "BackdropTemplate")
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -110)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        ns.craftScroll = ns.craftScroll - delta * 3
        ns:RefreshCrafting(true)
    end)

    self.craftHeaders = {}
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
            if ns.craftSort == key then ns.craftAsc = not ns.craftAsc else ns.craftSort, ns.craftAsc = key, (key == "name" or key == "low") end
            ns:RefreshCrafting()
        end)
        self.craftHeaders[#self.craftHeaders + 1] = h
        x = x + col[3]
    end
    local sep = list:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.15)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 4, -22)
    sep:SetPoint("TOPRIGHT", -4, -22)

    self.craftEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.craftEmpty:SetPoint("CENTER")
    self.craftEmpty:SetWidth(600)

    self.craftRows = {}
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
            if not r then return end
            if button == "RightButton" then
                ns:ShowItemMenu(btn, r.item)
            elseif IsModifiedClick("CHATLINK") then
                ns:LinkInChat(r.item)
            end
        end)
        row:SetScript("OnEnter", function(btn) ns:ShowCraftTooltip(btn, btn.rec) end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        self.craftRows[i] = row
    end

    self.craftFoot = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.craftFoot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    self.craftFoot:SetPoint("RIGHT", f, "RIGHT", -18, 0)
    self.craftFoot:SetJustifyH("LEFT")
end

function ns:ShowCraftTooltip(owner, r)
    if not r then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(r.item)
    GameTooltip:AddLine(" ")
    if r.gather then
        GameTooltip:AddDoubleLine("AH price", self.Money(r.ahPrice), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Listed", tostring(r.ahQty or 0), 0.8, 0.8, 0.8, 1, 1, 1)
    else
        GameTooltip:AddLine(r.name .. (r.count > 1 and (" (makes " .. r.count .. ")") or ""), 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Skill", string.format("yellow at %d, grey at %d", r.low or 0, r.high or 0), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddLine("Materials:", 0.8, 0.8, 0.8)
        for _, g in ipairs(r.reagents) do
            GameTooltip:AddDoubleLine(string.format("  %s x%d", self:ItemName(g.id), g.n),
                g.unit and (self.Money(g.unit * g.n) .. " |cff808080(" .. g.src .. ")|r") or "|cffff9900no price|r",
                1, 1, 1, 1, 1, 1)
        end
        GameTooltip:AddDoubleLine("Materials total", r.cost and self.Money(r.cost) or "|cffff9900incomplete|r", 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Sells on AH (after cut)", r.sells and self.Money(r.sells) or "|cff808080no AH price|r", 0.8, 0.8, 0.8, 1, 1, 1)
        if r.profit then GameTooltip:AddDoubleLine("Profit per craft", Signed(r.profit), 0.8, 0.8, 0.8, 1, 1, 1) end
        GameTooltip:AddLine(" ")
        if r.recipeItem then
            GameTooltip:AddDoubleLine("Learned from", self:ItemName(r.recipeItem), 0.8, 0.8, 0.8, 1, 1, 1)
            if r.recipePrice then GameTooltip:AddDoubleLine("Recipe on the AH", self.Money(r.recipePrice), 0.8, 0.8, 0.8, 1, 1, 1) end
        else
            GameTooltip:AddDoubleLine("Learned from", "Trainer (or automatically)", 0.8, 0.8, 0.8, 1, 1, 1)
        end
        if r.known then GameTooltip:AddLine("You know this recipe.", 0.25, 1, 0.35) end
    end
    if r.soldDay then
        GameTooltip:AddDoubleLine("Market buys per day", string.format("~%.1f", r.soldDay), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: track, search the AH, link in chat", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function ns:RefreshCrafting(scrollOnly)
    if not (self.craftPanel and self.craftRows) then return end
    local gathering = type(self.craftProf) == "string"
    self.craftProfBtn:SetText("Profession: " .. ProfLabel(self.craftProf))

    if not scrollOnly or not self.craftCache then
        local all
        if gathering then all = self:GatheringRows(self.craftProf) else all = self:CraftingRows(self.craftProf) end
        local summary = self:BracketSummary(all, gathering)
        local rows = {}
        local q = self.craftSearch or ""
        for _, r in ipairs(all) do
            local okSearch = q == "" or r.name:lower():find(q, 1, true)
            if not okSearch and not gathering then
                for _, g in ipairs(r.reagents) do
                    if self:ItemName(g.id):lower():find(q, 1, true) then okSearch = true; break end
                end
            end
            if okSearch and (not self.craftOnlyPriced or r.profit) then rows[#rows + 1] = r end
        end
        local key, asc = self.craftSort, self.craftAsc
        table.sort(rows, function(a, b)
            local va, vb = SortValue(a, key), SortValue(b, key)
            if va == nil or vb == nil or va == vb then
                if (va == nil) ~= (vb == nil) then return vb == nil end
                return a.name < b.name
            end
            if asc then return va < vb end
            return va > vb
        end)
        self.craftCache, self.craftAll, self.craftSummary = rows, all, summary
    end
    local rows, all, summary = self.craftCache, self.craftAll, self.craftSummary

    -- Headers change for gathering professions
    for _, h in ipairs(self.craftHeaders) do
        local title = gathering and GATHER_TITLES[h.key] or h.title
        if gathering and h.key == "soldDay" then title = "Sold/day" end
        h.text:SetText((title or h.title) .. ((h.key == self.craftSort) and (self.craftAsc and " ^" or " v") or ""))
    end

    for i, card in ipairs(self.craftCards) do
        local s = summary[i]
        card.summary, card.gathering = s, gathering
        card.title:SetText(gathering and string.format("Item level %d-%d", math.floor(s.from / 5), math.floor(s.to / 5))
            or (s.to >= 1000 and string.format("Skill %d+", s.from) or string.format("Skill %d-%d", s.from, s.to)))
        if s.total == 0 then
            card.line1:SetText("|cff808080nothing here|r")
            card.line2:SetText("")
        else
            card.line1:SetText(string.format("%d/%d profitable", s.profitable, s.priced))
            card.line2:SetText(s.best and ("best " .. Signed(s.best.profit)) or "|cff808080no prices yet|r")
        end
        local good = s.profitable > 0
        card:SetBackdropBorderColor(good and 0.25 or 0.3, good and 0.7 or 0.3, good and 0.3 or 0.3, 1)
    end

    self.craftScroll = math.max(0, math.min(self.craftScroll, #rows - NUM_ROWS))
    self.craftEmpty:SetShown(#rows == 0)
    if #rows == 0 then
        self.craftEmpty:SetText(not self:RecipeData() and "Recipe data file missing (Recipes.lua)."
            or (#all > 0 and "Nothing matches. Untick \"Only items with prices\" to see every recipe."
                or "No items for this profession."))
    end
    for i, row in ipairs(self.craftRows) do
        local r = rows[i + self.craftScroll]
        row.rec = r
        if r then
            local c = row.cells
            local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(r.item)
            c.name:SetText((icon and ("|T" .. icon .. ":14:14|t ") or "") .. r.name .. (r.known and " |cff40ff40*|r" or ""))
            if gathering then
                c.low:SetText(tostring(r.low or ""))
                c.cost:SetText("")
                c.sells:SetText(r.sells and self.Money(r.sells) or "|cff808080?|r")
                c.profit:SetText(r.profit and self.Money(r.profit) or "")
                c.margin:SetText("")
                c.source:SetText(r.ahQty and tostring(r.ahQty) or "")
            else
                c.low:SetText(string.format("%d-%d", r.low or 0, r.high or 0))
                c.cost:SetText(r.cost and self.Money(r.cost) or (r.partialCost and "|cffff9900?|r" or "|cff808080?|r"))
                c.sells:SetText(r.sells and self.Money(r.sells) or "|cff808080?|r")
                c.profit:SetText(Signed(r.profit))
                c.margin:SetText(r.margin and string.format("%+.0f%%", r.margin * 100) or "")
                c.source:SetText(r.recipeItem and "|cffffd100Recipe|r" or "Trainer")
            end
            c.soldDay:SetText(r.soldDay and string.format("~%.1f", r.soldDay) or "")
            c.profitDay:SetText(r.profitDay and Signed(r.profitDay) or "")
            row:Show()
        else
            row:Hide()
        end
    end
    local profitable = 0
    for _, r in ipairs(all) do if r.profit and r.profit > 0 then profitable = profitable + 1 end end
    self.craftFoot:SetText(string.format("%s: %d %s, %d profitable at current prices.%s",
        ProfLabel(self.craftProf), #all, gathering and "items" or "recipes", profitable,
        gathering and "" or "  |cff40ff40*|r = you know it."))
end
