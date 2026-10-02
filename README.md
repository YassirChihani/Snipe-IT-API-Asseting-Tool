# Snipe-IT Asset Tool

A PowerShell tool that makes day-to-day Snipe-IT work fast. Instead of opening each asset in its own window, you scan (or type) asset after asset, and the tool does the check-ins, check-outs and audits for you.

Built for **Snipe-IT v4.6 and v8**: it only uses API features that exist in both. Tested on v8 in a Docker lab.

> **Demo video:** [add your link here]
>
> **[User guide with screenshots](docs/USER-GUIDE.md)**

### Why I built it

I work in IT support in education, where laptops are tracked in an older version of Snipe-IT. Checking assets in and out meant opening each one in its own window, barcodes were stored inconsistently (some as asset tags, some as serial numbers, some in other fields), and laptops regularly got mixed up between charging caddies. I designed this tool around those problems.

The tool was built with AI assistance (Claude), which wrote much of the PowerShell to my specification. I set up the test environment, tested it against Snipe-IT v8 in Docker, found and fixed issues, and I'm working through the code to understand every part of it.

## What it does

| Mode | Use it for |
|---|---|
| **1. Scan an asset** | Scan any asset to see its status, who has it and when it's due back, then choose: check in (optionally to a location and with a new status), check out (or transfer), change status, or record an audit. **[R]** repeats your last action on the next asset |
| **2. Check out many** | Pick a user, location or caddy once, then scan asset after asset. Optional expected return date and note for the whole session |
| **3. Check in many** | Scan assets to check them in, with an optional note and location. Late returns are flagged |
| **4. Bulk from CSV** | Many check-ins and check-outs at once, each to a different person, location or caddy. The whole file is checked before anything changes |
| **5. Caddy audit** | Scan a caddy, scan the laptops physically in it, and see what's in the wrong place or missing. Then fix Snipe-IT or get a move list. Optionally records every laptop you scan as audited in Snipe-IT |
| **6. Reports** | Everything on loan to people, overdue returns, what one person has, and caddy contents |

**Undo:** type `UNDO` at any scan prompt to reverse the last change (it shows what will be restored and asks first). You can type it again to go further back. After a bulk CSV run, typing `UNDO` reverses the whole batch. Undo puts back who or where the asset was with and its status; a return date that has already passed isn't restored.

**Audits:** Snipe-IT can record when each asset was last physically seen. The caddy audit can record this for every laptop you scan, and "Scan an asset" has a **[A] Record audit** option. If your Snipe-IT version doesn't support this through the API, the tool says so and carries on without it.

**Getting around:** press Enter on an empty line to finish a list or go back a step, type `B` where offered to go back, and `Q` at the main menu to quit. Ctrl+C stops the tool immediately.

### Statuses

"Deployed" isn't a status you set: Snipe-IT shows an asset as deployed automatically while it's checked out. The statuses you can choose are your Snipe-IT status labels (e.g. Ready to Deploy, Broken, Disposed). Choosing one that means "not usable" (undeployable or archived) checks the asset in first, since those can't stay checked out. When checking an asset in, you can also set its status at the same time, e.g. check in and mark as Broken.

Every mode saves a CSV report of what it did to the `reports` folder.

## Scan anything

Barcodes aren't always stored in the asset tag field, so every scan is looked up in this order:

1. Asset tag
2. Serial number
3. Asset name and all custom fields

Only **exact** matches are used automatically. If a value matches several assets (e.g. a duplicate serial), you pick the right one. If nothing matches, it shows similar assets and asks you to scan a different identifier, such as the serial on the sticker. It never guesses.

People can be found by name, username, email or employee number. If several people match (e.g. two "Smith"s), you pick from a list.

A USB barcode scanner works like a keyboard that types the code and presses Enter, so most sessions need no typing at all.

## Safety

- **Practice mode:** run with `-WhatIf`. It reads live data from Snipe-IT so the preview is accurate, but changes nothing
- **Live checks before every change:** each asset is re-read from Snipe-IT just before it's changed, so it's never acting on out-of-date information
- **No surprise transfers:** if an asset is already checked out to someone else, you choose whether to transfer it (ask each time, always, or never)
- **Non-deployable assets** (e.g. status "Broken") are never checked out
- **CSV files are validated first:** missing assets, unknown people, bad dates and duplicate rows are all reported before you confirm
- **Every change leaves a note in the asset's history in Snipe-IT**, including who ran the tool
- **Undo** for the last change, or a whole CSV batch
- **Your API key is stored encrypted** with Windows DPAPI, readable only by your Windows account on your PC. It's never in the script or config file

## Setup

1. **Get an API key.** In Snipe-IT, open your profile menu (top right) → **Manage API Keys** → create a token. It has the same permissions as your Snipe-IT account.
2. **Edit `config/settings.json`:**

   | Setting | What it does |
   |---|---|
   | `SnipeUrl` | Your Snipe-IT address, e.g. `https://snipeit.example.local` |
   | `SkipCertificateCheck` | Leave `false`. Only set `true` if your internal server's certificate isn't trusted by your PC and IT has said that's acceptable |
   | `CaddyKeywords` | Words that identify a caddy in its tag, name, model or category |
   | `DefaultAssignType` | What `AssignTo` means in a CSV when `AssignType` is blank: `user`, `location` or `asset` |

3. **Run it** in PowerShell from the tool's folder:

   ```powershell
   .\Start-SnipeTool.ps1 -WhatIf     # practice first
   .\Start-SnipeTool.ps1
   ```

   The first run asks for your API key. Use `-ResetApiKey` to replace it. If Windows blocks the script, ask IT about the execution policy on your PC.

You can also jump straight to a mode:

```powershell
.\Start-SnipeTool.ps1 -Mode Scan
.\Start-SnipeTool.ps1 -Mode CheckOut
.\Start-SnipeTool.ps1 -Mode Csv -CsvPath .\loans.csv
.\Start-SnipeTool.ps1 -Mode Audit
```

## CSV format

See `templates/bulk-template.csv`:

| Column | Required | Notes |
|---|---|---|
| `Identifier` | Yes | Asset tag, serial or barcode (`AssetTag` also works as the column name) |
| `Action` | Yes | `Checkout` or `Checkin` (also accepts Out/In/Loan/Return) |
| `AssignTo` | For check-outs | Username, email, name, location name or caddy tag |
| `AssignType` | No | `User`, `Location` or `Asset`. Blank uses `DefaultAssignType` |
| `ExpectedCheckin` | No | `dd/MM/yyyy`, `yyyy-MM-dd` or `+14` (days from today) |
| `Notes` | No | Added to the asset's history |

## Caddy audit

1. Scan a caddy, then every laptop physically in it. Each scan shows **OK**, **WRONG CADDY**, **LOANED**, **UNASSIGNED** or **UNKNOWN**.
2. Press Enter on an empty line. Laptops Snipe-IT expected but you didn't scan are listed as **MISSING**.
3. Choose to update Snipe-IT to match what's physically there, go one by one, or leave Snipe-IT alone and add them to a physical move list.
4. At the end of the session, "missing" laptops that turned up in another caddy are matched up, so the report only lists ones not found anywhere.

Laptops on loan to a person are only moved after you confirm, since that ends the loan.

## Test data

To try the tool safely, run your own copy of Snipe-IT locally (e.g. with Docker), point `SnipeUrl` at it, then run:

```powershell
.\tools\New-SnipeTestData.ps1
```

It creates caddies, 24 laptops, locations and test users, including deliberately messy cases: barcodes stored in the serial and a custom field, a duplicate serial, a broken laptop, two users called Smith, an overdue loan and unassigned laptops. It prints suggestions for what to scan when it finishes.

It only runs against `localhost`, so it can never add test data to a real Snipe-IT. It's safe to run again: existing items are reused, and any laptops you've moved are put back where they started, which resets the scenario.

(The public Snipe-IT demo site can't be used, because it doesn't allow API keys.)

## Files

```
Start-SnipeTool.ps1     Main menu and entry point
lib/SnipeApi.ps1        Snipe-IT API calls and asset lookup
lib/Ui.ps1              Prompts, finding people/locations, safe check-in/out, reports
lib/AssetDesk.ps1       Scan an asset (details and action menu)
lib/ScanMode.ps1        Check out many / check in many
lib/CsvMode.ps1         Bulk CSV mode
lib/CaddyAudit.ps1      Caddy audit
lib/Reports.ps1         Reports
config/settings.json    Settings
templates/              Example CSV
tools/                  Test data script and demo CSV for a local test copy of Snipe-IT
docs/                   User guide and screenshots
```
