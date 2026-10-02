# Snipe-IT Asset Tool

A PowerShell tool that lets IT Technicians check assets in and out of Snipe-IT, audit laptop caddies and run loan reports from one interface window.

> **Demo video:** [add your link here]  ·  **[User guide with screenshots](docs/USER-GUIDE.md)**

![Auditing a laptop caddy](docs/images/07-caddy-audit-scanning.png)

## Features

- **Scan an asset** to see where it is, then check it in, check it out, change its status or record an audit. **R** repeats the last action for fast batches
- **Check out or check in many** assets to the same person, location or caddy
- **Bulk CSV** check-ins and check-outs, validated before anything changes
- **Caddy audits** comparing what's physically in a caddy with Snipe-IT, then fixing it or producing a move list
- **Reports** on loans, overdue returns, one person's assets and caddy contents
- **Finds assets by asset tag, serial or any custom field**, and reports duplicates for selection
- **Safe by design:** practice mode, undo, live re-checks before every change, and a note in each asset's history

Built for **Snipe-IT v4.6 and v8.x.x**. Tested on v8.8.0

## Quick start

1. Set your Snipe-IT address in `config/settings.json`
2. In PowerShell, from the tool's folder:
   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   .\Start-SnipeTool.ps1 -WhatIf     # practice mode: changes nothing
   ```
3. Paste your Snipe-IT API key when asked

See the **[user guide](docs/USER-GUIDE.md)** for full setup and instructions.

## License

MIT
