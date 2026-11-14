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
- The directories `local-fixtures/bonds/` and `local-fixtures/reports/`, along with any `local-fixtures/manifest.json`, are strictly ignored by `.gitignore`.
- Fixture images, private manifests, and reports remain outside the `Sources/` and `Tests/` directories so XcodeGen will never bundle them into the application.
- Public CI environments without private fixtures automatically skip these tests cleanly (`XCTSkip`).
- Test assertion failures never print raw OCR, serial numbers, tax IDs, or owner names to test logs.

### Setting Up Private Fixtures

1. **Place your bond images in `local-fixtures/bonds/`:**
   Use neutral filenames such as `sample-01.jpg` through `sample-07.jpg`:
   ```bash
   mkdir -p local-fixtures/bonds local-fixtures/reports
   cp /path/to/my-bonds/*.jpg local-fixtures/bonds/
   ```

2. **Create your private manifest (`local-fixtures/manifest.json`):**
   Copy the provided public template `local-fixtures.example.json`:
   ```bash
   cp local-fixtures.example.json local-fixtures/manifest.json
   ```
   Open `local-fixtures/manifest.json` and adjust the ground-truth values (`series`, `denomination`, `serial`, `issueMonth`, `issueYear`, `datingStamp`) to match your physical documents. Any omitted field is treated as "not evaluated".

3. **Verify Git ignores the private fixtures:**
   Confirm no private files or images are tracked by Git before testing:
   ```bash
   git check-ignore -v local-fixtures/bonds/*.jpg
   git check-ignore -v local-fixtures/manifest.json
   git ls-files -- local-fixtures/
   git status --short
   ```
   *(Ensure `git ls-files -- local-fixtures/` returns zero output).*

4. **Run the regression tests:**
   ```bash
   xcodebuild test -project BondScanner.xcodeproj -scheme BondScanner
   ```

5. **Review Quality Metrics & Reports:**
   Each test run writes privacy-safe aggregate metrics to `local-fixtures/reports/`:
   - `local-fixtures/reports/latest.txt`: Human-readable summary table with accuracy percentages, false high-confidence field warnings, status checks, and timings.
   - `local-fixtures/reports/latest.json`: Structured machine-readable metrics.
   - `local-fixtures/reports/report-<timestamp>.txt` / `.json`: Historical runs.

---

## Architecture

- **`Sources/Models/`**: `BondRecord` and OCR parsing types.
- **`Sources/Vision/`**: OCR extraction algorithms, denomination parsers, and dating stamp detectors.
- **`Sources/Camera/`**: Camera discovery, format negotiation (4K/1080p), and frame capture.
- **`Sources/Services/`**: Local persistence (`~/Bondscans/`), CSV sanitizer, and operational logging.
- **`Sources/UI/`**: AppKit preview overlays, window controller, and review table.
- **`Tests/`**: Unit tests verifying serial number patterns, denominations, and date algorithms without requiring a webcam.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
