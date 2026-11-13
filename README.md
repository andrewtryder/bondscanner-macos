# Bond Scanner (maintainable v2 project)

This is the extracted, working Bond Scanner **v2** source, taken from the heredoc in `~/Downloads/bondscan_v2.command`.

- Source: `Sources/BondScanner.swift`
- Build: `./build.sh` — compiles with the same `swiftc` flags as the v2 launcher
- Launch: `./bondscan.command` — builds from this project and opens the app
- App install location: `~/Applications/BondScanner.app` (this is where v2 actually installed; not `~/BondScans/BondScanner.app`)
- Scan data (do not delete): `~/BondScans/`

The original `~/Downloads/bondscan_v2.command` is left untouched. Do not run it to launch; it would overwrite `~/Library/Application Support/BondScanner/BondScanner.swift` with its embedded heredoc and could undo later edits.

This launcher never writes that Application Support file and never overwrites `~/BondScans/README.txt` or scan data.
