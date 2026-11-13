# Bond Scanner (maintainable v2 project)

This is the extracted, working Bond Scanner **v2** source, taken from the heredoc in `~/Downloads/bondscan_v2.command`.

- Source: `Sources/BondScanner.swift`
- Staging build: `./build.sh` or `./build.sh --staging` — writes `build/BondScanner.app` (does not touch the installed app)
- Install build: `./build.sh --install` — writes `~/Applications/BondScanner.app` (only when you are ready to replace the installed copy)
- Launch staging: `./bondscan.command` — builds staging and opens that copy, not the installed app
- Installed v2 location: `~/Applications/BondScanner.app` (this is where v2 actually installed; not `~/BondScans/BondScanner.app`)
- Scan data (do not delete): `~/BondScans/`

The original `~/Downloads/bondscan_v2.command` is left untouched. Do not run it to launch; it would overwrite `~/Library/Application Support/BondScanner/BondScanner.swift` with its embedded heredoc and could undo later edits.

This launcher never writes that Application Support file and never overwrites `~/BondScans/README.txt` or scan data.
