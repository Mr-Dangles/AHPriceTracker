-- AH Price Tracker: Flip Finder tab (buy from vendor, sell on the AH)
local ADDON, ns = ...

local ROW_H = 20
local NUM_ROWS = 15
local WHITE = "Interface\\Buttons\\WHITE8X8"
local COLUMNS = { -- key, title, width
    { "item", "Item", 214 }, { "vendor", "Vendor (each)", 82 }, { "ah", "AH lowest", 82 }, { "qty", "Listed", 50 },
    { "sold", "Sold/day", 64 }, { "profit", "Profit/unit", 82 }, { "per20", "Per 20", 100 }, { "roi", "Return", 58 },
    { "profitDay", "Profit/day", 96 },
}

-- Column titles that change in AH -> Vendor mode
local AHV_TITLES = { vendor = "Vendor pays", profitDay = "Buy all listed" } -- per item too

ns.flipSort = "profitDay"
ns.flipAsc = false
ns.flipScroll = 0
ns.flipShowLosses = false
ns.flipMode = "vendorah"   -- "vendorah" = buy from vendor, sell on AH; "ahvendor" = buy on AH, sell to vendor
ns.flipMaybe = false

-- Item type filter. Trade Goods subclasses: 5 cloth, 6 leather, 7 metal & stone, 8 meat, 9 herb, 12 enchanting.
local GATHERED = { [6] = true, [7] = true, [9] = true } -- skinned, mined, picked
local function IsVendor(r) return ns.vendor and ns.vendor[r.id] ~= nil end
local function IsCrafted(r) return ns.crafted and ns.crafted[r.id] end
local function IsGathered(r) return r.classID == 7 and GATHERED[r.subclassID] and not IsCrafted(r) end
local function Class(id) return function(r) return r.classID == id end end

ns.FLIP_TYPES = {
    { "All items" },
    { "Crafting components", function(r) return r.classID == 7 or r.classID == 5 end,
        "Trade goods and reagents, whether sold by vendors or not." },
    { "Vendor items", IsVendor, "Sold by a vendor you, Auctionator or another addon user has seen." },
    { "Crafted items", IsCrafted, "Made by a profession. Learned when you or another addon user opens that profession's window." },
    { "Drop exclusives", function(r)
        return not IsVendor(r) and not IsCrafted(r) and not IsGathered(r) and r.classID ~= 12
            and not (r.classID == 7 and r.subclassID == 12)
    end, "Not sold by any known vendor, not crafted, not gathered: mob and world drops. Improves as more vendors and professions are seen." },
    { "Gathered (herbs, ore, skins)", IsGathered, "Herbs, ore, stone and leather." },
    { "-" },
    { "Trade Goods", Class(7) }, { "Consumables", Class(0) }, { "Reagents", Class(5) }, { "Recipes", Class(9) },
    { "Weapons", Class(2) }, { "Armor", Class(4) }, { "Containers", Class(1) }, { "Projectiles", Class(6) },
    { "Quivers", Class(11) }, { "Miscellaneous", Class(15) },
}
local TYPES = ns.FLIP_TYPES
ns.flipType = 1      -- index into TYPES
ns.flipMinPrice = nil -- cost per unit range, in copper
ns.flipMaxPrice = nil

local function TypeLabel(i) return TYPES[i][1] end

-- "1g20s", "50s", "75c", "1.5g" -> copper. A plain number is silver.
function ns.ParseMoney(text)
    text = strtrim((text or ""):lower()):gsub("%s", "")
    if text == "" then return nil end
    local total, found = 0, false
    for num, unit in text:gmatch("([%d%.]+)([gsc])") do
        local n = tonumber(num)
        if not n then return nil end
        total = total + n * (unit == "g" and 10000 or unit == "s" and 100 or 1)
        found = true
    end
    if not found then
        local n = tonumber(text)
        if not n then return nil end
        total = n * 100
    end
    return math.floor(total + 0.5)
end

-- Cost per unit for the price filter: what you pay (vendor price, or the AH price in AH > Vendor mode).
local function Cost(r)
    if ns.flipMode == "ahvendor" then return r.ah and r.ah.price end
    return r.vendorPrice
end

local function PassesFilters(r)
    local test = TYPES[ns.flipType][2]
    if test and not test(r) then return false end
    local cost = Cost(r)
    if ns.flipMinPrice and (not cost or cost < ns.flipMinPrice) then return false end
    if ns.flipMaxPrice and (not cost or cost > ns.flipMaxPrice) then return false end
    return true
end

StaticPopupDialogs["AHPT_FORGET_VENDOR"] = {
    text = "Remove %s from the Flip Finder?\n\n(It comes back if you visit a vendor that sells it.)",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, id)
        ns.vendor[id] = nil
        ns.flipPrices[id] = nil
        ns:RefreshFlips()
    end,
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

local function Colored(c, text)
    if not c then return text end
    if c > 0 then return "|cff40ff40" .. text .. "|r" end
    if c < 0 then return "|cffff5050" .. text .. "|r" end
    return text
end

local function SignedMoney(c)
    if not c then return "" end
    return Colored(c, (c < 0 and "-" or "+")) .. ns.Money(math.abs(c))
end

local function SortValue(r, key)
    if key == "item" then return r.name:lower() end
    if key == "vendor" then return r.vendorPrice end
    if key == "ah" then return r.ah and r.ah.price end
    if key == "qty" then return r.ah and r.ah.price and r.ah.qty end
    if key == "age" then return r.ah and r.ah.t end
    if key == "sold" then return r.soldDay end
    -- Items with measured volume rank by real daily profit; the rest follow, ranked by profit per 20.
    if key == "profitDay" then
        if ns.flipMode == "ahvendor" then return r.allListed end
        if r.profitDay then return 1e12 + r.profitDay end
        return r.per20
    end
    return r[key]
end

function ns:CreateFlipUI(f)
    local fp = CreateFrame("Frame", nil, f)
    fp:SetAllPoints()
    fp:Hide()
    self.flipsPanel = fp

    self.flipModeBtn = Button(fp, "", 150)
    self.flipModeBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    self.flipModeBtn:SetScript("OnClick", function()
        ns.flipMode = (ns.flipMode == "ahvendor") and "vendorah" or "ahvendor"
        ns.flipScroll = 0
        ns:RefreshFlips()
    end)
    self.flipModeBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Flip direction")
        GameTooltip:AddLine("Vendor > AH: buy from a vendor, list on the AH. Ranked by profit per day, using measured sales volume.", 1, 1, 1, true)
        GameTooltip:AddLine("AH > Vendor: AH listings cheaper than what a vendor pays for them. Checks every item in the market data.", 1, 1, 1, true)
        GameTooltip:AddLine("Click to switch.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    self.flipModeBtn:SetScript("OnLeave", GameTooltip_Hide)

    local scanBtn = Button(fp, "Scan AH prices", 120)
    scanBtn:SetPoint("LEFT", self.flipModeBtn, "RIGHT", 6, 0)
    scanBtn:SetScript("OnClick", function() ns:StartFlipScan() end)
    scanBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Scan AH prices")
        GameTooltip:AddLine("Searches the Auction House for every item with a known vendor price.", 1, 1, 1, true)
        if ns.ahOpen then
            GameTooltip:AddLine("Auction House is open.", 0.25, 1, 0.35)
        else
            GameTooltip:AddLine("You need to have the Auction House open (talk to an auctioneer) for this to work.", 1, 0.3, 0.3, true)
        end
        GameTooltip:Show()
    end)
    scanBtn:SetScript("OnLeave", GameTooltip_Hide)

    local cb = CreateFrame("CheckButton", nil, fp, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("LEFT", scanBtn, "RIGHT", 12, 0)
    cb:SetChecked(ns.flipShowLosses)
    cb:SetScript("OnClick", function(btn)
        ns.flipShowLosses = btn:GetChecked() and true or false
        ns.flipScroll = 0
        ns:RefreshFlips()
    end)
    local cbLabel = fp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cbLabel:SetText("Show losses")
    self.flipLossBox = cb

    local mb = CreateFrame("CheckButton", nil, fp, "UICheckButtonTemplate")
    mb:SetSize(24, 24)
    mb:SetPoint("LEFT", cbLabel, "RIGHT", 10, 0)
    mb:SetChecked(ns.flipMaybe)
    mb:SetScript("OnClick", function(btn)
        ns.flipMaybe = btn:GetChecked() and true or false
        ns.flipScroll = 0
        ns:RefreshFlips()
    end)
    mb:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Include maybe-vendor items")
        GameTooltip:AddLine("Adds every trade good in the market data whose AH price beats the game's listed buy price. Many of these aren't sold by any vendor, so check one first. Visiting a vendor that sells it confirms it.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    mb:SetScript("OnLeave", GameTooltip_Hide)
    local mbLabel = fp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mbLabel:SetPoint("LEFT", mb, "RIGHT", 2, 0)
    mbLabel:SetText("Maybe-vendor items")
    self.flipMaybeBox, self.flipMaybeLabel = mb, mbLabel
    cbLabel:Show()

    local note = fp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -38)
    note:SetText("After the AH cut (5%; 15% at the neutral goblin auction house).")

    -- Filter row: item type + cost range
    self.flipTypeBtn = Button(fp, "", 190)
    self.flipTypeBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -60)
    self.flipTypeBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local function Choose(i)
        ns.flipType = i
        ns.flipScroll = 0
        ns:RefreshFlips()
    end
    self.flipTypeBtn:SetScript("OnClick", function(btn, button)
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(btn, function(_, root)
                root:CreateTitle("Item type")
                for i, t in ipairs(TYPES) do
                    if t[1] == "-" then
                        root:CreateDivider()
                    else
                        local radio = root:CreateRadio(t[1], function() return ns.flipType == i end, function() Choose(i) end)
                        if t[3] and radio.SetTooltip then
                            radio:SetTooltip(function(tip) GameTooltip_SetTitle(tip, t[1]); GameTooltip_AddNormalLine(tip, t[3]) end)
                        end
                    end
                end
            end)
        else
            -- Older menu system: cycle instead (left = next, right = previous), skipping the divider.
            local step = (button == "RightButton") and -1 or 1
            local i = ns.flipType
            repeat i = (i - 1 + step) % #TYPES + 1 until TYPES[i][1] ~= "-"
            Choose(i)
        end
    end)
    self.flipTypeBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
        local t = TYPES[ns.flipType]
        GameTooltip:AddLine("Item type: " .. t[1])
        if t[3] then GameTooltip:AddLine(t[3], 1, 1, 1, true) end
        GameTooltip:AddLine("Click to choose.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    self.flipTypeBtn:SetScript("OnLeave", GameTooltip_Hide)

    local function PriceBox(anchor, x)
        local eb = CreateFrame("EditBox", nil, fp, "InputBoxTemplate")
        eb:SetSize(70, 20)
        eb:SetPoint("LEFT", anchor, "RIGHT", x, 0)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
        eb:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
        eb:SetScript("OnEnter", function(box)
            GameTooltip:SetOwner(box, "ANCHOR_BOTTOMRIGHT")
            GameTooltip:AddLine("Cost per unit")
            GameTooltip:AddLine("What you pay: the vendor price (Vendor > AH) or the AH price (AH > Vendor). Type 1g20s, 50s or 75c. A plain number means silver. Leave empty for no limit.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        eb:SetScript("OnLeave", GameTooltip_Hide)
        return eb
    end
    local costLabel = fp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    costLabel:SetPoint("LEFT", self.flipTypeBtn, "RIGHT", 14, 0)
    costLabel:SetText("Cost from")
    local minBox = PriceBox(costLabel, 8)
    local toLabel = fp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    toLabel:SetPoint("LEFT", minBox, "RIGHT", 6, 0)
    toLabel:SetText("to")
    local maxBox = PriceBox(toLabel, 8)
    local function OnPriceChanged()
        ns.flipMinPrice = ns.ParseMoney(minBox:GetText())
        ns.flipMaxPrice = ns.ParseMoney(maxBox:GetText())
        ns.flipScroll = 0
        ns:RefreshFlips()
    end
    minBox:SetScript("OnTextChanged", OnPriceChanged)
    maxBox:SetScript("OnTextChanged", OnPriceChanged)
    local clear = Button(fp, "Clear filters", 100, 20)
    clear:SetPoint("LEFT", maxBox, "RIGHT", 10, 0)
    clear:SetScript("OnClick", function()
        ns.flipType = 1
        minBox:SetText("")
        maxBox:SetText("")
        OnPriceChanged()
    end)

    self.flipSummary = fp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.flipSummary:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -88)
    self.flipSummary:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    self.flipSummary:SetJustifyH("LEFT")
    self.flipSummary:SetWordWrap(false)

    local list = CreateFrame("Frame", nil, fp, "BackdropTemplate")
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -108)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        ns.flipScroll = ns.flipScroll - delta * 3
        ns:RefreshFlips()
    end)

    -- Sortable column headers
    self.flipHeaders = {}
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
        h.baseTitle = col[2]
        h:SetHighlightTexture(WHITE)
        h:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)
        h:SetScript("OnClick", function()
            if ns.flipSort == key then
                ns.flipAsc = not ns.flipAsc
            else
                ns.flipSort, ns.flipAsc = key, (key == "item")
            end
            ns:RefreshFlips()
        end)
        h.key = key
        self.flipHeaders[#self.flipHeaders + 1] = h
        x = x + col[3]
    end
    local sep = list:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.15)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 4, -22)
    sep:SetPoint("TOPRIGHT", -4, -22)

    self.flipEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.flipEmpty:SetPoint("CENTER")
    self.flipEmpty:SetWidth(560)

    self.flipRows = {}
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
                local extras = {}
                if ns.vendor[r.id] then
                    extras[1] = { "Remove from Flip Finder", function()
                        StaticPopup_Show("AHPT_FORGET_VENDOR", r.link or r.name, nil, r.id)
                    end }
                end
                ns:ShowItemMenu(btn, r.id, extras)
            elseif IsModifiedClick("CHATLINK") then
                ns:LinkInChat(r.id)
            end
        end)
        row:SetScript("OnEnter", function(btn) ns:ShowFlipTooltip(btn, btn.rec) end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        self.flipRows[i] = row
    end

    self.flipCount = fp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.flipCount:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    self.flipStatus = fp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.flipStatus:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 16)
end

function ns:ShowFlipTooltip(owner, r)
    if not r then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if r.link then GameTooltip:SetHyperlink(r.link) else GameTooltip:SetItemByID(r.id) end
    GameTooltip:AddLine(" ")
    local ah = r.ah
    if self.flipMode == "ahvendor" then
        GameTooltip:AddDoubleLine("A vendor pays", self.Money(r.vendorPrice), 0.8, 0.8, 0.8, 1, 1, 1)
        if r.unconfirmed then
            GameTooltip:AddLine("Vendor price from the item catalogue, not yet confirmed by the game. Hover again in a moment.", 1, 0.6, 0, true)
        end
        if ah and ah.price then
            GameTooltip:AddDoubleLine("AH lowest", self.Money(ah.price), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("Profit per unit (no AH cut when buying)", SignedMoney(r.profit), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("If every listed unit were this cheap", SignedMoney(r.allListed), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddLine("Only the cheapest listings may be under the vendor price. Search the AH to see how many.", 0.6, 0.6, 0.6, true)
            GameTooltip:AddLine(string.format("AH price from %s%s", ah.source or "?", ah.t and (", " .. self.Ago(ah.t)) or ""), 0.5, 0.5, 0.5)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Right-click: track, search the AH, link in chat", 0.5, 0.5, 0.5)
        GameTooltip:Show()
        return
    end
    local from = r.vendorName and ("from " .. r.vendorName)
        or (r.vendorSource == "Auctionator" and "from Auctionator's vendor cache")
        or (r.vendorSource == "shared" and "shared by another addon user")
        or (r.maybe and "(game's listed price)") or ""
    GameTooltip:AddDoubleLine("Vendor price (each) " .. from, self.Money(r.vendorPrice), 0.8, 0.8, 0.8, 1, 1, 1)
    if r.bundle and r.bundle > 1 then
        -- What the vendor window shows: the price of a whole bundle
        GameTooltip:AddDoubleLine("Vendor sells them in bundles", string.format("%d for %s", r.bundle, self.Money(r.vendorPrice * r.bundle)),
            0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.maybe then
        GameTooltip:AddLine("Not confirmed: no vendor selling this has been seen. Many trade goods aren't sold by any vendor.", 1, 0.6, 0, true)
    end
    if r.limited then GameTooltip:AddLine("Limited supply at the vendor", 1, 0.6, 0) end
    if not ah then
        GameTooltip:AddLine("No AH price yet. Open the AH and press Scan AH prices.", 0.6, 0.6, 0.6, true)
    elseif ah.none then
        GameTooltip:AddLine("None listed on the AH at the last scan. No competition, but demand is unknown.", 1, 0.82, 0, true)
    else
        GameTooltip:AddDoubleLine("AH lowest", self.Money(ah.price), 0.8, 0.8, 0.8, 1, 1, 1)
        if ah.qty then GameTooltip:AddDoubleLine("Listed", tostring(ah.qty), 0.8, 0.8, 0.8, 1, 1, 1) end
        GameTooltip:AddDoubleLine(string.format("You receive after %d%% cut", self:AHCut() * 100 + 0.5), self.Money(math.floor(ah.price * (1 - self:AHCut()))), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Profit per unit", SignedMoney(r.profit), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Profit per 20", SignedMoney(r.per20), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(self:SalesLong(r.id), 1, 1, 1, true)
    if r.profitDay and r.soldDay > 0 then
        GameTooltip:AddDoubleLine("Profit/day if you sold every unit bought", SignedMoney(r.profitDay), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Time for the market to buy 20", self.Duration(r.daysFor20 * 86400), 0.8, 0.8, 0.8, 1, 1, 1)
        if r.supplyDays then
            GameTooltip:AddDoubleLine("Days of supply already listed", string.format("%.1f", r.supplyDays), 0.8, 0.8, 0.8, 1, 1, 1)
        end
        GameTooltip:AddLine("Other sellers share these buyers, so expect a fraction of this.", 0.5, 0.5, 0.5, true)
    elseif r.soldDay == 0 then
        GameTooltip:AddLine("No sales seen while watched. Listings may just sit.", 1, 0.4, 0.4, true)
    else
        GameTooltip:AddLine("Track this item (right-click) and keep the AH open to measure how much sells.", 0.6, 0.6, 0.6, true)
    end
    if ah then
        GameTooltip:AddLine(string.format("AH price from %s%s", ah.source or "?", ah.t and (", " .. self.Ago(ah.t)) or ""), 0.5, 0.5, 0.5)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: track, search the AH, link in chat, remove", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function ns:RefreshFlips()
    if not (self.flipsPanel and self.flipRows) then return end
    local all = self:GetFlips()
    local rows, profitable, best, bestDay = {}, 0, nil, nil
    local filtered = false
    for _, r in ipairs(all) do
        if PassesFilters(r) then
            if r.profit and r.profit > 0 then
                profitable = profitable + 1
                if not best or r.per20 > best.per20 then best = r end
                if r.profitDay and r.profitDay > 0 and (not bestDay or r.profitDay > bestDay.profitDay) then bestDay = r end
            end
            if self.flipShowLosses or not r.profit or r.profit > 0 then rows[#rows + 1] = r end
        else
            filtered = true
        end
    end
    local ahv = self.flipMode == "ahvendor"
    self.flipTypeBtn:SetText(TypeLabel(self.flipType))
    self.flipModeBtn:SetText(ahv and "Mode: AH > Vendor" or "Mode: Vendor > AH")
    self.flipMaybeBox:SetShown(not ahv)
    self.flipMaybeLabel:SetShown(not ahv)
    for _, h in ipairs(self.flipHeaders) do
        h.title = (ahv and AHV_TITLES[h.key]) or h.baseTitle
    end

    local key, asc = self.flipSort, self.flipAsc
    table.sort(rows, function(a, b)
        local va, vb = SortValue(a, key), SortValue(b, key)
        if va == nil or vb == nil or va == vb then
            if (va == nil) ~= (vb == nil) then return vb == nil end -- unknowns last
            return a.name < b.name
        end
        if asc then return va < vb end
        return va > vb
    end)

    for _, h in ipairs(self.flipHeaders) do
        local arrow = (h.key == key) and (asc and " ^" or " v") or ""
        h.text:SetText(h.title .. arrow)
    end

    local summary
    if ahv then
        summary = string.format("%d AH listing%s below what a vendor pays (%s)", #all, #all == 1 and "" or "s", ns.MarketLabel(self:MarketKey()))
        if best then summary = summary .. string.format("   |   Best: %s  %s each", best.link or best.name, SignedMoney(best.profit)) end
    else
        summary = string.format("%d vendor item%s known   |   %d profitable", #all, #all == 1 and "" or "s", profitable)
        local watching = self.watchList and #self.watchList or 0
        if watching > 0 then summary = summary .. string.format("   |   measuring volume on top %d", watching) end
    end
    if ahv then
        -- summary done
    elseif bestDay then
        summary = summary .. string.format("   |   Best seller: %s  %s/day", bestDay.link or bestDay.name, SignedMoney(bestDay.profitDay))
    elseif best then
        summary = summary .. string.format("   |   Best margin: %s  %s per 20", best.link or best.name, SignedMoney(best.per20))
    end
    self.flipSummary:SetText(summary)

    self.flipScroll = math.max(0, math.min(self.flipScroll, #rows - NUM_ROWS))
    self.flipEmpty:SetShown(#rows == 0)
    if #rows == 0 then
        if ahv then
            self.flipEmpty:SetText(self:MarketData()
                and (filtered and "Nothing matches the type and price filters. Press Clear filters to see everything."
                    or "No AH listings below vendor price in the market data right now.")
                or "AH > Vendor needs the market data file.\nRun \"Update Market Data.bat\" in the addon folder, then /reload.")
        else
            self.flipEmpty:SetText(#all == 0
                and "No vendor prices known yet.\n\nOpen any vendor and its prices are learned automatically.\nThen open the Auction House and press Scan AH prices."
                or (filtered and "Nothing matches the type and price filters. Press Clear filters to see everything.")
                or "No profitable flips right now. Tick \"Show losses\" to see everything.")
        end
    end

    for i, row in ipairs(self.flipRows) do
        local r = rows[i + self.flipScroll]
        row.rec = r
        if r then
            local c = row.cells
            local icon = r.icon and ("|T" .. r.icon .. ":14:14|t ") or ""
            local tag = (r.limited and " |cffff9900(limited)|r") or (r.maybe and " |cffff9900(check vendor)|r")
                or (r.unconfirmed and " |cffff9900(unverified)|r") or ""
            c.item:SetText(icon .. (r.link or r.name) .. tag)
            c.vendor:SetText(self.Money(r.vendorPrice))
            local ah = r.ah
            if not ah then
                c.ah:SetText((ns.unitPending and ns.unitPending[r.id]) and "|cffffd100re-checking|r" or "|cff808080not scanned|r")
            elseif ah.none then
                c.ah:SetText("|cffffd100none listed|r")
            else
                c.ah:SetText(self.Money(ah.price))
            end
            c.qty:SetText(ah and ah.price and ah.qty and tostring(ah.qty) or "")
            c.sold:SetText(ns:SalesShort(r.id) or ((ns.unitPending and ns.unitPending[r.id]) and "|cff808080...|r" or ""))
            c.profit:SetText(SignedMoney(r.profit))
            c.per20:SetText(SignedMoney(r.per20))
            c.roi:SetText(r.roi and Colored(r.roi, string.format("%+.0f%%", r.roi * 100)) or "")
            if ahv then
                c.profitDay:SetText(SignedMoney(r.allListed))
            elseif r.profitDay then
                c.profitDay:SetText(r.soldDay == 0 and "|cffff5050no buyers|r" or SignedMoney(r.profitDay))
            else
                c.profitDay:SetText(r.profit and "|cff808080no volume yet|r" or "")
            end
            row:Show()
        else
            row:Hide()
        end
    end

    self.flipCount:SetText(string.format("%d shown. Click a column to sort. Hover for details.", #rows))
    local q = self.flipQueue and #self.flipQueue or 0
    local unpriced = self.UnpricedVendorCount and self:UnpricedVendorCount() or 0
    if self.ahOpen and self.settings.pauseWhileTrading and self:IsBusyAtAH() and (q > 0 or unpriced > 0) then
        self.flipStatus:SetText("|cffff9900Scanning paused while a buy/sell screen is open.|r")
    elseif q > 0 and self.ahOpen then
        self.flipStatus:SetText(string.format("|cffffd100Scanning AH: %d left...|r", q))
    elseif q > 0 then
        self.flipStatus:SetText("|cffff5050Scan paused: Auction House closed.|r")
    elseif unpriced > 0 then
        self.flipStatus:SetText(self.ahOpen
            and string.format("|cffffd100Pricing vendor items in the background: %d left (~%s)|r", unpriced, self.Duration(unpriced * 1.5 + 5))
            or string.format("|cff808080%d vendor items not priced yet: open the AH|r", unpriced))
    else
        self.flipStatus:SetText("")
    end
end
