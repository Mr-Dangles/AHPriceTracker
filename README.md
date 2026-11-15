# AH Price Tracker (WoW Forever)

Logs auction house prices for the items you choose and graphs their history.

## Download
**[Download the newest version](https://github.com/Mr-Dangles/AHPriceTracker/releases/latest/download/AHPriceTracker.zip)** (this link always gets the latest release).
All versions and what changed: [Releases](https://github.com/Mr-Dangles/AHPriceTracker/releases).

Using WowUp? Add `https://github.com/Mr-Dangles/AHPriceTracker` under Get Addons > Install from URL and it updates automatically.

## Install
Unzip, then copy the `AHPriceTracker` folder into:
`World of Warcraft\_forever_\Interface\AddOns\`
then restart the game (or `/reload`).

## Use
- `/aht` opens the window, or click **Price Tracker** next to the Auction House.
- Add items: shift-click an item link into the box, drag an item onto it, or type an item ID. You can also use `/aht add [item link]`.
- Right-click an item in the list to stop tracking it.
- While the Auction House is open, each item is searched again every 5 minutes (`/aht interval <seconds>`).
  Scanning pauses while a buy/sell screen is open so it doesn't get in your way.
  Searches you run yourself in the AH also get logged for tracked items.
- The graph shows **Lowest buyout** (gold) and **Market** (blue, the average unit price of the cheapest 15% of units listed).
  Switch the range with 24h / 7d / 30d / All, and hover over the graph for exact values.
- **Export CSV** copies the history of the selected item. `/aht export` copies the history of all items.

### Graph indicators
The legend above the graph lists every series with its colour. Hover an entry to see what it means and how to read it, and click it to show or hide that series. Lowest and Market can be hidden too.
- **Sold**: volume bars in a pane under the price graph, showing estimated units bought per period. Grey columns mean nobody was watching.
- **Listed**: an orange supply line in the volume pane.
- **MA**: a moving average of the lowest buyout. The window grows with the view: 10 minutes on 1h, 1 hour on 6h, 2 hours on 12h, 3 hours on 24h, 1 day on 7d and 3 days on 30d.
- **Bands**: Bollinger bands, the moving average plus or minus 2 standard deviations. Hover to see whether the current price is cheap or expensive compared with its recent range.
- **Trades**: your own buys and sales.

Moving the view:
- **Drag** the price chart up or down to shift the price scale.
- **Scroll the mouse wheel** over it to zoom the price scale.
- **Double-click** it, or press **Reset view**, to snap back.
- Drag the divider above the tinted **VOLUME** pane to make the pane taller or shorter.

### Sorting, menus and price data
- **Sort by** above the item list: name, price, 24h change, 7d change, sold per day, listed now, recently added or last scanned. Click Asc/Desc to flip the order.
- **Right-click any item on any page** for a menu: Track price, Show price history, Stop tracking, Search on the Auction House, Link in chat, plus that page's own actions.
- **Price data** in the title bar applies to every page:
  - **Mixed**: the freshest price from any source.
  - **Game scans**: only in-game scans, from you, other addon users or Auctionator.
  - **Online**: only auctionhouse.fyi. On the graph its daily closes show as a green line.

## My Auctions tab (`/aht auctions`)
Your current auctions are read whenever the Auction House is open, or when you post or cancel. They're saved, so the tab works anywhere.
- **Cards**: what you have on the market, listed value, value after the 5% cut, projected earnings, and sold auctions waiting in your mail.
- **Per listing**: your price against the lowest now (Lowest price, or Undercut by X%), time left, when the whole stack should sell, value after the cut, and projected earnings.
- **How projections work**: buyers take cheaper units first. The addon counts the units listed below your price and uses the item's sell rate to estimate how much of your stack sells before it expires. Items you have listed are scanned automatically to measure that rate.

## Trade History tab (`/aht history`)
Logs every exchange automatically. You never need to open the window for logging to happen.
- **Player trades**: who you traded with, the items and gold you gave, and the items and gold you got. Only completed trades are logged.
- **AH purchases**: commodity and item buyouts, logged the moment they succeed, with the exact price.
- **AH sales** and **won bids**: read from the Auction House mail when you open a mailbox. Each sale records the sale price, the AH cut and what you received. Each mail is only logged once.

You can filter by type and search by item or player. The summary shows gold spent, gold received, net, and AH cut paid.
Hover over a row for full details, or right-click it to delete it. **Export CSV** exports whatever the current filter shows.
On the Prices graph, green squares mark your purchases of that item and red squares mark your sales.

## Flip Finder tab (`/aht flips`)
Finds items you can buy from a vendor and resell on the AH for a profit.
- Opening any vendor teaches the addon that vendor's prices automatically. It also imports the vendor prices Auctionator has already saved.
- Open the Auction House and press **Scan AH prices**. It searches the AH for every known vendor item (about 1–2 seconds per item).
  Searches you run yourself, and prices from the Prices tab, also feed it. If no scan has been done yet, it falls back to Auctionator's last price.
- Shows the vendor cost, AH lowest price, number listed, profit per unit and per 20 after the 5% AH cut, return %, and when the price was seen.
  Click a column to sort. Items marked "none listed" have no competition, but there's no proof anyone buys them.
- Left-click a row to start tracking its price history. Right-click a row to remove it.

## Sales estimates (Sold/day)
The game doesn't tell addons what other players buy, so the addon estimates it.
Buyers always take the cheapest units first. When the cheapest listings shrink or disappear between two scans, those units count as sold.
Units that vanish from higher prices while cheaper ones stay are treated as cancelled or expired, and aren't counted.
Your own AH purchases are subtracted.
- The Prices tab shows **Sold ~X/day** above the graph for the selected item. The Flip Finder has a **Sold/day** column.
- A rate appears after 30 minutes of watching (two scans at least 30 minutes apart, or several 5-minute scans). It gets better the longer the AH is open.
  Tracked items are rescanned every 5 minutes. Flip Finder items are only rescanned when you press Scan AH prices, so track an item to measure it properly.
- It's an estimate. A cheapest listing that's cancelled or expires counts as a sale. Anything listed and bought between two scans is missed.
  Scans more than 6 hours apart aren't compared.

## Market Data tab (`/aht market`)
Shows prices for every item seen on your auction house, from auctionhouse.fyi. Those prices come from scans uploaded by players, and the site keeps the six Forever auction houses (Normal, PvP and RP, each Horde and Alliance) separate.
- Addons can't go online, so the data comes from a file. To refresh it, double-click **Update Market Data.bat** in the addon folder, then type `/reload` in game.
- Your auction house is picked from your realm and faction. Click the button at the top left to look at another one, or right-click it to go back to yours.
- Columns: site lowest buyout, units listed, your own latest scan, the difference, 7-day low and high, and 7-day change. Hover for the daily closes, and click a row to track it.
- The Flip Finder also uses these prices, so items get an AH price without you scanning them.

## Flip Finder modes and volume
- **Vendor > AH** (buy from a vendor, list on the AH) covers every item with a known vendor cost: vendors you've opened, Auctionator's cache, and vendor prices shared by other addon users.
  Tick **Maybe-vendor items** to add every trade good whose AH price beats the game's listed buy price. Many of those aren't sold by any vendor, so check one first.
- It's ranked by **Profit/day** = profit per unit × units sold per day. Items with measured volume come first, the rest by profit per 20.
- The 8 best candidates are scanned automatically every 5 minutes while the AH is open, so their volume gets measured without you tracking them.
- **AH > Vendor** checks every item in the market data for AH listings cheaper than what a vendor pays for them. Prices marked "unverified" come from the item catalogue until the game confirms them. Hover again after a moment.

### Filters
- **Item type** dropdown:
  - Source groups: Crafting components (vendor and non-vendor), Vendor items, Crafted items, Drop exclusives, Gathered (herbs, ore, skins).
  - Item classes: Trade Goods, Consumables, Reagents, Recipes, Weapons, Armor and so on.
- Vendor items are learned from merchant windows, and crafted items from profession windows, by you or any other addon user.
  Drop exclusives means "not sold by any known vendor, not crafted, not gathered", so it gets more accurate as more vendors and professions are seen.
- **Cost from / to** sets the price per unit you pay. Type `1g20s`, `50s` or `75c`; a plain number means silver.

## Sharing scans with other players (`/aht sync`)
Everyone running this addon shares their scans automatically, through your guild and a hidden chat channel (AHPTForeverSync).
- Shared scans feed price history, Flip Finder prices, vendor prices and sales volume.
- Sales are worked out across everyone's scans combined, so nothing is double-counted. Each player's AH time fills the others' gaps.
- When you log in, a player who is already online sends you what you missed from the last 3 days.
- Messages carry a random ID, not your character name. Only data from the same auction house is used.
- `/aht sync` shows the status. `/aht sync off` stops all sharing, `/aht sync guildonly` limits sharing to your guild, and `/aht sync ignore <name>` drops a player's data.

## Commands
`/aht flips`, `/aht history`, `/aht add|remove <item>`, `/aht scan`, `/aht interval <sec>`, `/aht auto on|off`, `/aht export`

Data is saved per realm in `WTF\Account\<account>\SavedVariables\AHPriceTracker.lua`.
