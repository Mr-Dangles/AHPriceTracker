# AH Price Tracker: Quick Manual

Open the window with **/aht**, or with the **Price Tracker** button next to the Auction House. Type **/aht help**, or press **?** in the title bar, for this manual in game.
Data is collected whenever the **Auction House is open**, even with the window closed. Every AH search you make is recorded and shared with other players running the addon.

## Everywhere
- **Right-click any item** for a menu: Track price, Show history, Fast watch, Search the AH, Link in chat.
- **Price data** (title bar):
  - **Mixed**: the freshest price from any source.
  - **Game scans**: in-game scans only.
  - **Online**: auctionhouse.fyi only.
- **Chars** (title bar): show trades, profit and auctions for this character, every character on this realm, or the whole account.

## Auction houses
Each auction house has its own listings. Your faction's cities share one (Orgrimmar, Undercity and Thunder Bluff for the Horde). The neutral goblin auctioneers share another, open to both factions: Booty Bay, Gadgetzan, Everlook, and Auctioneer Quickcoin at the Crossroads and in Redridge. The neutral cut is 15% instead of 5%.

The addon keeps scans, sales, Flip Finder prices and your auction list separately for each house, and shares them for the right house. The **AH** button (title bar, left) shows which house every page uses; it switches when you open an auction house. Your watch list is the same everywhere. auctionhouse.fyi data only covers the faction houses.

## Neutral camp schedule
The trade camp just west of the Crossroads (and Three Corners in Redridge) has one spot that takes turns between Auctioneer Quickcoin (neutral auction house), the Uninspected Shipment (bank) and the Steamwheedle Courier (mail). Nobody has published when each is there, so the addon records it whenever you see one (mouse over, target, interact or a nameplate) and shares it with other addon users.

**Camp schedule** (title bar) or `/aht camp` shows who's there now, a 24-hour chart of who's usually there in each half hour, and when the auctioneer is next likely. You get a chat note when another user sees the auctioneer at your faction's camp; `/aht camp alerts` toggles it.

## Prices
- Track an item by typing its **name** (pick from the suggestions), shift-clicking it, or entering its ID. Use **Sort by** to order the list.
- **Graph**:
  - The **legend** lists every series. Hover an entry to see what it means, and click it to show or hide it.
  - **Drag** the chart to move it, **mouse wheel** to zoom, **double-click** to reset. Ranges run from 1h to All.
- **Volume pane**: bars show units sold, the orange line shows units listed, and grey means not watched. Drag the divider to resize it.
- **Fast watch** (right-click an item) scans it every minute instead of every 5, for up to 5 items.
- **Sold/day** is adjusted for time of day, so evening-only watching doesn't inflate it.

## My Auctions
Your current auctions: undercut warnings, time left, when each should sell, value after the AH cut, and projected earnings. They're saved per character.

## Profit
Realized profit per item: sales after the 5% cut, minus what you paid (oldest stock first) and deposits lost. Purchases include AH buys and vendor buys. Choose a period: 24h, 7d, 30d or All.

## Trade History
- Logs player trades, AH buys, vendor buys, AH sales and listings.
- A sale shows up the moment it happens, marked **(in mail)**. Opening a mailbox swaps in the exact amount.
- Use the filters and search to narrow the list. **Refresh** forces an update, and **Export CSV** saves the list.

## Flip Finder
- **Vendor > AH** is ranked by **Profit/day**, which uses real sales volume.
- **AH > Vendor** finds AH listings cheaper than what a vendor pays.
- Filter by item type and cost range.

## Crafting
- Pick **any profession**, even one you don't have, to see if it's worth starting.
- Each recipe shows material cost, sale price, profit and sales volume.
- The **skill bracket cards** show how profitable each stage of the profession is. Gathering professions show the value of what they collect.

## Market Data
- Prices for every item on your auction house, from auctionhouse.fyi.
- **To refresh it automatically:** double-click **Hourly Market Data - On.bat** once. **Off.bat** stops it.
- **To refresh by hand:** run **Update Market Data.bat**.
- Either way, type **/reload** to load the new data.

## Town services (world map)
- Icons for auction houses, banks, innkeepers, flight masters, trainers, stable masters, repair, vendors and mailboxes.
- Locations are **learned** when you use one, and shared with other addon users, so towns fill in for everyone.
- The **Services** button on the world map shows or hides each type. `/aht tracking` turns on minimap tracking for them too.

## Commands
| Command | Does |
|---|---|
| `/aht` · `/aht help` | Open the window · the manual |
| `/aht prices`, `auctions`, `profit`, `history`, `flips`, `crafting`, `market` | Open a tab |
| `/aht add <item>` / `remove <item>` | Track or untrack an item (name, link or ID) |
| `/aht scan` · `interval <sec>` · `auto on/off` | Scanning |
| `/aht sync` | Sharing (`on`, `off`, `guildonly`, `ignore <name>`) |
| `/aht export` · `/aht perf` | Price history CSV · memory and CPU use |
