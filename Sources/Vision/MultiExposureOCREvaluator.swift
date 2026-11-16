import CoreGraphics
import Foundation

/// Evaluates and reconciles OCR readings across multiple exposure captures.
///
/// Principles:
/// 1. Baseline (0.0 EV) exposure is primary.
/// 2. Missing or uncertain fields in baseline may be enriched by confident reads from bracketed exposures.
/// 3. Conflicting valid readings between exposures are preserved as explicit review reasons (never silently resolved by blind voting).
/// 4. Never invent values for missing fields.
/// 5. Never overwrite human-confirmed fields.
/// 6. Complete provenance is tracked in fieldPhoto and fieldSource.
enum MultiExposureOCREvaluator {
    static let importantFields = [
        "series", "serial", "denomination", "issueMonth", "issueYear",
        "owner", "secondName", "address", "issuingAgent", "datingStamp",
    ]

    struct EvaluationResult {
        let reconciledRecord: BondRecord
        let conflictingFields: [String: (baseline: String, alternate: String, biasEV: Float)]
        let enrichedFields: [String: (value: String, biasEV: Float)]
    }

    static func evaluate(
        baselineResult: OCRResult,
        baselinePhotoRel: String,
        bracketedResults: [(biasEV: Float, result: OCRResult, photoRel: String)],
        baseRecord: BondRecord
    ) -> EvaluationResult {
        var record = baseRecord
        let userConfirmed = Set(record.userConfirmedFields ?? [])

        // Populate baseline values first
        let baseRec = baselineResult.record
        if !userConfirmed.contains("series") {
            record.series = baseRec.series
        }
        if !userConfirmed.contains("serial") {
            record.serial = baseRec.serial
        }
        if !userConfirmed.contains("denomination") {
            record.denomination = baseRec.denomination
        }
        if !userConfirmed.contains("issueMonth") {
            record.issueMonth = baseRec.issueMonth
        }
        if !userConfirmed.contains("issueYear") {
            record.issueYear = baseRec.issueYear
        }
        if !userConfirmed.contains("owner") {
            record.owner = baseRec.owner
        }
        if !userConfirmed.contains("secondName") {
            record.secondName = baseRec.secondName
        }
        if !userConfirmed.contains("secondRole") {
            record.secondRole = baseRec.secondRole
        }
        if !userConfirmed.contains("address") {
            record.address = baseRec.address
        }
        if !userConfirmed.contains("taxID") {
            record.taxID = baseRec.taxID
        }
        if !userConfirmed.contains("issuingAgent") {
            record.issuingAgent = baseRec.issuingAgent
        }
        if !userConfirmed.contains("datingStamp") {
            record.datingStamp = baseRec.datingStamp
        }
        record.rawOCR = baseRec.rawOCR

        var fieldPhoto = record.fieldPhoto ?? [:]
        var fieldSource = record.fieldSource ?? [:]
        var fieldConfidence = record.fieldConfidence ?? baseRec.fieldConfidence ?? [:]

        // Set baseline photo for all populated baseline fields
        for field in importantFields {
            let val = getFieldValue(record, field: field)
            if !val.isEmpty, fieldPhoto[field] == nil {
                fieldPhoto[field] = baselinePhotoRel
                fieldSource[field] = "exposure_0.0EV"
            }
        }

        var conflicting: [String: (baseline: String, alternate: String, biasEV: Float)] = [:]
        var enriched: [String: (value: String, biasEV: Float)] = [:]
        var reviewReasons = Set(record.reviewReasons ?? [])

        for bracket in bracketedResults {
            let altRec = bracket.result.record
            let bias = bracket.biasEV
            let photoPath = bracket.photoRel

            // Append additional OCR text if new content is present
            if !altRec.rawOCR.isEmpty, !record.rawOCR.contains(altRec.rawOCR.prefix(40)) {
                let header = "--- Exposure \(String(format: "%.1f", bias)) EV ---"
                record.additionalOCR = (record.additionalOCR == nil)
                    ? "\(header)\n\(altRec.rawOCR)"
                    : "\(record.additionalOCR!)\n\(header)\n\(altRec.rawOCR)"
            }

            for field in importantFields {
                guard !userConfirmed.contains(field) else { continue }
                let baseVal = getFieldValue(record, field: field).trimmingCharacters(in: .whitespacesAndNewlines)
                let altVal = getFieldValue(altRec, field: field).trimmingCharacters(in: .whitespacesAndNewlines)

                guard !altVal.isEmpty else { continue }

                let altConf = altRec.fieldConfidence?[field] ?? "high"
                let baseConf = fieldConfidence[field] ?? ""

                if baseVal.isEmpty || baseConf == "uncertain" {
                    // Enrich missing or uncertain field from confident bracketed read
                    setFieldValue(&record, field: field, value: altVal)
                    fieldPhoto[field] = photoPath
                    fieldSource[field] = "exposure_\(String(format: "%+.1f", bias))EV"
                    fieldConfidence[field] = altConf
                    enriched[field] = (altVal, bias)
                } else if baseVal != altVal {
                    // Both have valid but differing values: record conflict
                    conflicting[field] = (baseVal, altVal, bias)
                    let reason = "exposure_conflict: \(field): baseline '\(baseVal)' vs exposure \(String(format: "%+.1f", bias))EV '\(altVal)'"
                    reviewReasons.insert(reason)
                }
            }
        }

        record.fieldPhoto = fieldPhoto.isEmpty ? nil : fieldPhoto
        record.fieldSource = fieldSource.isEmpty ? nil : fieldSource
        record.fieldConfidence = fieldConfidence.isEmpty ? nil : fieldConfidence
        record.reviewReasons = reviewReasons.isEmpty ? nil : Array(reviewReasons).sorted()

        if record.status == "PROCESSING" {
            record.status = ""
        }

        applyRequiredStatus(&record)

        return EvaluationResult(
            reconciledRecord: record,
            conflictingFields: conflicting,
            enrichedFields: enriched
        )
    }

    private static func getFieldValue(_ record: BondRecord, field: String) -> String {
        switch field {
        case "series": return record.series
        case "serial": return record.serial
        case "denomination": return record.denomination
        case "issueMonth": return record.issueMonth
        case "issueYear": return record.issueYear
        case "owner": return record.owner
        case "secondName": return record.secondName
        case "address": return record.address
        case "issuingAgent": return record.issuingAgent
        case "datingStamp": return record.datingStamp
        default: return ""
        }
    }

    private static func setFieldValue(_ record: inout BondRecord, field: String, value: String) {
        switch field {
        case "series": record.series = value
        case "serial": record.serial = value
        case "denomination": record.denomination = value
        case "issueMonth": record.issueMonth = value
        case "issueYear": record.issueYear = value
        case "owner": record.owner = value
        case "secondName": record.secondName = value
        case "address": record.address = value
        case "issuingAgent": record.issuingAgent = value
        case "datingStamp": record.datingStamp = value
        default: break
        }
    }
}
