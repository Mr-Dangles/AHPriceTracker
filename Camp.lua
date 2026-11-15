-- AH Price Tracker: the rotating goblin service spot at the trade camps
--
-- The Durotar Supply and Logistics camp (just west of the Crossroads, the Barrens) and Three Corners
-- (Redridge) have one spot that takes turns between three Steamwheedle NPCs:
--   Auctioneer Quickcoin (neutral auction house), Steamwheedle Courier (mail), Uninspected Shipment (bank).
-- Nobody has published when each one is there, so the addon records it: every time you (or another
-- addon user) see one of them, and builds a time-of-day schedule from the sightings.
local ADDON, ns = ...

local Now = GetServerTime or time
ns.CAMP_SERVICES = {
    { key = "auction", npc = 258878, label = "Auctioneer", who = "Auctioneer Quickcoin", color = { 1, 0.78, 0.2 } },
    { key = "bank", npc = 258880, label = "Bank", who = "Uninspected Shipment", color = { 0.35, 0.65, 1 } },
    { key = "mail", npc = 258879, label = "Mail", who = "Steamwheedle Courier", color = { 0.4, 0.9, 0.4 } },
}
local BY_NPC, BY_KEY = {}, {}
for _, s in ipairs(ns.CAMP_SERVICES) do BY_NPC[s.npc] = s; BY_KEY[s.key] = s end
ns.CAMP_SERVICE = BY_KEY

-- Camps by world map (Classic map IDs, as Forever uses).
ns.CAMPS = {
    { key = "barrens", map = 1413, label = "Crossroads camp (the Barrens)", side = "Horde" },
    { key = "redridge", map = 1433, label = "Three Corners (Redridge)", side = "Alliance" },
}
local CAMP_BY_MAP, CAMP_BY_KEY = {}, {}
for _, c in ipairs(ns.CAMPS) do CAMP_BY_MAP[c.map] = c; CAMP_BY_KEY[c.key] = c end

local MERGE_GAP = 10 * 60        -- sightings this close together belong to the same stay
local KEEP = 28 * 86400          -- keep four weeks of sightings
local SLOT = 30 * 60             -- schedule resolution
local SLOTS = 86400 / SLOT

---------------------------------------------------------------------------
-- Storage: runs of { service, from, to, src } per camp ("me" or "shared")
---------------------------------------------------------------------------
function ns:InitCamp()
    self.realmData.campRuns = self.realmData.campRuns or {}
    self.campRuns = self.realmData.campRuns
    local cutoff = Now() - KEEP
    for key, list in pairs(self.campRuns) do
        local keep = {}
        for _, r in ipairs(list) do if r[3] >= cutoff then keep[#keep + 1] = r end end
        self.campRuns[key] = keep
    end
    if self.settings.campAlerts == nil then self.settings.campAlerts = true end
    -- Start from what Town services already learned (the last time you used each one there).
    if not self.realmData.campSeeded then
        self.realmData.campSeeded = true
        for id, s in pairs(BY_NPC) do
            local n = self.townNpcs and self.townNpcs[id]
            local c = n and n.map and CAMP_BY_MAP[n.map]
            if c and n.t and not n.src then self:AddCampRun(c.key, s.key, n.t, n.t, "me") end
        end
    end
    C_Timer.After(5, function() ns:UpdateCampTicker() end)
end

-- Record that `svc` was at `camp` from t1 to t2. Returns the run and whether it's news.
function ns:AddCampRun(camp, svc, t1, t2, src)
    if not (self.campRuns and BY_KEY[svc] and camp) then return end
    local list = self.campRuns[camp] or {}
    self.campRuns[camp] = list
    for _, r in ipairs(list) do
        if r[1] == svc and t1 <= r[3] + MERGE_GAP and t2 >= r[2] - MERGE_GAP then
            local grew = t2 > r[3] or t1 < r[2]
            r[2], r[3] = math.min(r[2], t1), math.max(r[3], t2)
            if src == "me" then r[4] = "me" end
            if grew then self:OnCampUpdated() end
            return r, false
        end
    end
    local r = { svc, t1, t2, src or "me" }
    list[#list + 1] = r
    table.sort(list, function(a, b) return a[2] < b[2] end)
    self:OnCampUpdated()
    return r, true
end

---------------------------------------------------------------------------
-- Seeing the NPCs: talking to them, mouseover, target, interact key, nameplates
---------------------------------------------------------------------------
local function NpcID(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or not guid or (issecretvalue and issecretvalue(guid)) then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" then return nil end
    return tonumber(id)
end

local function PlayerCamp()
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local c = map and CAMP_BY_MAP[map]
    if c then return c.key end
    return map and ("map" .. map) or nil -- another spot we don't know about yet
end

local lastShare = {}
function ns:CheckCampUnit(unit)
    if not self.campRuns then return end
    local id = NpcID(unit)
    local s = id and BY_NPC[id]
    if not s then return end
    local camp = PlayerCamp()
    if not camp then return end
    local t = Now()
    local r = self:AddCampRun(camp, s.key, t, t, "me")
    -- Share at most every 2 minutes per service while you stand there.
    local k = camp .. s.key
    if r and self.ShareCampRun and (not lastShare[k] or t - lastShare[k] >= 120) then
        lastShare[k] = t
        self:ShareCampRun(camp, r)
    end
end

function ns:CheckCampNearby()
    for _, u in ipairs({ "softinteract", "target", "mouseover", "npc" }) do self:CheckCampUnit(u) end
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if u then self:CheckCampUnit(u) end
        end
    end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED", "NAME_PLATE_UNIT_ADDED",
    "PLAYER_SOFT_INTERACT_CHANGED", "AUCTION_HOUSE_SHOW", "BANKFRAME_OPENED", "MAIL_SHOW", "GOSSIP_SHOW",
    "MERCHANT_SHOW", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, arg)
    if not ns.campRuns then return end
    if event == "UPDATE_MOUSEOVER_UNIT" then ns:CheckCampUnit("mouseover")
    elseif event == "PLAYER_TARGET_CHANGED" then ns:CheckCampUnit("target")
    elseif event == "NAME_PLATE_UNIT_ADDED" then if arg then ns:CheckCampUnit(arg) end
    elseif event == "PLAYER_SOFT_INTERACT_CHANGED" then ns:CheckCampUnit("softinteract")
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then ns:UpdateCampTicker()
    else ns:CheckCampUnit("npc") end
end)

-- While you're in a camp's zone, look around every 15 seconds so a long stay keeps its run growing.
function ns:UpdateCampTicker()
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local inCamp = map and CAMP_BY_MAP[map]
    if inCamp and not self.campTicker then
        self.campTicker = C_Timer.NewTicker(15, function() ns:CheckCampNearby() end)
    elseif not inCamp and self.campTicker then
        self.campTicker:Cancel()
        self.campTicker = nil
    end
end

---------------------------------------------------------------------------
-- Sharing (via Sync.lua): W;camp;service;from;to
---------------------------------------------------------------------------
function ns:OnCampMessage(camp, svc, t1, t2)
    if not (camp and BY_KEY[svc] and t1 and t2) or #camp > 20 or camp:find("[^%w]") then return end
    local now = Now()
    if t1 > t2 or t2 > now + 600 or t2 < now - KEEP or t2 - t1 > 12 * 3600 then return end
    local r, new = self:AddCampRun(camp, svc, t1, t2, "shared")
    -- Heads-up: the neutral auctioneer just turned up at your faction's camp.
    if svc == "auction" and self.settings.campAlerts and now - t2 < 300 then
        local c = CAMP_BY_KEY[camp]
        if c and c.side == UnitFactionGroup("player") and (not self.campAlerted or now - self.campAlerted > 1800) then
            self.campAlerted = now
            self.Print("Auctioneer Quickcoin is at the %s right now (seen by another addon user).", c.label)
        end
    end
end

-- Recent runs for a catch-up: newest first.
function ns:CampRunsSince(since)
    local out = {}
    for camp, list in pairs(self.campRuns or {}) do
        for _, r in ipairs(list) do if r[3] > since then out[#out + 1] = { camp, r } end end
    end
    table.sort(out, function(a, b) return a[2][3] > b[2][3] end)
    return out
end

---------------------------------------------------------------------------
-- Schedule: for each half hour of the day, on how many days each service was seen
---------------------------------------------------------------------------
local function SlotOf(t)
    local d = date("*t", t)
    return math.floor((d.hour * 3600 + d.min * 60) / SLOT) + 1
end
local function DayOf(t) return date("%Y%m%d", t) end

function ns:CampSchedule(camp)
    local grid = {}
    for i = 1, SLOTS do grid[i] = { total = 0 } end
    local days, n = {}, 0
    for _, r in ipairs(self.campRuns and self.campRuns[camp] or {}) do
        n = n + 1
        local seen = {}
        local t, stop = r[2], math.min(r[3], r[2] + 12 * 3600)
        while true do
            local key = SlotOf(t) .. ":" .. DayOf(t)
            if not seen[key] then
                seen[key] = true
                local g = grid[SlotOf(t)]
                g[r[1]] = (g[r[1]] or 0) + 1
                g.total = g.total + 1
            end
            days[DayOf(t)] = true
            if t >= stop then break end
            t = math.min(t + 300, stop)
        end
    end
    local nDays = 0
    for _ in pairs(days) do nDays = nDays + 1 end
    return grid, n, nDays
end

-- The service most often seen in a slot, its share, and how many days back that up.
function ns.CampSlotBest(g)
    local best, bestN = nil, 0
    for _, s in ipairs(ns.CAMP_SERVICES) do
        if (g[s.key] or 0) > bestN then best, bestN = s.key, g[s.key] end
    end
    return best, g.total > 0 and bestN / g.total or 0, bestN
end

-- Latest run of each service at a camp.
function ns:CampLastSeen(camp)
    local last = {}
    for _, r in ipairs(self.campRuns and self.campRuns[camp] or {}) do
        if not last[r[1]] or r[3] > last[r[1]][3] then last[r[1]] = r end
    end
    return last
end

-- Next half hour (from now) when `svc` is the likeliest, with its share. nil if never seen.
function ns:CampNext(camp, svc, grid)
    grid = grid or self:CampSchedule(camp)
    local now = Now()
    local slot = SlotOf(now)
    for i = 0, SLOTS - 1 do
        local s = (slot - 1 + i) % SLOTS + 1
        local best, share = ns.CampSlotBest(grid[s])
        if best == svc and share >= 0.5 then
            local d = date("*t", now)
            local start = now - (d.hour * 3600 + d.min * 60 + d.sec) + (s - 1) * SLOT
            if start + SLOT <= now then start = start + 86400 end
            return start, share, i == 0
        end
    end
end

function ns:OnCampUpdated()
    if self.campFrame and self.campFrame:IsShown() and not self.campRefresh then
        self.campRefresh = C_Timer.NewTimer(0.3, function() ns.campRefresh = nil; ns:RefreshCamp() end)
    end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local CELL_W, CELL_H, ROW_GAP = 15, 16, 4

local function Ago(t)
    local s = Now() - t
    if s < 90 then return "just now" end
    if s < 3600 then return string.format("%d min ago", s / 60) end
    if s < 86400 then return string.format("%dh %02dm ago", s / 3600, (s % 3600) / 60) end
    return string.format("%d days ago", s / 86400)
end

function ns:ShowCamp()
    if not self.campFrame then self:CreateCampFrame() end
    if self.campFrame:IsShown() then self.campFrame:Hide() return end
    self.campFrame:Show()
    self:RefreshCamp()
end

function ns:CreateCampFrame()
    local f = CreateFrame("Frame", "AHPriceTrackerCamp", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(48 * CELL_W + 120, 330)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, f:GetName())
    local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not f.TitleText then title:SetPoint("TOP", 0, -5) end
    title:SetText("Neutral camp schedule")
    self.campFrame = f

    local side = UnitFactionGroup("player")
    self.campSel = (side == "Alliance") and "redridge" or "barrens"

    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(230, 22)
    btn:SetPoint("TOPLEFT", 14, -30)
    btn:SetScript("OnClick", function()
        ns.campSel = (ns.campSel == "barrens") and "redridge" or "barrens"
        ns:RefreshCamp()
    end)
    f.campBtn = btn

    f.status = {}
    for i, s in ipairs(self.CAMP_SERVICES) do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", 16, -60 - (i - 1) * 18)
        fs:SetJustifyH("LEFT")
        f.status[s.key] = fs
    end

    -- Grid: one row per service, one column per half hour of the day (your local time)
    local gx, gy = 90, -130
    f.cells = {}
    for r, s in ipairs(self.CAMP_SERVICES) do
        local lab = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lab:SetPoint("RIGHT", f, "TOPLEFT", gx - 6, gy - (r - 1) * (CELL_H + ROW_GAP) - CELL_H / 2)
        lab:SetText(s.label)
        f.cells[s.key] = {}
        for c = 1, SLOTS do
            local cell = CreateFrame("Frame", nil, f)
            cell:SetSize(CELL_W - 1, CELL_H)
            cell:SetPoint("TOPLEFT", gx + (c - 1) * CELL_W, gy - (r - 1) * (CELL_H + ROW_GAP))
            cell.tex = cell:CreateTexture(nil, "ARTWORK")
            cell.tex:SetAllPoints()
            cell.slot, cell.svc = c, s.key
            cell:EnableMouse(true)
            cell:SetScript("OnEnter", function(self) ns:CampCellTooltip(self) end)
            cell:SetScript("OnLeave", GameTooltip_Hide)
            f.cells[s.key][c] = cell
        end
    end
    for h = 0, 24, 3 do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOP", f, "TOPLEFT", gx + h * 2 * CELL_W, gy - 3 * (CELL_H + ROW_GAP) - 2)
        fs:SetText(string.format("%02d:00", h % 24))
    end
    local nowLine = f:CreateTexture(nil, "OVERLAY")
    nowLine:SetColorTexture(1, 0.2, 0.2, 0.9)
    nowLine:SetSize(2, 3 * (CELL_H + ROW_GAP))
    f.nowLine, f.gx, f.gy = nowLine, gx, gy

    f.next = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.next:SetPoint("TOPLEFT", 16, gy - 3 * (CELL_H + ROW_GAP) - 26)
    f.next:SetJustifyH("LEFT")
    f.next:SetWidth(f:GetWidth() - 32)

    f.foot = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.foot:SetPoint("BOTTOMLEFT", 16, 14)
    f.foot:SetWidth(f:GetWidth() - 32)
    f.foot:SetJustifyH("LEFT")
    f.foot:SetSpacing(2)

    f:SetScript("OnUpdate", function(self, el)
        self.acc = (self.acc or 0) + el
        if self.acc > 30 then self.acc = 0; ns:RefreshCamp() end
    end)
end

function ns:CampCellTooltip(cell)
    local g = self.campGrid and self.campGrid[cell.slot]
    if not g then return end
    local from = (cell.slot - 1) * SLOT
    GameTooltip:SetOwner(cell, "ANCHOR_TOP")
    GameTooltip:AddLine(string.format("%02d:%02d - %02d:%02d", from / 3600, (from % 3600) / 60,
        ((from + SLOT) / 3600) % 24, ((from + SLOT) % 3600) / 60))
    if g.total == 0 then
        GameTooltip:AddLine("No sightings at this time of day yet.", 0.7, 0.7, 0.7)
    else
        for _, s in ipairs(self.CAMP_SERVICES) do
            local n = g[s.key] or 0
            GameTooltip:AddDoubleLine(s.who, string.format("%d of %d day%s", n, g.total, g.total == 1 and "" or "s"),
                s.color[1], s.color[2], s.color[3], 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

function ns:RefreshCamp()
    local f = self.campFrame
    if not (f and f:IsShown()) then return end
    local camp = self.campSel
    local c = CAMP_BY_KEY[camp]
    f.campBtn:SetText(c.label .. "  (switch)")

    local grid, nRuns, nDays = self:CampSchedule(camp)
    self.campGrid = grid
    local last = self:CampLastSeen(camp)
    local now = Now()
    for _, s in ipairs(self.CAMP_SERVICES) do
        local r = last[s.key]
        local text
        if not r then
            text = "|cff808080not seen yet|r"
        elseif now - r[3] < 15 * 60 then
            text = "|cff40ff40there now|r (seen " .. Ago(r[3]) .. (r[4] == "shared" and ", by another addon user)" or ")")
        else
            text = "last seen " .. Ago(r[3]) .. string.format(" (%s)", date("%a %H:%M", r[3]))
        end
        f.status[s.key]:SetText(string.format("|cff%02x%02x%02x%s|r: %s", s.color[1] * 255, s.color[2] * 255,
            s.color[3] * 255, s.who, text))
    end

    for _, s in ipairs(self.CAMP_SERVICES) do
        for i = 1, SLOTS do
            local g = grid[i]
            local cell = f.cells[s.key][i]
            if g.total == 0 then
                cell.tex:SetColorTexture(0.2, 0.2, 0.2, 0.5)
            else
                local share = (g[s.key] or 0) / g.total
                if share == 0 then
                    cell.tex:SetColorTexture(0.12, 0.12, 0.12, 0.8)
                else
                    cell.tex:SetColorTexture(s.color[1], s.color[2], s.color[3], 0.25 + 0.75 * share)
                end
            end
        end
    end
    local d = date("*t", now)
    local x = (d.hour * 3600 + d.min * 60) / SLOT * CELL_W
    f.nowLine:ClearAllPoints()
    f.nowLine:SetPoint("TOPLEFT", f, "TOPLEFT", f.gx + x, f.gy)

    local start, share, isNow = self:CampNext(camp, "auction", grid)
    if not start then
        f.next:SetText(nRuns == 0 and "No sightings yet. Walk past or talk to the camp's goblin NPC and it's recorded."
            or "Not enough sightings to predict the auctioneer yet.")
    elseif isNow then
        f.next:SetText(string.format("Auctioneer: |cff40ff40usually there now|r (seen at this time on %d%% of days).", share * 100))
    else
        f.next:SetText(string.format("Next likely auctioneer: |cffffd100%s|r (in %s; seen at that time on %d%% of days).",
            date("%H:%M", start), self.Duration and self.Duration(start - now) or "", share * 100))
    end
    f.foot:SetText(string.format("%d sighting%s over %d day%s, from you and other addon users. Times are your local time. "
        .. "A sighting is recorded when you see one of the three NPCs (mouse over, target, interact or nameplate). "
        .. "Bright = seen there at that time on most days, dark = another service was there instead, grey = no data yet. "
        .. "Chat alert when another user sees the auctioneer at your camp: /aht camp alerts.",
        nRuns, nRuns == 1 and "" or "s", nDays, nDays == 1 and "" or "s"))
end

function ns:CampCommand(rest)
    if (rest or ""):lower():match("alert") then
        self.settings.campAlerts = not self.settings.campAlerts
        self.Print("Camp auctioneer alerts %s.", self.settings.campAlerts and "on" or "off")
        return
    end
    self:ShowCamp()
end
