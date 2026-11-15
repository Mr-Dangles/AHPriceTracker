-- AH Price Tracker: in-game manual (the "?" button in the title bar, or /aht help)
local ADDON, ns = ...

local H = "|cffffd100"   -- heading colour
local K = "|cff59d9cc"   -- key word colour
local E = "|r"

local SECTIONS = {
    { "Getting started", {
        "Open with " .. K .. "/aht" .. E .. " or the " .. K .. "Price Tracker" .. E .. " button next to the Auction House.",
        "Most data is collected while the " .. K .. "Auction House is open" .. E .. ". The tracker window doesn't need to be open.",
        "Every AH search you make is recorded and shared with other players running the addon.",
    } },
    { "Everywhere", {
        K .. "Right-click any item" .. E .. ": Track price, Show history, Fast watch, Search the AH, Link in chat.",
        K .. "Item tooltips" .. E .. " everywhere show what a vendor " .. K .. "sells" .. E .. " the item for (per item, and the bundle price), the AH lowest, and the flip margin after the cut. The game's own \"Sell Price\" line (what a vendor pays you) is hidden.",
        K .. "Price data" .. E .. " (title bar): " .. K .. "Mixed" .. E .. " uses the freshest price from any source, "
            .. K .. "Game scans" .. E .. " uses in-game scans only, " .. K .. "Online" .. E .. " uses auctionhouse.fyi only.",
        K .. "Chars" .. E .. " (title bar): show trades, profit and auctions for this character, every character on this realm, or the whole account.",
        K .. "AH" .. E .. " (title bar, left): which auction house's prices every page shows. It switches by itself when you open an auction house.",
    } },
    { "Auction houses", {
        "Each auction house has its own listings. " .. K .. "Your faction's cities share one" .. E .. " (Orgrimmar, Undercity, Thunder Bluff for the Horde).",
        "The " .. K .. "neutral goblin auctioneers" .. E .. " share another, open to both factions: Booty Bay, Gadgetzan, Everlook, and Auctioneer Quickcoin at the Crossroads and in Redridge. Its cut is " .. K .. "15%" .. E .. " instead of 5%.",
        "The addon keeps scans, sales, Flip Finder prices and your auction list separately for each house, and shares them with other players for the right house. Your watch list is the same everywhere.",
        "auctionhouse.fyi data only covers the faction auction houses, so at the neutral house prices come from game scans only.",
    } },
    { "Neutral camp schedule", {
        "The trade camp just west of the Crossroads (and Three Corners in Redridge) has one spot that takes turns between " .. K .. "Auctioneer Quickcoin" .. E .. " (neutral auction house), the " .. K .. "Uninspected Shipment" .. E .. " (bank) and the " .. K .. "Steamwheedle Courier" .. E .. " (mail).",
        "Nobody has published when each is there, so the addon records it whenever you see one (mouse over, target, interact or a nameplate) and shares it with other addon users.",
        K .. "Camp schedule" .. E .. " (title bar) or " .. K .. "/aht camp" .. E .. ": who's there now, a 24-hour chart of who's usually there in each half hour, and when the auctioneer is next likely.",
        "You get a chat note when another user sees the auctioneer at your faction's camp. " .. K .. "/aht camp alerts" .. E .. " turns that off or on.",
    } },
    { "Prices", {
        "Type an item's " .. K .. "name" .. E .. " (pick from the suggestions), shift-click an item, or enter an item ID to track it.",
        K .. "Sort by" .. E .. " orders the list (price, change, sold per day...).",
        "Graph: the " .. K .. "legend" .. E .. " lists each series. Hover an entry to see what it means, click it to show or hide it.",
        K .. "Drag" .. E .. " the chart to move it, " .. K .. "mouse wheel" .. E .. " to zoom, " .. K .. "double-click" .. E .. " to reset. Ranges run from 1h to All.",
        "Volume pane: bars are units sold, the orange line is units listed, grey means nobody was watching. Drag the divider to resize it.",
        K .. "Fast watch" .. E .. " (right-click an item) scans it every minute instead of every 5, for up to 5 items. Use it on items you're actively flipping.",
    } },
    { "My Auctions", {
        "Your current auctions: undercut warnings, time left, when each should sell, value after the cut, and projected earnings.",
        "Read whenever the AH is open. Saved per character, so it works anywhere.",
    } },
    { "Profit", {
        "Realized profit per item: AH sales after the AH cut, minus what you paid (oldest stock first) and deposits lost.",
        "Purchases come from AH buys and " .. K .. "vendor buys" .. E .. ". Items you farmed or crafted count as free (marked *).",
        "Pick 24h, 7d, 30d or All. The cards at the top show the totals.",
    } },
    { "Trade History", {
        "Logs player trades, AH buys, vendor buys, AH sales and listings (with deposits).",
        "A sale appears the moment it happens, marked " .. K .. "(in mail)" .. E .. ". Opening a mailbox swaps in the exact amount.",
        "Use the filters and search to narrow the list. " .. K .. "Refresh" .. E .. " forces an update and " .. K .. "Export CSV" .. E .. " saves the list.",
    } },
    { "Flip Finder", {
        K .. "Vendor > AH" .. E .. ": buy from a vendor, sell on the AH. Ranked by " .. K .. "Profit/day" .. E .. ", which uses real sales volume.",
        K .. "AH > Vendor" .. E .. ": AH listings cheaper than what a vendor pays.",
        "Filter by item type (crafting parts, vendor items, drops...) and cost range.",
        "Opening vendors and profession windows teaches the addon which items are sold or crafted.",
    } },
    { "Crafting", {
        "Pick any profession from the dropdown, even one you don't have, to see if it's " .. K .. "worth starting" .. E .. ".",
        "Each recipe shows material cost (the cheaper of vendor or AH), sale price after the cut, profit and sales volume.",
        "The " .. K .. "skill bracket cards" .. E .. " show how many recipes are profitable at each stage, and the best one.",
        "Gathering professions show the value of what they collect. " .. K .. "*" .. E .. " marks recipes you know.",
    } },
    { "Market Data", {
        "Prices for every item on your auction house, from auctionhouse.fyi (player-uploaded scans).",
        "It refreshes hourly on its own (scheduled task). To refresh by hand, run " .. K .. "Update Market Data.bat" .. E .. ". Either way, type " .. K .. "/reload" .. E .. " to load the new data.",
        "Prices older than 12 hours are marked " .. "|cffff9900orange" .. E .. ".",
    } },
    { "Town services (world map)", {
        "Icons for auction houses, banks, innkeepers, flight masters, class and profession trainers, stable masters, repair, vendors and mailboxes.",
        "Locations are " .. K .. "learned" .. E .. " when you use one (open the bank, talk to the innkeeper...), and shared with other addon users, so towns fill in for everyone.",
        "The " .. K .. "Services" .. E .. " button on the world map shows or hides each type. Hover an icon for the NPC's name.",
        K .. "/aht tracking" .. E .. " turns on the game's minimap tracking for these NPCs too.",
    } },
    { "Commands", {
        K .. "/aht" .. E .. " open/close   " .. K .. "/aht help" .. E .. " this manual",
        K .. "/aht prices | auctions | profit | history | flips | crafting | market" .. E .. " open a tab",
        K .. "/aht add <item>" .. E .. " / " .. K .. "remove <item>" .. E .. " track or untrack (name, link or ID)",
        K .. "/aht scan" .. E .. " scan now   " .. K .. "/aht interval <sec>" .. E .. "   " .. K .. "/aht auto on|off" .. E,
        K .. "/aht sync" .. E .. " sharing status (on, off, guildonly, ignore <name>)",
        K .. "/aht export" .. E .. " price history CSV   " .. K .. "/aht perf" .. E .. " memory and CPU use",
    } },
}

function ns:ShowHelp()
    if not self.helpFrame then
        local hf = CreateFrame("Frame", "AHPriceTrackerHelp", UIParent, "BasicFrameTemplateWithInset")
        hf:SetSize(560, 460)
        hf:SetPoint("CENTER", 60, -20)
        hf:SetFrameStrata("DIALOG")
        hf:SetMovable(true)
        hf:EnableMouse(true)
        hf:RegisterForDrag("LeftButton")
        hf:SetScript("OnDragStart", hf.StartMoving)
        hf:SetScript("OnDragStop", hf.StopMovingOrSizing)
        hf:SetClampedToScreen(true)
        tinsert(UISpecialFrames, hf:GetName())
        local title = hf.TitleText or hf:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        if not hf.TitleText then title:SetPoint("TOP", 0, -5) end
        title:SetText("AH Price Tracker - Manual")

        local sf = CreateFrame("ScrollFrame", nil, hf, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 14, -32)
        sf:SetPoint("BOTTOMRIGHT", -32, 12)
        local child = CreateFrame("Frame", nil, sf)
        child:SetWidth(500)
        sf:SetScrollChild(child)

        local y = -2
        for _, sec in ipairs(SECTIONS) do
            local head = child:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            head:SetPoint("TOPLEFT", 0, y)
            head:SetText(H .. sec[1] .. E)
            y = y - head:GetStringHeight() - 6
            for _, line in ipairs(sec[2]) do
                local fs = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                fs:SetPoint("TOPLEFT", 10, y)
                fs:SetWidth(488)
                fs:SetJustifyH("LEFT")
                fs:SetSpacing(2)
                fs:SetText("- " .. line)
                y = y - fs:GetStringHeight() - 5
            end
            y = y - 10
        end
        child:SetHeight(-y + 10)
        self.helpFrame = hf
    end
    self.helpFrame:SetShown(not self.helpFrame:IsShown())
end
