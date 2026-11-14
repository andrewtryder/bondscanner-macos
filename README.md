# Bond Scanner (macOS)

A lightweight, native macOS desktop application to scan and catalogue physical United States paper savings bonds (Series E, EE, and I) using Apple Vision OCR and a connected webcam.

All processing occurs 100% locally on your Mac. No images, personal names, tax IDs, or serial numbers are ever transmitted or uploaded anywhere.

---

## Features

- **Real-Time OCR & Edge Detection**: Automatically detects paper savings bond boundaries and extracts denominations, serial numbers, issue dates, and cancellation stamps.
- **Series-Specific Validation**:
  - **Series E**: Validates variable serial lengths (8, 9, 10 digits + `E`), issue years (1941–1980), and standard denominations ($10, $25, $50, $75, $100, $200, $500, $1,000, $5,000, $10,000).
  - **Series EE & I**: Validates modern 10-digit serial patterns.
- **Error-Resistant Heuristics**: Fuzzy word matching (`TWENTY FIVE` vs OCR noise like `TVENTYFINE`), corner numeral extraction, and cancellation stamp date resolution.
- **100% Offline & Private**: High-resolution photos, structured `records.json`, and sanitized `bonds.csv` exports are saved locally to `~/Bondscans/`.
- **Zero Third-Party Dependencies**: Pure native Swift using Apple's `Vision`, `AVFoundation`, `AppKit`, and `CoreImage`.

---

## Building and Running

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to define a clean, reproducible Xcode project structure (`project.yml`).

### Quick Start

1. Install XcodeGen (if not already installed):
   ```bash
   brew install xcodegen
   ```
2. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
3. Open `BondScanner.xcodeproj` in Xcode and press **Cmd+R** to build and run.
   *The project is pre-configured with local ad-hoc code signing ("Sign to Run Locally"), so no paid Apple Developer team certificate is required.*

### Testing

Run the standard unit test suite in Xcode with **Cmd+U** or from the terminal:
```bash
xcodebuild test -project BondScanner.xcodeproj -scheme BondScanner
```

---

## Local-Only Private OCR Regression Testing

This repository includes a local-only image regression framework (`Tests/BondScannerTests/PrivateOCRRegressionTests.swift`) designed to evaluate Vision OCR against real bond photographs without committing sensitive financial or personal information.

### Strict Privacy Guarantee
- The directories `local-fixtures/synthetic/`, `local-fixtures/real/`, and `local-fixtures/reports/` are strictly ignored by `.gitignore`.
- Fixture images, private manifests, and reports remain outside the `Sources/` and `Tests/` directories so XcodeGen will never bundle them into the application.
- Public CI environments or local environments without private real fixtures automatically skip the real photo tests cleanly (`XCTSkip`).
- Test assertion failures never print raw OCR, serial numbers, tax IDs, or owner names to test logs.
- Synthetic and real photo datasets are evaluated separately; their accuracy metrics and reports are never combined.

### Setting Up Private Fixtures

1. **Synthetic Fixtures:**
   Generated locally and written exclusively to `local-fixtures/synthetic/`:
   ```bash
   swift scripts/generate_fixtures.swift
   ```
   This generates synthetic images in `local-fixtures/synthetic/images/` and the synthetic manifest `local-fixtures/synthetic/manifest.json`.

2. **Real Photograph Fixtures (Privately Held Paper Bonds):**
   Place your physical bond photographs in `local-fixtures/real/images/`:
   ```bash
   mkdir -p local-fixtures/real/images
   cp /path/to/my-bonds/*.jpg local-fixtures/real/images/
   ```

3. **Create your verified real manifest (`local-fixtures/real/manifest.json`):**
   Copy the example template `local-fixtures.example.json` or `local-fixtures/real/manifest.example.json`:
   ```bash
   cp local-fixtures.example.json local-fixtures/real/manifest.json
   ```
   Open `local-fixtures/real/manifest.json` and adjust the ground-truth values (`series`, `denomination`, `serial`, `issueMonth`, `issueYear`, `datingStamp`) to match your physical documents based on manual verification (never from OCR output). Any omitted field is treated as "not evaluated".

4. **Verify Git ignores the private fixtures:**
   Confirm no private files or images are tracked by Git before testing:
   ```bash
   git check-ignore -v local-fixtures/synthetic/manifest.json
   git check-ignore -v local-fixtures/real/manifest.json
   git ls-files -- local-fixtures/
   git status --short
   ```
   *(Ensure `git ls-files -- local-fixtures/` returns zero output).*

5. **Run the regression tests:**
   ```bash
   xcodebuild test -project BondScanner.xcodeproj -scheme BondScanner
   ```

6. **Review Quality Metrics & Reports:**
   Each test run writes isolated, privacy-safe aggregate metrics for each dataset:
   - Synthetic fixtures:
     - `local-fixtures/reports/synthetic/latest.txt` & `latest.json`
     - `local-fixtures/reports/latest-synthetic.txt` & `latest-synthetic.json`
   - Real photographs:
     - `local-fixtures/reports/real/latest.txt` & `latest.json`
     - `local-fixtures/reports/latest-real.txt` & `latest-real.json`

---

## Architecture

- **`Sources/Models/`**: `BondRecord`, schema definitions, and OCR parsing types.
- **`Sources/Vision/`**: OCR extraction algorithms, denomination parsers, dating stamp detectors, and image quality evaluation.
- **`Sources/Camera/`**: Camera discovery, format negotiation (4K/1080p), and frame capture.
- **`Sources/Services/`**: SQLite persistence engine (`DatabaseManager`), automated JSON/CSV exporter (`StorageManager`), and operational logging.
- **`Sources/UI/`**: AppKit preview overlays, window controller, and review table.
- **`Tests/`**: Unit tests verifying serial number patterns, denominations, date algorithms, database transactions, and orientation invariance.

---

## Data Integrity, Exports & Backup

### Storage Architecture
- **Primary Store**: `~/BondScans/bonds.sqlite3` is the authoritative, WAL-backed, crash-resilient SQLite database.
- **Schema Versioning**: Managed via `PRAGMA user_version` (Version 1) with forward migration support.
- **Automatic Live Exports**: Every scan capture, edit, merge, or deletion automatically schedules a debounced background export to both `~/BondScans/records.json` and `~/BondScans/bonds.csv`. Exports are synchronously flushed on application termination.
- **Manual CSV Export**: Users can export a custom CSV snapshot at any time via the toolbar "Export CSV…" button. Formula characters (`=`, `+`, `-`, `@`) are automatically sanitized to prevent CSV injection.

### Photograph Preservation & Duplicate Safety
- **Zero Data Loss**: High-resolution original photographs (`photos/original_*.jpg`) are written and flushed to disk *before* database records are inserted.
- **Photo Preservation on DB Failure**: If a database write throws an error, the original photo remains untouched on disk.
- **Atomic Duplicate Consolidations**: Multi-record merges execute inside an immediate SQLite transaction. Duplicate captures only consolidate when serials are exact validated matches with zero conflicting fields. Near-matches are preserved as separate records for user review. Original photographs are never trashed during duplicate merges.

### Backup and Disaster Recovery
- **Online Backup**: Consistent point-in-time snapshots can be created safely using SQLite's native `VACUUM INTO` (`DatabaseManager.shared.backupDatabase(to:)`).
- **Restoration**: Restores verify foreign keys and database integrity before replacing live data.
- **Self-Healing Initialization**: If SQLite encounters unrecoverable disk corruption, the corrupted database file is safely archived to `~/BondScans_backups/corrupt_<timestamp>.sqlite3`, allowing a fresh database to initialize without crashing the application or losing photos.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
