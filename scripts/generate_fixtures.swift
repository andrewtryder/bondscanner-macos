#!/usr/bin/env swift
import Foundation
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let syntheticDir = root.appendingPathComponent("local-fixtures/synthetic")
let imagesDir = syntheticDir.appendingPathComponent("images")
let manifestURL = syntheticDir.appendingPathComponent("manifest.json")

// SAFETY GUARDS:
// Ensure this script strictly writes ONLY to local-fixtures/synthetic
// and cannot accidentally overwrite real photographs or manifests.
let standardizedSynthetic = syntheticDir.standardizedFileURL.path
precondition(
    imagesDir.standardizedFileURL.path.hasPrefix(standardizedSynthetic),
    "SAFETY VIOLATION: Target images directory must be inside local-fixtures/synthetic"
)
precondition(
    manifestURL.standardizedFileURL.path.hasPrefix(standardizedSynthetic),
    "SAFETY VIOLATION: Target manifest must be inside local-fixtures/synthetic"
)
precondition(
    !imagesDir.standardizedFileURL.path.contains("local-fixtures/real"),
    "SAFETY VIOLATION: Cannot write to real fixtures directory"
)
precondition(
    !manifestURL.standardizedFileURL.path.contains("local-fixtures/real"),
    "SAFETY VIOLATION: Cannot write to real fixtures manifest"
)

try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

struct ManifestItem: Codable {
    let id: String
    let filename: String
    let series: String?
    let denomination: String?
    let serial: String?
    let issueMonth: String?
    let issueYear: String?
    let datingStamp: String?
    let expectedConfidence: [String: String]?
    let expectedStatus: String?
    let scenario: String?
    let notes: String?
}

func drawBond(
    filename: String,
    series: String,
    denom: String,
    denomWord: String,
    serial: String,
    monthStr: String,
    yearStr: String,
    upsideDown: Bool = false,
    portrait: Bool = false,
    stampText: String? = nil,
    micr: Bool = false
) {
    let width = portrait ? 600 : 1200
    let height = portrait ? 1200 : 600
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx

    if upsideDown {
        let transform = NSAffineTransform()
        transform.translateX(by: CGFloat(width), yBy: CGFloat(height))
        transform.rotate(byDegrees: 180)
        transform.concat()
    }

    // Background
    NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.91, alpha: 1.0).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Decorative Security Border
    NSColor(calibratedRed: 0.15, green: 0.30, blue: 0.18, alpha: 1.0).setStroke()
    let border = NSBezierPath(rect: NSRect(x: 25, y: 25, width: (portrait ? 600 : 1200) - 50, height: (portrait ? 1200 : 600) - 50))
    border.lineWidth = 6
    border.stroke()

    func drawText(_ str: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, color: NSColor = .black) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (str as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    func drawSerial(_ str: String, x: CGFloat, y: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .kern: 3.5
        ]
        (str as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    let baseX: CGFloat = portrait ? 30 : 0
    let baseY: CGFloat = portrait ? 300 : 0

    drawText("UNITED STATES SAVINGS BOND", x: baseX + 340, y: baseY + 520, size: 26, bold: true)
    drawText("THE UNITED STATES OF AMERICA", x: baseX + 370, y: baseY + 485, size: 18, bold: true)
    drawText("SERIES \(series)", x: baseX + 70, y: baseY + 460, size: 22, bold: true)
    drawText("$\(denom)", x: baseX + 70, y: baseY + 505, size: 34, bold: true)
    drawText("$\(denom)", x: baseX + (portrait ? 450 : 1050), y: baseY + 505, size: 34, bold: true)
    drawText("\(denomWord) DOLLARS", x: baseX + 330, y: baseY + 430, size: 22, bold: true)

    // Issue Date
    drawText("ISSUE DATE", x: baseX + (portrait ? 350 : 840), y: baseY + 420, size: 13, bold: true)
    drawText("\(monthStr) \(yearStr)", x: baseX + (portrait ? 350 : 840), y: baseY + 395, size: 18, bold: true)

    // Payee
    drawText("TO: JANE DOE", x: baseX + 180, y: baseY + 310, size: 16)
    drawText("123 MAIN STREET", x: baseX + 180, y: baseY + 285, size: 15)

    // Serial numbers
    drawSerial(serial, x: baseX + (portrait ? 350 : 840), y: baseY + 460)
    drawSerial(serial, x: baseX + (portrait ? 350 : 840), y: baseY + 120)

    if let stamp = stampText {
        drawText(stamp, x: baseX + (portrait ? 350 : 840), y: baseY + 360, size: 14, bold: true, color: NSColor.purple)
    }

    if micr {
        drawText("⑆000090007⑆   \(serial)   ⑈", x: baseX + 150, y: baseY + 40, size: 18, bold: true)
    }

    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.95])!
    let fileURL = imagesDir.appendingPathComponent(filename)
    precondition(
        fileURL.standardizedFileURL.path.hasPrefix(standardizedSynthetic),
        "SAFETY VIOLATION: Refusing to write image outside synthetic directory: \(fileURL.path)"
    )
    try! data.write(to: fileURL)
}

print("Generating synthetic fixtures for regression testing...")

var items: [ManifestItem] = []

// Sample 01: $25 Series E, upside-down
drawBond(filename: "sample-01.jpg", series: "E", denom: "25", denomWord: "TWENTY FIVE", serial: "Q0000000000E", monthStr: "JUL", yearStr: "1966", upsideDown: true, stampText: "12 AUG 1966")
items.append(ManifestItem(
    id: "sample-01",
    filename: "sample-01.jpg",
    series: "E",
    denomination: "25",
    serial: "Q0000000000E",
    issueMonth: "07",
    issueYear: "1966",
    datingStamp: "12 AUG 1966",
    expectedConfidence: ["serial": "high", "denomination": "high"],
    expectedStatus: "OK",
    scenario: "$25 Series E, upside-down image",
    notes: "Synthetic example: upside-down orientation, 10-digit Series E serial with high-confidence expected"
))

// Sample 02: $50 Series E, upside-down
drawBond(filename: "sample-02.jpg", series: "E", denom: "50", denomWord: "FIFTY", serial: "L000000000E", monthStr: "MAR", yearStr: "1972", upsideDown: true, stampText: "24 MAR 1972")
items.append(ManifestItem(
    id: "sample-02",
    filename: "sample-02.jpg",
    series: "E",
    denomination: "50",
    serial: "L000000000E",
    issueMonth: "03",
    issueYear: "1972",
    datingStamp: "24 MAR 1972",
    expectedConfidence: ["serial": "high", "denomination": "high"],
    expectedStatus: "OK",
    scenario: "$50 Series E, upside-down image",
    notes: "Synthetic example: upside-down 9-digit Series E serial"
))

// Sample 03: $100 Series E, landscape
drawBond(filename: "sample-03.jpg", series: "E", denom: "100", denomWord: "ONE HUNDRED", serial: "C000000000E", monthStr: "NOV", yearStr: "1975")
items.append(ManifestItem(
    id: "sample-03",
    filename: "sample-03.jpg",
    series: "E",
    denomination: "100",
    serial: "C000000000E",
    issueMonth: "11",
    issueYear: "1975",
    datingStamp: nil,
    expectedConfidence: ["serial": "high", "denomination": "high"],
    expectedStatus: "OK",
    scenario: "$100 Series E, landscape image",
    notes: "Synthetic example: standard landscape orientation, clear serial"
))

// Sample 04: $100 Series E
drawBond(filename: "sample-04.jpg", series: "E", denom: "100", denomWord: "ONE HUNDRED", serial: "C000000001E", monthStr: "MAY", yearStr: "1978")
items.append(ManifestItem(
    id: "sample-04",
    filename: "sample-04.jpg",
    series: "E",
    denomination: "100",
    serial: "C000000001E",
    issueMonth: "05",
    issueYear: "1978",
    datingStamp: nil,
    expectedConfidence: ["serial": "high"],
    expectedStatus: "OK",
    scenario: "$100 Series E, landscape image",
    notes: "Synthetic example: $100 Series E clear serial"
))

// Sample 05: $100 Series EE
drawBond(filename: "sample-05.jpg", series: "EE", denom: "100", denomWord: "ONE HUNDRED", serial: "C0000000000EE", monthStr: "AUG", yearStr: "1992")
items.append(ManifestItem(
    id: "sample-05",
    filename: "sample-05.jpg",
    series: "EE",
    denomination: "100",
    serial: "C0000000000EE",
    issueMonth: "08",
    issueYear: "1992",
    datingStamp: nil,
    expectedConfidence: ["serial": "high", "denomination": "high"],
    expectedStatus: "OK",
    scenario: "$100 Series EE, landscape image",
    notes: "Synthetic example: Series EE 10-digit serial"
))

// Sample 06: $100 Series EE with stamp
drawBond(filename: "sample-06.jpg", series: "EE", denom: "100", denomWord: "ONE HUNDRED", serial: "C0000000001EE", monthStr: "OCT", yearStr: "1995", stampText: "15 OCT 1995")
items.append(ManifestItem(
    id: "sample-06",
    filename: "sample-06.jpg",
    series: "EE",
    denomination: "100",
    serial: "C0000000001EE",
    issueMonth: "10",
    issueYear: "1995",
    datingStamp: nil,
    expectedConfidence: ["serial": "high"],
    expectedStatus: "OK",
    scenario: "$100 Series EE with dating stamp",
    notes: "Synthetic example: Series EE with stamp"
))

// Sample 07: $100 Series EE
drawBond(filename: "sample-07.jpg", series: "EE", denom: "100", denomWord: "ONE HUNDRED", serial: "C0000000002EE", monthStr: "APR", yearStr: "1999")
items.append(ManifestItem(
    id: "sample-07",
    filename: "sample-07.jpg",
    series: "EE",
    denomination: "100",
    serial: "C0000000002EE",
    issueMonth: "04",
    issueYear: "1999",
    datingStamp: nil,
    expectedConfidence: ["serial": "high", "denomination": "high"],
    expectedStatus: "OK",
    scenario: "$100 Series EE, landscape image",
    notes: "Synthetic example: standard landscape orientation Series EE"
))

// NEGATIVE CASES (Requirement 7)
// sample-neg-01: Series E with EE suffix (mismatch)
drawBond(filename: "sample-neg-01.jpg", series: "E", denom: "100", denomWord: "ONE HUNDRED", serial: "C0000000000EE", monthStr: "MAY", yearStr: "1972")
items.append(ManifestItem(
    id: "sample-neg-01",
    filename: "sample-neg-01.jpg",
    series: "E",
    denomination: "100",
    serial: nil, // Serial should not be validated as a valid Series E serial
    issueMonth: "05",
    issueYear: "1972",
    datingStamp: nil,
    expectedConfidence: nil,
    expectedStatus: "REVIEW",
    scenario: "Negative: Series E bond with invalid EE serial suffix",
    notes: "Series E requires suffix E. Serial ending in EE must be flagged for REVIEW"
))

// sample-neg-02: Series EE with issue year 1974 (date contradiction: EE began 1980)
drawBond(filename: "sample-neg-02.jpg", series: "EE", denom: "100", denomWord: "ONE HUNDRED", serial: "C0000000000EE", monthStr: "APR", yearStr: "1974")
items.append(ManifestItem(
    id: "sample-neg-02",
    filename: "sample-neg-02.jpg",
    series: "EE",
    denomination: "100",
    serial: "C0000000000EE",
    issueMonth: "04",
    issueYear: "1974",
    datingStamp: nil,
    expectedConfidence: nil,
    expectedStatus: "REVIEW",
    scenario: "Negative: Series EE bond with impossible pre-1980 issue year (1974)",
    notes: "Series EE was introduced in 1980. Issue date 1974 violates historical offering era"
))

// sample-neg-03: Truncated serial (missing digits: only 7 digits)
drawBond(filename: "sample-neg-03.jpg", series: "EE", denom: "100", denomWord: "ONE HUNDRED", serial: "C000000EE", monthStr: "AUG", yearStr: "1994")
items.append(ManifestItem(
    id: "sample-neg-03",
    filename: "sample-neg-03.jpg",
    series: "EE",
    denomination: "100",
    serial: nil,
    issueMonth: "08",
    issueYear: "1994",
    datingStamp: nil,
    expectedConfidence: nil,
    expectedStatus: "REVIEW",
    scenario: "Negative: Truncated 7-digit serial on Series EE",
    notes: "Missing digits are never invented. Truncated serial must fail syntactic validation"
))

// AMBIGUOUS CASES (Requirement 7)
// sample-amb-01: Prefix C with $50 denomination (prefix/denomination warning)
drawBond(filename: "sample-amb-01.jpg", series: "EE", denom: "50", denomWord: "FIFTY", serial: "C0000000000EE", monthStr: "JUN", yearStr: "1993")
items.append(ManifestItem(
    id: "sample-amb-01",
    filename: "sample-amb-01.jpg",
    series: "EE",
    denomination: "50",
    serial: "C0000000000EE",
    issueMonth: "06",
    issueYear: "1993",
    datingStamp: nil,
    expectedConfidence: nil,
    expectedStatus: "OK",
    scenario: "Ambiguous: Prefix C ($100 expected) on $50 denomination",
    notes: "Prefix/denomination inconsistency warning; non-fatal historical anomaly flagged for REVIEW"
))

// sample-amb-02: Series EE with experimental MICR line (March 1985+ compatible)
drawBond(filename: "sample-amb-02.jpg", series: "EE", denom: "100", denomWord: "ONE HUNDRED", serial: "C0000000000EE", monthStr: "MAY", yearStr: "1990", micr: true)
items.append(ManifestItem(
    id: "sample-amb-02",
    filename: "sample-amb-02.jpg",
    series: "EE",
    denomination: "100",
    serial: "C0000000000EE",
    issueMonth: "05",
    issueYear: "1990",
    datingStamp: nil,
    expectedConfidence: ["serial": "high", "denomination": "high"],
    expectedStatus: "OK",
    scenario: "Experimental MICR: Post-March 1985 Series EE with machine-readable bottom clear band",
    notes: "Validates independent bottom-band MICR line routing number (000090007) and serial corroboration"
))

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let jsonData = try! encoder.encode(items)
precondition(
    manifestURL.standardizedFileURL.path.hasPrefix(standardizedSynthetic),
    "SAFETY VIOLATION: Refusing to write manifest outside synthetic directory: \(manifestURL.path)"
)
try! jsonData.write(to: manifestURL, options: .atomic)

print("Generated \(items.count) fixture items and images in local-fixtures/synthetic/images/")
