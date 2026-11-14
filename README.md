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

You can build and run Bond Scanner either via Xcode or directly from the Terminal.

### Option A: Using Xcode (Recommended for Development)

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to maintain a clean, declarative project configuration (`project.yml`).

1. Install XcodeGen (if not already installed):
   ```bash
   brew install xcodegen
   ```
2. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
3. Open `BondScanner.xcodeproj` in Xcode and hit **Cmd+R** to run.
   *The project is pre-configured with local ad-hoc code signing ("Sign to Run Locally"), so no paid Apple Developer team certificate is required.*

4. Run unit tests in Xcode with **Cmd+U** or via the CLI:
   ```bash
   xcodebuild test -project BondScanner.xcodeproj -scheme BondScanner
   ```

### Option B: Using Terminal (No Xcode IDE required)

You only need macOS with Apple Command Line Tools installed (`xcode-select --install`).

- **Staging Build**:
  ```bash
  ./build.sh --staging
  ```
- **Launch Application**:
  ```bash
  ./bondscan.command
  ```

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
