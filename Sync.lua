-- AH Price Tracker: share scans with everyone else running the addon
--
-- Every AH scan you make is sent (as a small hidden addon message) to your guild and to a shared hidden
-- chat channel. Everyone running the addon on the same auction house merges what they receive into
-- their own data: price history for tracked items, Flip Finder prices, vendor prices, and the sales
-- timeline. When someone logs in, a peer who is already online sends them what they missed.
--
-- Messages carry no character names: each account gets a random sync ID. Sender names are only used
-- locally for /aht sync ignore.
local ADDON, ns = ...

local PREFIX    = "AHPT2" -- v1.5.1: older versions sent stack totals as unit prices; ignore them
local CHANNEL   = "AHPTForeverSync"
local PROTO     = 1
local BULK_SECS = 3 * 86400  -- catch-up sync covers the last 3 days
local BULK_MAX  = 600        -- records per catch-up
local SEND_GAP  = 1.0        -- seconds between messages (Blizzard throttles addon messages per prefix)
local SENDER_CAP = 900       -- records accepted per sender per hour
local Now = GetServerTime or time

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function enc(n)
    if not n or n == false then return "" end
    n = math.floor(n)
    if n == 0 then return "0" end
    local neg = n < 0
    if neg then n = -n end
    local s = ""
    while n > 0 do
        local r = n % 36
        s = B36:sub(r + 1, r + 1) .. s
        n = (n - r) / 36
    end
    return neg and ("-" .. s) or s
end
local function dec(s)
    if not s or s == "" then return nil end
    return tonumber(s, 36)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
function ns:SyncID()
    if not self.db.syncID then
        local t = {}
        for i = 1, 8 do local r = math.random(1, 36); t[i] = B36:sub(r, r) end
        self.db.syncID = table.concat(t)
    end
    return self.db.syncID
end

function ns:InitSync()
    if self.settings.sync == nil then self.settings.sync = true end
    if self.settings.syncChannel == nil then self.settings.syncChannel = true end
    self.db.syncIgnore = self.db.syncIgnore or {}
    self.realmData.syncPeers = self.realmData.syncPeers or {}
    self.syncStats = { sent = 0, received = 0, peers = {}, perSender = {} }
    self.sendQueue, self.bulkQueue = {}, {}
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    self:SyncID()
    if self.settings.sync then
        C_Timer.After(8, function() ns:JoinSyncChannel() end)
        C_Timer.After(15, function() ns:SendHello() end)
    end
    C_Timer.NewTicker(SEND_GAP, function() ns:PumpQueue() end)
end

function ns:SyncChannelID()
    local id = GetChannelName(CHANNEL)
    return (id and id > 0) and id or nil
end

function ns:JoinSyncChannel()
    if not (self.settings.sync and self.settings.syncChannel) then return end
    if not self:SyncChannelID() then JoinTemporaryChannel(CHANNEL) end
    -- Keep the channel out of every chat window.
    C_Timer.After(2, function()
        for i = 1, NUM_CHAT_WINDOWS or 10 do
            local frame = _G["ChatFrame" .. i]
            if frame and ChatFrame_RemoveChannel then pcall(ChatFrame_RemoveChannel, frame, CHANNEL) end
        end
    end)
end

function ns:LeaveSyncChannel()
    if self:SyncChannelID() then LeaveChannelByName(CHANNEL) end
end

---------------------------------------------------------------------------
-- Sending (throttled queue: live messages first, then catch-up data)
---------------------------------------------------------------------------
local function Targets()
    local out = {}
    if IsInGuild() then out[#out + 1] = { "GUILD" } end
    local ch = ns.settings.syncChannel and ns:SyncChannelID()
    if ch then out[#out + 1] = { "CHANNEL", ch } end
    return out
end

function ns:Send(msg, bulk)
    if not self.settings.sync then return end
    local q = bulk and self.bulkQueue or self.sendQueue
    if #q > 2000 then return end
    q[#q + 1] = msg
end

function ns:PumpQueue()
    local q = (#self.sendQueue > 0) and self.sendQueue or self.bulkQueue
    local msg = q[1]
    if not msg then return end
    local targets = Targets()
    if #targets == 0 then
        if #self.bulkQueue > 0 and q == self.bulkQueue then wipe(self.bulkQueue) end
        return
    end
    local ok = true
    for _, t in ipairs(targets) do
        local r = C_ChatInfo.SendAddonMessage(PREFIX, msg, t[1], t[2])
        -- Older clients return true/false, newer ones Enum.SendAddonMessageResult (0 = success).
        if r == false or (type(r) == "number" and r ~= 0) then ok = false end
    end
    if ok or (self.sendRetry or 0) >= 5 then
        table.remove(q, 1)
        self.sendRetry = 0
        self.syncStats.sent = self.syncStats.sent + 1
    else
        self.sendRetry = (self.sendRetry or 0) + 1 -- throttled or restricted (e.g. in an encounter): retry later
    end
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
-- S;market;src;id;t;min;market;total;complete;p:q,p:q,...
-- `key` is the auction house's market key (see ns:MarketKey); defaults to the house you're using.
local function EncodeSnap(id, s, key)
    local lv = {}
    for i = 1, #s.levels, 2 do lv[#lv + 1] = enc(s.levels[i]) .. ":" .. enc(s.levels[i + 1]) end
    return table.concat({ "S", key or ns:MarketKey(), s.src or "", enc(id), enc(s.t), enc(s.min or nil),
        enc(s.market or nil), enc(s.total), s.complete and "1" or "0", table.concat(lv, ",") }, ";")
end

-- B;market;src;id;t;qty   (an AH purchase, so others don't count it as market demand twice)
local function EncodeBuy(id, t, qty, src, key)
    return table.concat({ "B", key or ns:MarketKey(), src, enc(id), enc(t), enc(qty) }, ";")
end

function ns:ShareSnapshot(id, snap)
    if not self.settings.sync then return end
    -- A scan's results arrive in several pieces; send once it has settled.
    self.pendingShare = self.pendingShare or {}
    self.pendingShare[id .. "@" .. self:MarketKey()] = { id, snap, self:MarketKey() }
    if self.shareTimer then return end
    self.shareTimer = C_Timer.NewTimer(5, function()
        ns.shareTimer = nil
        for _, p in pairs(ns.pendingShare) do ns:Send(EncodeSnap(p[1], p[2], p[3])) end
        wipe(ns.pendingShare)
    end)
end

function ns:ShareBuy(rec)
    if not (self.settings.sync and rec.itemID) then return end
    self:Send(EncodeBuy(rec.itemID, Now(), rec.qty or 1, self:SyncID()))
end

function ns:ShareVendor(id, price)
    if not self.settings.sync then return end
    self:Send(table.concat({ "V", enc(id), enc(price) }, ";"), true)
end

-- N;key;map;x;y;type;name;title   (a town service location; x/y in 1/10000ths of the map)
local function EncodeTown(key, n)
    local clean = function(s) return (s or ""):gsub(";", ","):sub(1, 40) end
    local k = type(key) == "number" and enc(key) or ("~" .. key)
    return table.concat({ "N", k, enc(n.map), enc(math.floor(n.x * 10000 + 0.5)), enc(math.floor(n.y * 10000 + 0.5)),
        n.type, clean(n.name), clean(n.title) }, ";")
end

function ns:ShareTownNpc(key, n)
    if not self.settings.sync then return end
    self:Send(EncodeTown(key, n), true)
end

function ns:OnTownMessage(f, src)
    local rawKey = f[2] or ""
    local key = rawKey:sub(1, 1) == "~" and rawKey:sub(2) or dec(rawKey)
    local map, x, y, stype = dec(f[3]), dec(f[4]), dec(f[5]), f[6]
    if not (key and map and x and y and stype and ns.TOWN_TYPE and ns.TOWN_TYPE[stype]) then return end
    if x <= 0 or x >= 10000 or y <= 0 or y >= 10000 then return end
    local name = (f[7] and f[7] ~= "") and f[7] or nil
    local title = (f[8] and f[8] ~= "") and f[8] or nil
    self:SaveTownNpc(key, { type = stype, map = map, x = x / 10000, y = y / 10000, name = name, title = title,
        t = time() }, src or "shared")
end

-- W;camp;service;from;to   (a sighting of the rotating goblin NPC at a trade camp, see Camp.lua)
local function EncodeCamp(camp, r)
    return table.concat({ "W", camp, r[1], enc(r[2]), enc(r[3]) }, ";")
end

function ns:ShareCampRun(camp, r)
    if not self.settings.sync then return end
    self:Send(EncodeCamp(camp, r))
end

function ns:ShareCrafted(id)
    if not self.settings.sync then return end
    self:Send("C;" .. enc(id), true)
end

---------------------------------------------------------------------------
-- Catch-up: H = hello (what I have), R = "I'm answering", then S/B records
---------------------------------------------------------------------------
function ns:NewestShared()
    local newest = 0
    for _, s in pairs(self.sales or {}) do
        local last = s.snaps[#s.snaps]
        if last and last.t > newest then newest = last.t end
    end
    return newest
end

-- Hello for the house you're using (at login: your faction's house).
function ns:SendHello()
    if not self.settings.sync then return end
    local since = math.max(self:NewestShared(), Now() - BULK_SECS)
    self:Send(table.concat({ "H", ns:MarketKey(), enc(PROTO), enc(since) }, ";"))
end

function ns:StartCatchUp(since, house)
    -- Several peers may hear the same hello; wait a random moment and stand down if someone else answers.
    if self.catchUpTimer then return end
    local delay = 2 + math.random() * 6
    self.catchUpSince = since
    self.catchUpHouse = house or "home"
    self.catchUpTimer = C_Timer.NewTimer(delay, function()
        ns.catchUpTimer = nil
        local from, hk = ns.catchUpSince, ns.catchUpHouse
        if not from then return end
        local key = ns:MarketKey(hk)
        ns:Send(table.concat({ "R", key, enc(from) }, ";"))
        local recs = {}
        ns:WithHouse(hk, function()
            for id, s in pairs(ns.sales or {}) do
                for _, sn in ipairs(s.snaps) do
                    if sn.t > from then recs[#recs + 1] = { sn.t, EncodeSnap(id, sn, key) } end
                end
            end
            for id, list in pairs(ns.syncBuys or {}) do
                for _, b in ipairs(list) do
                    if b[1] > from then recs[#recs + 1] = { b[1], EncodeBuy(id, b[1], b[2], b[3] or "?", key) } end
                end
            end
        end)
        table.sort(recs, function(a, b) return a[1] > b[1] end) -- newest first
        -- Town service locations you found yourself (others pass on their own)
        local town = {}
        for tkey, n in pairs(ns.townNpcs or {}) do
            if not n.src then town[#town + 1] = EncodeTown(tkey, n) end
        end
        for i = 1, math.min(#town, 300) do ns:Send(town[i], true) end
        -- Camp sightings from the last two weeks (the schedule needs history, not just today)
        local camp = ns.CampRunsSince and ns:CampRunsSince(Now() - 14 * 86400) or {}
        for i = 1, math.min(#camp, 200) do ns:Send(EncodeCamp(camp[i][1], camp[i][2]), true) end
        for i = 1, math.min(#recs, BULK_MAX) do ns:Send(recs[i][2], true) end
    end)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function Plausible(t, price, qty)
    local now = Now()
    if not t or t < now - BULK_SECS - 3600 or t > now + 600 then return false end
    if price and (price < 1 or price > 1e10) then return false end
    if qty and (qty < 0 or qty > 1e7) then return false end
    return true
end

function ns:OnSyncMessage(msg, sender)
    if not self.settings.sync or not self.sales then return end
    local short = Ambiguate(sender or "", "none")
    if short == UnitName("player") then return end
    if self.db.syncIgnore[short:lower()] then return end

    local f = { strsplit(";", msg) }
    local kind = f[1]
    if kind == "V" then
        local id, price = dec(f[2]), dec(f[3])
        if id and price and price > 0 and price < 1e8 and self.vendor and not self.vendor[id] then
            self.vendor[id] = { price = price, source = "shared" }
            if self.OnFlipsUpdated then self:OnFlipsUpdated() end
        end
        return
    end
    if kind == "N" then -- town service locations are the same for every auction house
        self:OnTownMessage(f, "shared")
        return
    end
    if kind == "W" then -- camp sightings are the same for every auction house
        if self.OnCampMessage then self:OnCampMessage(f[2], f[3], dec(f[4]), dec(f[5])) end
        return
    end
    if kind == "C" then
        local id = dec(f[2])
        if id and id > 0 and id < 1e7 and self.MarkCrafted and self:MarkCrafted(id, false) then
            if self.OnFlipsUpdated then self:OnFlipsUpdated() end
        end
        return
    end
    -- Which of your auction houses this is for: your faction's, the neutral goblin one (kept even before
    -- your first visit, so it has data when you get there), or another you've used. Others are dropped.
    local hk = self:HouseForKey(f[2])
    if not hk then return end

    -- Per-sender cap so one bad or buggy client can't flood the data.
    local hour = math.floor(GetTime() / 3600)
    local ps = self.syncStats.perSender[short]
    if not ps or ps.hour ~= hour then ps = { hour = hour, n = 0 }; self.syncStats.perSender[short] = ps end
    ps.n = ps.n + 1
    if ps.n > SENDER_CAP then return end

    self.syncStats.received = self.syncStats.received + 1
    self.syncStats.peers[short] = GetTime()
    self.realmData.syncPeers[short] = time()
    self:HouseData(hk) -- make sure it exists
    self:WithHouse(hk, self.OnSyncRecord, self, f, kind, hk)
end

function ns:OnSyncRecord(f, kind, hk)
    if kind == "H" then
        local since = dec(f[4])
        local haveTown = (self.townNpcs and next(self.townNpcs) ~= nil) or (self.campRuns and next(self.campRuns) ~= nil)
        if since and (self:NewestShared() > since or haveTown) then self:StartCatchUp(since, hk) end
    elseif kind == "R" then
        -- Someone else is answering a hello; let them, unless they're sending less than we would.
        local from = dec(f[3])
        if self.catchUpTimer and self.catchUpHouse == hk and from and from <= (self.catchUpSince or 0) then
            self.catchUpTimer:Cancel()
            self.catchUpTimer = nil
        end
    elseif kind == "S" then
        local src, id, t = f[3], dec(f[4]), dec(f[5])
        local min, market, total = dec(f[6]), dec(f[7]), dec(f[8]) or 0
        if not (id and t and src and src ~= "" and src ~= self:SyncID()) then return end
        if not Plausible(t, min, total) then return end
        local levels = {}
        for pq in (f[10] or ""):gmatch("[^,]+") do
            local p, q = pq:match("^(%w+):(%w+)$")
            p, q = dec(p), dec(q)
            if p and q and #levels < ns.SNAP_LEVELS * 2 and Plausible(t, p, q) then
                levels[#levels + 1] = p
                levels[#levels + 1] = q
            end
        end
        local snap = { t = t, levels = levels, complete = f[9] == "1", min = min or false,
            market = market, total = total, src = src }
        if self:AddSnapshot(id, snap) then self:MergeSharedPrice(id, snap) end
    elseif kind == "B" then
        local src, id, t, qty = f[3], dec(f[4]), dec(f[5]), dec(f[6])
        if not (id and t and qty and src and src ~= self:SyncID()) or not Plausible(t, nil, qty) then return end
        local list = self.syncBuys[id] or {}
        self.syncBuys[id] = list
        for _, b in ipairs(list) do
            if b[1] == t and b[3] == src then return end -- already have it
        end
        list[#list + 1] = { t, qty, src }
        self.salesCache[id] = nil
    end
end

-- A shared scan also feeds price history (tracked items) and Flip Finder prices.
function ns:MergeSharedPrice(id, snap)
    local entry = self.items and self.items[id]
    if entry then
        local h = entry.history
        local near = false
        for i = #h, 1, -1 do
            if h[i][1] < snap.t - 120 then break end
            if math.abs(h[i][1] - snap.t) < 60 then near = true; break end
        end
        if not near then
            local point = { snap.t, snap.min or false, snap.market or snap.min or false, snap.total, shared = true }
            local pos = #h + 1
            while pos > 1 and h[pos - 1][1] > snap.t do pos = pos - 1 end
            table.insert(h, pos, point)
            if #h > self.settings.maxPoints then table.remove(h, 1) end
            self:OnDataUpdated(id)
        end
    end
    if self.vendor and self.vendor[id] and self.flipPrices then
        local fp = self.flipPrices[id]
        if not fp or fp.t < snap.t then
            self.flipPrices[id] = { min = snap.min or false, qty = snap.total, t = snap.t, shared = true }
            if self.OnFlipsUpdated then self:OnFlipsUpdated() end
        end
    end
end

---------------------------------------------------------------------------
-- Status / commands
---------------------------------------------------------------------------
function ns:SyncStatus()
    local online = 0
    for _, t in pairs(self.syncStats.peers) do if GetTime() - t < 3600 then online = online + 1 end end
    local known = 0
    for _ in pairs(self.realmData.syncPeers) do known = known + 1 end
    self.Print("Sync is %s (%s). Market: %s.", self.settings.sync and "|cff40ff40on|r" or "|cffff5050off|r",
        (self.settings.syncChannel and "guild + shared channel" or "guild only"), ns.MarketLabel(self:MarketKey()))
    self.Print("Players heard from: %d in the last hour, %d ever. Messages sent %d, received %d. Queue: %d live, %d catch-up.",
        online, known, self.syncStats.sent, self.syncStats.received, #self.sendQueue, #self.bulkQueue)
end

function ns:SyncCommand(rest)
    local sub, arg = (rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
    sub = sub:lower()
    if sub == "on" then
        self.settings.sync = true
        self:JoinSyncChannel()
        C_Timer.After(3, function() ns:SendHello() end)
        self.Print("Sync on.")
    elseif sub == "off" then
        self.settings.sync = false
        self:LeaveSyncChannel()
        wipe(self.sendQueue); wipe(self.bulkQueue)
        self.Print("Sync off. Nothing is sent or received.")
    elseif sub == "guildonly" then
        self.settings.syncChannel = not self.settings.syncChannel
        if self.settings.syncChannel then self:JoinSyncChannel() else self:LeaveSyncChannel() end
        self.Print(self.settings.syncChannel and "Sharing with your guild and everyone else running the addon." or "Sharing with your guild only.")
    elseif sub == "ignore" and arg ~= "" then
        self.db.syncIgnore[arg:lower()] = true
        self.Print("Ignoring sync data from %s.", arg)
    elseif sub == "unignore" and arg ~= "" then
        self.db.syncIgnore[arg:lower()] = nil
        self.Print("No longer ignoring %s.", arg)
    else
        self:SyncStatus()
        print("  /aht sync on|off - share scans with other players running the addon")
        print("  /aht sync guildonly - toggle between guild only and everyone")
        print("  /aht sync ignore|unignore <name> - drop data from a player")
    end
end

-- Your AH purchases are shared so other players don't count them as market demand.
hooksecurefunc(ns, "AddTrade", function(self, rec)
    if rec and rec.type == "ahbuy" and self.syncStats then self:ShareBuy(rec) end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(_, _, prefix, msg, _, sender)
    if ns.syncStats and prefix == PREFIX then ns:OnSyncMessage(msg, sender) end
end)
