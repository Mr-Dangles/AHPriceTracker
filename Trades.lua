-- AH Price Tracker: trade history logging
--   * player-to-player trades (items + gold both ways)
--   * Auction House purchases (commodity and item buyouts, logged the moment they succeed)
--   * Auction House sales and won bids (read from the mail invoices when you open a mailbox)
local ADDON, ns = ...

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local NUM_TRADE_SLOTS = MAX_TRADABLE_ITEMS or 6
local AH_MAIL_DAYS = 30
local MAIL_BUCKET = 300 -- seconds; tolerance when matching a mail we've already logged

ns.TYPE_LABEL = {
    trade  = "Trade",
    ahbuy  = "AH Buy",
    ahwon  = "AH Won Bid",
    ahsell = "AH Sale",
    listed = "AH Listed",
}

function ns.LinkID(link)
    return link and tonumber(link:match("item:(%d+)"))
end

function ns.LinkName(link)
    return link and (link:match("%[(.-)%]") or link) or ""
end

-- Quantity from a mail subject like "Auction successful: Hot Spices (20)"; 1 if there's none.
local function SubjectCount(subject)
    return tonumber(subject and subject:match("%((%d+)%)%s*$")) or 1
end

-- Best-effort item ID from a name (only works for cached items).
local function ResolveName(name)
    if not name or name == "" then return nil end
    for id, e in pairs(ns.items or {}) do
        if e.name == name then return id, e.link end
    end
    local _, link = GetItemInfo(name)
    return ns.LinkID(link), link
end

function ns:InitTrades()
    local r = self.realmData
    r.trades = r.trades or {}
    r.mailSeen = r.mailSeen or {}
    self.trades = r.trades
    self.mailSeen = r.mailSeen
    -- Sales seen in chat but not collected from the mail yet (sale mail expires after 30 days)
    r.pendingSales = r.pendingSales or {}
    for i = #r.pendingSales, 1, -1 do
        if r.pendingSales[i].t < time() - 31 * 86400 then table.remove(r.pendingSales, i) end
    end
    self.pendingSales = r.pendingSales
    -- v1.6.2 fix: sales from the AH's "sold" notification were saved with the auction's whole remaining
    -- stack as the quantity, once per partial sale. Their real quantity is unknown: clear it (the sale
    -- mail fills it in) and keep one entry per auction.
    local seenAuction = {}
    for i = 1, #r.pendingSales do
        local p = r.pendingSales[i]
        if p and p.via == "notify" and not p.qtyChecked then
            p.qty, p.net, p.qtyChecked = nil, nil, true
        end
    end
    for i = #r.pendingSales, 1, -1 do
        local p = r.pendingSales[i]
        if p.via == "notify" and p.auctionID then
            if seenAuction[p.auctionID] then table.remove(r.pendingSales, i) else seenAuction[p.auctionID] = true end
        end
    end
    -- v1.6.1 fix: a sale spotted in your auction list after the mail had already logged it was
    -- counted twice. Drop pending sales that match a logged sale (same item and quantity, within 3h).
    for i = #r.pendingSales, 1, -1 do
        local p = r.pendingSales[i]
        for _, s in ipairs(r.trades) do
            if s.type == "ahsell" and not s.pending and p.itemID and s.itemID == p.itemID and s.qty == p.qty
                and math.abs((s.loggedAt or s.t) - p.t) <= 3 * 3600 then
                table.remove(r.pendingSales, i)
                break
            end
        end
    end
    -- Repair AH mail quantities. Versions before 1.5 read the wrong invoice field, so quantities
    -- could be anything. The remembered mail subject ("Hot Spices (40)") has the real one; match each
    -- record to its mail by time and the gold it paid.
    local subjectAt = {}
    for key, t in pairs(self.mailSeen) do
        local subject, money = key:match("^(.*)|([^|]*)|[^|]*$")
        if subject then subjectAt[t .. "|" .. (money or "")] = subject end
    end
    for _, r in ipairs(self.trades) do
        if r.type == "ahsell" or r.type == "ahwon" then
            local subject = subjectAt[r.t .. "|" .. tostring(r.net or "")]
            if subject then r.qty = SubjectCount(subject) end
            if not r.qty or r.qty < 1 then r.qty = 1 end
        end
    end

    local cutoff = time() - (AH_MAIL_DAYS + 10) * 86400
    for k, t in pairs(self.mailSeen) do
        if t < cutoff then self.mailSeen[k] = nil end
    end
end

function ns:AddTrade(rec)
    if not self.trades then return end
    rec.t = rec.t or time()
    rec.loggedAt = time() -- when it was logged (a sale's t is when the mail arrived)
    rec.char = rec.char or UnitName("player")
    self.trades[#self.trades + 1] = rec
    if rec.type == "trade" then
        self.Print("Logged trade with %s.", rec.who or "?")
    elseif rec.type == "ahsell" then
        self.Print("Logged AH sale: %s x%d for %s.", rec.link or rec.name or "?", rec.qty or 1, self.Money(rec.total or rec.net))
    elseif rec.type == "listed" then
        self.Print("Logged listing: %s x%d at %s each (deposit %s).", rec.link or rec.name or "?", rec.qty or 1,
            self.Money(rec.unit), self.Money(rec.deposit or 0))
    else
        self.Print("Logged %s: %s x%d for %s.", self.TYPE_LABEL[rec.type], rec.link or rec.name or "?", rec.qty or 1, self.Money(rec.total))
    end
    if self.OnTradesUpdated then self:OnTradesUpdated(rec) end
end

-- A confirmed auction posting -> "AH Listed" entry. The deposit is the gold that left your bags; it
-- comes back inside the sale mail if the auction sells, so sales and listings net out correctly.
function ns:LogPost(p)
    self:AddTrade({
        type = "listed", itemID = p.itemID, link = p.link, name = p.name,
        qty = p.qty, unit = p.unit, total = p.total, deposit = p.deposit, hours = p.hours,
    })
end

---------------------------------------------------------------------------
-- Character scope: which characters' records the Trade History, Profit and My Auctions pages show
---------------------------------------------------------------------------
ns.SCOPES = {
    { "char", "This character" },
    { "realm", "All characters (this realm)" },
    { "account", "Whole account (all realms)" },
}
function ns:Scope() return self.settings.scope or "realm" end

-- Realm tables to read for the current scope.
function ns:ScopedRealms()
    if self:Scope() == "account" then return self.db.realms end
    return { [GetRealmName() or "?"] = self.realmData }
end

-- Trade records (and optionally live pending sales) for the current scope.
function ns:ScopedTrades(includePending)
    local me, scope = UnitName("player"), self:Scope()
    local out = {}
    for realm, rd in pairs(self:ScopedRealms()) do
        local lists = { rd.trades or {} }
        if includePending then lists[2] = rd.pendingSales or {} end
        for _, list in ipairs(lists) do
            for _, r in ipairs(list) do
                if scope ~= "char" or r.char == me then
                    if scope == "account" then r.realm = r.realm or realm end
                    out[#out + 1] = r
                end
            end
        end
    end
    return out
end

function ns:DeleteTrade(rec)
    -- The record may belong to any realm when viewing the whole account.
    for _, rd in pairs(self.db.realms) do
        for _, list in ipairs({ rd.trades or {}, rd.pendingSales or {} }) do
            for i = #list, 1, -1 do
                if list[i] == rec then
                    table.remove(list, i)
                    break
                end
            end
        end
    end
    if self.OnTradesUpdated then self:OnTradesUpdated(rec) end
end

---------------------------------------------------------------------------
-- Player-to-player trades
---------------------------------------------------------------------------
local trade -- the trade currently (or most recently) open

local function Snapshot()
    if not trade or not trade.open then return end
    local snap = { gave = {}, got = {} }
    for i = 1, NUM_TRADE_SLOTS do
        local name, _, num = GetTradePlayerItemInfo(i)
        if name then snap.gave[#snap.gave + 1] = { link = GetTradePlayerItemLink(i) or name, count = num or 1 } end
        local tname, _, tnum = GetTradeTargetItemInfo(i)
        if tname then snap.got[#snap.got + 1] = { link = GetTradeTargetItemLink(i) or tname, count = tnum or 1 } end
    end
    snap.gaveMoney = GetPlayerTradeMoney() or 0
    snap.gotMoney = GetTargetTradeMoney() or 0
    trade.snap = snap
    return snap
end

local function FinishTrade()
    if not trade then return end
    local s = trade.accepted or trade.snap
    trade = nil
    if not s then return end
    if #s.gave == 0 and #s.got == 0 and s.gaveMoney == 0 and s.gotMoney == 0 then return end
    ns:AddTrade({
        type = "trade",
        who = s.who,
        gave = s.gave, got = s.got,
        gaveMoney = s.gaveMoney, gotMoney = s.gotMoney,
    })
end

-- Backup confirmation when no "Trade complete" message arrived: a trade someone accepted counts as
-- done if your gold moved by the agreed amount, or the traded items left or arrived in your bags.
local function ConfirmTrade(t)
    if trade ~= t or not t or t.open or t.cancelled then return end -- already logged, reopened, or cancelled
    local s = t.accepted
    if not s then return end
    local done = false
    local delta = GetMoney() - (t.startMoney or GetMoney())
    if (s.gotMoney ~= 0 or s.gaveMoney ~= 0) and delta == s.gotMoney - s.gaveMoney then done = true end
    for _, it in ipairs(s.gave) do
        if s.counts and s.counts[it.link] and GetItemCount(it.link) < s.counts[it.link] then done = true end
    end
    for _, it in ipairs(s.got) do
        if s.counts and s.counts[it.link] and GetItemCount(it.link) > s.counts[it.link] then done = true end
    end
    if done then
        s.who = t.who
        FinishTrade()
    end
end

---------------------------------------------------------------------------
-- Auction House purchases
---------------------------------------------------------------------------
local pendingCommodity
local pendingBids = {}
local pendingPosts = {} -- auctions you just posted, waiting for the AH to confirm them

-- Fallback cost estimate from the loaded commodity listings (cheapest first).
local function EstimateCommodityCost(itemID, qty)
    local total, left = 0, qty
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r then
            local take = math.min(left, r.quantity or 0)
            total, left = total + take * r.unitPrice, left - take
            if left <= 0 then return total end
        end
    end
end

local function HookAuctionHouse()
    if ns.ahHooked or not C_AuctionHouse then return end
    ns.ahHooked = true

    hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(itemID, quantity)
        pendingCommodity = { itemID = itemID, qty = quantity, total = EstimateCommodityCost(itemID, quantity) }
    end)
    hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
        if not pendingCommodity or pendingCommodity.itemID ~= itemID then
            pendingCommodity = { itemID = itemID, qty = quantity, total = EstimateCommodityCost(itemID, quantity) }
        end
        pendingCommodity.qty = quantity
        pendingCommodity.confirmed = true
    end)
    -- Posting an auction: remember what was posted; it's logged once the AH confirms it.
    local DURATION_HOURS = { [1] = 12, [2] = 24, [3] = 48 }
    local function QueuePost(itemLoc, duration, quantity, unit, isCommodity)
        local ok, id = pcall(C_Item.GetItemID, itemLoc)
        local ok2, link = pcall(C_Item.GetItemLink, itemLoc)
        if not ok or not id then return end
        local deposit
        if isCommodity and C_AuctionHouse.CalculateCommodityDeposit then
            deposit = select(2, pcall(C_AuctionHouse.CalculateCommodityDeposit, id, duration, quantity))
        elseif C_AuctionHouse.CalculateItemDeposit then
            deposit = select(2, pcall(C_AuctionHouse.CalculateItemDeposit, itemLoc, duration, quantity))
        end
        pendingPosts[#pendingPosts + 1] = {
            type = "listed", itemID = id, link = ok2 and link or nil, name = ok2 and ns.LinkName(link) or nil,
            qty = quantity or 1, unit = unit, total = unit and (unit * (quantity or 1)) or nil,
            deposit = type(deposit) == "number" and deposit or nil,
            hours = DURATION_HOURS[duration], countBefore = GetItemCount(id), at = GetTime(),
        }
        -- Backup if the AH's "auction created" event doesn't arrive: log it if the items left your
        -- bags, otherwise the post failed (e.g. not enough gold for the deposit) and it's dropped.
        local post = pendingPosts[#pendingPosts]
        C_Timer.After(4, function()
            for i, p in ipairs(pendingPosts) do
                if p == post then
                    table.remove(pendingPosts, i)
                    if GetItemCount(p.itemID) < (p.countBefore or 0) then ns:LogPost(p) end
                    return
                end
            end
        end)
    end
    if C_AuctionHouse.PostCommodity then
        hooksecurefunc(C_AuctionHouse, "PostCommodity", function(item, duration, quantity, unitPrice)
            QueuePost(item, duration, quantity, unitPrice, true)
        end)
    end
    if C_AuctionHouse.PostItem then
        hooksecurefunc(C_AuctionHouse, "PostItem", function(item, duration, quantity, bid, buyout)
            -- Stack listings: the buyout is for the whole stack; store per unit like everything else.
            local q = math.max(1, quantity or 1)
            local unit = buyout and (buyout / q) or (bid and (bid / q))
            QueuePost(item, duration, quantity, unit, false)
        end)
    end

    hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, bidAmount)
        local info = C_AuctionHouse.GetAuctionInfoByID(auctionID)
        pendingBids[auctionID] = {
            link = info and info.itemLink,
            itemID = info and info.itemKey and info.itemKey.itemID,
            qty = info and info.quantity or 1,
            amount = bidAmount,
            isBuyout = info and info.buyoutAmount and bidAmount >= info.buyoutAmount,
        }
    end)
end

---------------------------------------------------------------------------
-- Mail: AH sales and won bids
---------------------------------------------------------------------------
local soldPattern
local function SoldSubjectPattern()
    if not soldPattern and AUCTION_SOLD_MAIL_SUBJECT then
        local p = AUCTION_SOLD_MAIL_SUBJECT:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
        soldPattern = "^" .. p:gsub("%%s", "(.+)") .. "$"
    end
    return soldPattern
end

-- "A buyer has been found for your auction of %s." -> pattern capturing the item name
local soldChatPattern
local function SoldChatPattern()
    if not soldChatPattern and ERR_AUCTION_SOLD_S then
        local p = ERR_AUCTION_SOLD_S:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
        soldChatPattern = "^" .. p:gsub("%%s", "(.+)") .. "$"
    end
    return soldChatPattern
end

-- An auction just sold (chat message). Log it straight away as a pending sale with an estimated
-- amount from your listing; the sale mail replaces it with the exact figures when you open a mailbox.
-- Records a sale the moment it's detected, as a pending "in mail" entry. Several detection paths can
-- report the same sale (chat message, AH notification, your auction list), so duplicates are dropped:
-- same auction ID, or the same item from a different path within a few seconds.
-- info = { itemID, name, link, qty, unit, auctionID, via }
function ns:AddPendingSale(info)
    if not self.pendingSales then return end
    local now = time()
    for _, p in ipairs(self.pendingSales) do
        -- Your auction list (exact quantities) confirming a sale already caught live since its last read
        if info.since and info.auctionID and p.auctionID == info.auctionID and p.t >= info.since then
            -- Exact total sold since the last read: put it on the first live report and drop the rest
            -- (several partial sales of one auction were each reported separately).
            p.qty = info.qty or p.qty
            if p.unit and p.qty then p.net = math.floor(p.unit * p.qty * (1 - ns:AHCut())) end
            for j = #self.pendingSales, 1, -1 do
                local o = self.pendingSales[j]
                if o ~= p and o.auctionID == info.auctionID and o.t >= info.since then table.remove(self.pendingSales, j) end
            end
            if self.OnTradesUpdated then self:OnTradesUpdated(p) end
            return
        end
        if info.auctionID and p.auctionID == info.auctionID and (p.qty == info.qty or not info.qty) then return end
        if now - p.t <= 10 and p.via ~= info.via
            and ((info.itemID and p.itemID == info.itemID) or (info.name and p.name == info.name)) then
            -- Same sale seen another way: fill in anything the first report lacked.
            p.qty, p.unit, p.auctionID = p.qty or info.qty, p.unit or info.unit, p.auctionID or info.auctionID
            if p.unit and p.qty then p.net = math.floor(p.unit * p.qty * (1 - ns:AHCut())) end
            return
        end
    end
    local rec = {
        type = "ahsell", pending = true, t = now, name = info.name, itemID = info.itemID, link = info.link,
        qty = info.qty, unit = info.unit, auctionID = info.auctionID, via = info.via, qtyChecked = true,
        net = info.unit and info.qty and math.floor(info.unit * info.qty * (1 - ns:AHCut())) or nil,
        char = UnitName("player"),
    }
    self.pendingSales[#self.pendingSales + 1] = rec
    self.Print("Sold: %s%s. It's in Trade History (in mail).", rec.link or rec.name or "?", rec.qty and (" x" .. rec.qty) or "")
    if self.OnTradesUpdated then self:OnTradesUpdated(rec) end
end

-- Your listing of an item (for the price and quantity of a sale reported only by name).
local function FindOwned(id, name)
    for _, a in ipairs(ns.owned and ns.owned.list or {}) do
        if not a.sold and ((id and a.id == id) or (name and a.link and ns.LinkName(a.link) == name)) then return a end
    end
end

-- A sale reported by a chat message (plain name or item link).
function ns:OnAuctionSold(raw, via)
    local itemName = raw:match("%[(.-)%]") or raw
    itemName = itemName:gsub("%s*%(%d+%)%s*$", ""):gsub("%s*x%d+%s*$", "") -- "Linen Cloth (20)" / "x20"
    local qty = tonumber(raw:match("%((%d+)%)") or raw:match("x(%d+)"))
    local id, link = ns.LinkID(raw), raw:match("|H") and raw or nil
    if not id then id, link = ResolveName(itemName) end
    local a = FindOwned(id, itemName)
    self:AddPendingSale({ itemID = id or (a and a.id), name = itemName, link = link or (a and a.link),
        qty = qty or (a and a.qty), unit = a and a.unit, auctionID = a and a.auctionID, via = via or "chat" })
end

-- Messages about auctions that weren't recognised are kept (last 20) for /aht debug.
function ns:NoteAuctionMessage(event, msg)
    self.db.auctionMsgLog = self.db.auctionMsgLog or {}
    local log = self.db.auctionMsgLog
    log[#log + 1] = date("%m/%d %H:%M:%S") .. "  " .. event .. ": " .. tostring(msg)
    while #log > 20 do table.remove(log, 1) end
end

-- Looser chat matching: a system message that mentions one of your listed items plus "sold" or "buyer".
local function LooseSaleMatch(msg)
    local l = msg:lower()
    if not (l:find("sold") or l:find("buyer") or l:find("purchased")) then return nil end
    for _, a in ipairs(ns.owned and ns.owned.list or {}) do
        local name = a.link and ns.LinkName(a.link) or ns:ItemName(a.id)
        if name and name ~= "" and l:find(name:lower(), 1, true) then return name end
    end
end

-- The sale mail arrived: drop the matching pending sale (oldest first).
local function ClearPendingSale(rec)
    for i, p in ipairs(ns.pendingSales or {}) do
        if (rec.itemID and p.itemID == rec.itemID) or (p.name and p.name == rec.name) then
            table.remove(ns.pendingSales, i)
            return
        end
    end
end

local function SplitCount(text)
    local name, n = text:match("^(.-) %((%d+)%)$")
    if name then return name, tonumber(n) end
    return text, 1
end

local function MailSeen(base, received)
    local b = math.floor(received / MAIL_BUCKET)
    for d = -1, 1 do
        if ns.mailSeen[base .. "|" .. (b + d)] then return true end
    end
    return false
end

function ns:ScanMail()
    if not self.trades then return end
    for i = 1, GetInboxNumItems() do
        local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
        if subject and daysLeft then
            local received = time() - math.floor((AH_MAIL_DAYS - daysLeft) * 86400)
            local base = (subject or "") .. "|" .. (money or 0)
            if not MailSeen(base, received) then
                local rec
                -- Returns: type, item, player, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count
                local invType, itemName, player, bid, buyout, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(i)
                -- The subject ("Auction successful: Hot Spices (20)") is the most reliable quantity.
                if subject:match("%((%d+)%)%s*$") or not count or count < 1 then count = SubjectCount(subject) end
                if invType == "seller" then
                    local id, link = ResolveName(itemName)
                    rec = {
                        type = "ahsell", t = received, name = itemName, itemID = id, link = link,
                        qty = count or 1, total = bid, cut = consignment, deposit = deposit,
                        net = (money and money > 0) and money or ((bid or 0) - (consignment or 0) + (deposit or 0)),
                        who = player,
                    }
                elseif invType == "buyer" and bid and (not buyout or buyout == 0 or bid < buyout) then
                    -- Won by bidding (buyouts are logged at purchase time instead).
                    local id, link = ResolveName(itemName)
                    rec = { type = "ahwon", t = received, name = itemName, itemID = id, link = link,
                        qty = count or 1, total = bid, who = player }
                elseif not invType and money and money > 0 and SoldSubjectPattern() then
                    -- Invoice not loaded yet: fall back to the "Auction successful" subject line.
                    local what = subject:match(soldPattern)
                    if what then
                        local name, n = SplitCount(what)
                        local id, link = ResolveName(name)
                        rec = { type = "ahsell", t = received, name = name, itemID = id, link = link,
                            qty = n, net = money }
                    end
                end
                if rec then
                    self.mailSeen[base .. "|" .. math.floor(received / MAIL_BUCKET)] = received
                    if rec.type == "ahsell" then ClearPendingSale(rec) end
                    self:AddTrade(rec)
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({
    "PLAYER_LOGIN", "TRADE_SHOW", "TRADE_CLOSED", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED",
    "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE", "UI_INFO_MESSAGE", "UI_ERROR_MESSAGE", "CHAT_MSG_SYSTEM",
    "AUCTION_HOUSE_SHOW", "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
    "AUCTION_HOUSE_PURCHASE_COMPLETED", "MAIL_INBOX_UPDATE", "AUCTION_HOUSE_AUCTION_CREATED",
    "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", "AUCTION_HOUSE_SHOW_NOTIFICATION",
}) do ev:RegisterEvent(e) end

local mailTimer
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" or event == "AUCTION_HOUSE_SHOW" then
        HookAuctionHouse()

    elseif event == "TRADE_SHOW" then
        trade = { open = true, startMoney = GetMoney() }
        trade.who = UnitName("NPC") or (TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText()) or "?"
        Snapshot()
    elseif event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_TARGET_ITEM_CHANGED" or event == "TRADE_MONEY_CHANGED" then
        Snapshot()
    elseif event == "TRADE_ACCEPT_UPDATE" then
        -- Keep the last snapshot taken while someone had accepted: that's the final contents.
        -- (Changing anything un-accepts both sides, which fires this again with 0, 0.)
        local playerAccepted, targetAccepted = ...
        local snap = Snapshot()
        if snap then
            if playerAccepted == 1 or targetAccepted == 1 then
                -- Remember bag counts of the traded items, to confirm the trade later if needed.
                snap.counts = {}
                for _, it in ipairs(snap.gave) do snap.counts[it.link] = GetItemCount(it.link) end
                for _, it in ipairs(snap.got) do snap.counts[it.link] = GetItemCount(it.link) end
                trade.accepted = snap
            else
                trade.accepted = nil
            end
        end
    elseif event == "TRADE_CLOSED" then
        if trade then
            trade.open = false
            -- If the "Trade complete" message never shows up (wording differs, or it goes to chat
            -- instead), confirm the trade from what actually changed in your gold and bags.
            local t = trade
            C_Timer.After(1.5, function() ConfirmTrade(t) end)
        end
    elseif event == "UI_INFO_MESSAGE" or event == "UI_ERROR_MESSAGE" or event == "CHAT_MSG_SYSTEM" then
        local a, b = ...
        local msg = (event == "CHAT_MSG_SYSTEM") and a or b
        local id = (event ~= "CHAT_MSG_SYSTEM") and a or nil
        local soldPat = msg and SoldChatPattern()
        local soldItem = soldPat and msg:match(soldPat)
        if soldItem then
            ns:OnAuctionSold(soldItem, "chat")
            return
        end
        if msg and event == "CHAT_MSG_SYSTEM" then
            local loose = LooseSaleMatch(msg)
            if loose then
                ns:OnAuctionSold(loose, "chat")
                return
            end
            local l = msg:lower()
            if l:find("auction") or l:find("sold") or l:find("buyer") then ns:NoteAuctionMessage(event, msg) end
        end
        if not trade then return end
        local complete = msg == ERR_TRADE_COMPLETE
            or (id and LE_GAME_ERR_TRADE_COMPLETE and id == LE_GAME_ERR_TRADE_COMPLETE)
        if complete then
            if trade.accepted then trade.accepted.who = trade.who end
            if trade.snap then trade.snap.who = trade.who end
            FinishTrade()
        elseif msg and (msg == ERR_TRADE_CANCELLED or msg == ERR_TRADE_BAG_FULL or msg == ERR_TRADE_TARGET_BAG_FULL
            or msg == ERR_TRADE_MAX_COUNT_EXCEEDED or msg == ERR_TRADE_TARGET_MAX_COUNT_EXCEEDED
            or msg == ERR_TRADE_TOO_FAR or msg == ERR_TRADE_BLOCKED_S) then
            trade.cancelled = true
        end

    elseif event == "COMMODITY_PRICE_UPDATED" then
        local _, total = ...
        if pendingCommodity and total then pendingCommodity.total = total end
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        local p = pendingCommodity
        pendingCommodity = nil
        if p and p.itemID then
            local _, link = GetItemInfo(p.itemID)
            ns:AddTrade({ type = "ahbuy", itemID = p.itemID, link = link, name = ns.LinkName(link),
                qty = p.qty or 1, total = p.total })
        end
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        pendingCommodity = nil
    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
        local auctionID = ...
        local p = pendingBids[auctionID]
        pendingBids[auctionID] = nil
        if p and p.isBuyout then
            ns:AddTrade({ type = "ahbuy", itemID = p.itemID, link = p.link, name = ns.LinkName(p.link),
                qty = p.qty, total = p.amount })
        end

    elseif event == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION" or event == "AUCTION_HOUSE_SHOW_NOTIFICATION" then
        -- The AH's own pop-up notifications ("Your auction sold" etc.)
        local note, text, auctionID = ...
        local SOLD = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionSold
        if SOLD and note == SOLD then
            local a
            for _, o in ipairs(ns.owned and ns.owned.list or {}) do
                if auctionID and o.auctionID == auctionID then a = o end
            end
            if a then
                -- The notification doesn't say how many sold (a buyer can take part of a stack), so the
                -- quantity stays unknown until your auction list is re-read and shows how much the stack shrank.
                local textQty = type(text) == "string" and tonumber(text:match("%((%d+)%)") or text:match("x(%d+)"))
                ns:AddPendingSale({ itemID = a.id, link = a.link, name = a.link and ns.LinkName(a.link) or ns:ItemName(a.id),
                    qty = textQty, unit = a.unit, auctionID = auctionID, via = "notify" })
                if ns.ahOpen and ns.QueryOwned then
                    if ns.ownedRefresh then ns.ownedRefresh:Cancel() end
                    ns.ownedRefresh = C_Timer.NewTimer(2, function() ns.ownedRefresh = nil; ns:QueryOwned() end)
                end
            elseif type(text) == "string" and text ~= "" then
                ns:OnAuctionSold(text, "notify")
            end
        else
            ns:NoteAuctionMessage(event, tostring(note) .. " " .. tostring(text))
        end

    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        -- Posts are confirmed in the order they were made.
        local p = table.remove(pendingPosts, 1)
        if p then ns:LogPost(p) end

    elseif event == "MAIL_INBOX_UPDATE" then
        if mailTimer then mailTimer:Cancel() end
        mailTimer = C_Timer.NewTimer(0.5, function() mailTimer = nil; ns:ScanMail() end)
    end
end)

---------------------------------------------------------------------------
-- CSV export
---------------------------------------------------------------------------
local function ItemsText(list)
    local parts = {}
    for _, it in ipairs(list or {}) do
        parts[#parts + 1] = ns.LinkName(it.link) .. " x" .. (it.count or 1)
    end
    return table.concat(parts, "; ")
end
ns.TradeItemsText = ItemsText

function ns:BuildTradesCSV(records)
    local out = { "type,datetime,timestamp,character,other_player,item,quantity,price_copper,ah_cut_copper,net_copper,gave_items,got_items,gave_money_copper,got_money_copper" }
    local function q(s) return '"' .. tostring(s or ""):gsub('"', '""') .. '"' end
    for _, r in ipairs(records or self.trades) do
        out[#out + 1] = table.concat({
            r.type, date("%Y-%m-%d %H:%M:%S", r.t), r.t, q(r.char), q(r.who),
            q(r.link and ns.LinkName(r.link) or r.name), r.qty or "", r.total or "", r.cut or "", r.net or "",
            q(ItemsText(r.gave)), q(ItemsText(r.got)), r.gaveMoney or "", r.gotMoney or "",
        }, ",")
    end
    return table.concat(out, "\n")
end
