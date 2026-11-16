import CoreGraphics
import Foundation

/// Evaluates and reconciles OCR readings across multiple exposure captures.
///
/// Principles:
/// 1. Baseline (0.0 EV) exposure is primary.
/// 2. Missing or uncertain fields in baseline may be enriched ONLY by validated, high-confidence reads from bracketed exposures.
/// 3. Missing confidence metadata defaults to "uncertain" (never "high").
/// 4. Conflicting readings between exposures are preserved as explicit review reasons (never silently resolved by blind voting).
/// 5. Never invent values for missing fields.
/// 6. Never overwrite human-confirmed fields.
/// 7. Complete provenance is tracked in fieldPhoto, fieldSource, and fieldCaptureId.
enum MultiExposureOCREvaluator {
    static let importantFields = [
        "series", "serial", "denomination", "issueMonth", "issueYear",
        "owner", "secondName", "address", "issuingAgent", "datingStamp",
    ]

    static let coreValidatedFields: Set<String> = [
        "series", "serial", "denomination", "issueMonth", "issueYear",
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

        // Populate baseline values first for unconfirmed fields
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
        var fieldConfidence = record.fieldConfidence ?? [:]
        if let baseConfMap = baseRec.fieldConfidence {
            for (k, v) in baseConfMap where !userConfirmed.contains(k) {
                fieldConfidence[k] = v
            }
        }
        var previousExtracted = record.previousExtracted ?? [:]

        // Set baseline provenance and normalized confidence for all populated baseline fields
        for field in importantFields {
            let val = getFieldValue(record, field: field).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !val.isEmpty else { continue }
            if fieldPhoto[field] == nil {
                fieldPhoto[field] = baselinePhotoRel
                fieldSource[field] = "exposure_0.0EV"
            }
            if !userConfirmed.contains(field) {
                let isHigh = isHighConfidenceReading(
                    field: field,
                    value: val,
                    in: baseRec,
                    fallbackConfidenceMap: fieldConfidence,
                    context: (series: record.series, month: record.issueMonth)
                )
                fieldConfidence[field] = isHigh ? "high" : "uncertain"
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

                let effectiveSeries = !record.series.isEmpty ? record.series : altRec.series
                let effectiveMonth = !record.issueMonth.isEmpty ? record.issueMonth : altRec.issueMonth
                let altValidated = isFieldValueValidated(
                    field: field,
                    value: altVal,
                    effectiveSeries: effectiveSeries,
                    effectiveMonth: effectiveMonth
                )
                let altIsHigh = isHighConfidenceReading(
                    field: field,
                    value: altVal,
                    in: altRec,
                    fallbackConfidenceMap: nil,
                    context: (series: effectiveSeries, month: effectiveMonth)
                )
                let baseConf = resolvedConfidence(for: field, in: fieldConfidence)
                let baseIsHigh = (baseConf == "high")

                if coreValidatedFields.contains(field) {
                    // Core fields require validated readings; never promote or substitute unvalidated or uncertain reads.
                    guard altValidated else { continue }

                    if baseVal.isEmpty {
                        // Enrich missing core field ONLY when alternate reading is validated AND high confidence
                        guard altIsHigh else { continue }
                        setFieldValue(&record, field: field, value: altVal)
                        fieldPhoto[field] = photoPath
                        fieldSource[field] = "exposure_\(String(format: "%+.1f", bias))EV"
                        fieldConfidence[field] = "high"
                        enriched[field] = (altVal, bias)
                    } else if !baseIsHigh {
                        // Baseline has an uncertain reading
                        if baseVal == altVal {
                            if altIsHigh {
                                fieldConfidence[field] = "high"
                                fieldPhoto[field] = photoPath
                                fieldSource[field] = "exposure_\(String(format: "%+.1f", bias))EV"
                                enriched[field] = (altVal, bias)
                            } else {
                                fieldConfidence[field] = "uncertain"
                            }
                        } else if altIsHigh {
                            // Confident, validated alternate reading replaces uncertain baseline reading
                            if previousExtracted[field] == nil {
                                previousExtracted[field] = baseVal
                            }
                            setFieldValue(&record, field: field, value: altVal)
                            fieldPhoto[field] = photoPath
                            fieldSource[field] = "exposure_\(String(format: "%+.1f", bias))EV"
                            fieldConfidence[field] = "high"
                            enriched[field] = (altVal, bias)
                        } else {
                            // Both baseline and alternate are uncertain and disagree: retain baseline, keep uncertain, flag conflict
                            fieldConfidence[field] = "uncertain"
                            conflicting[field] = (baseVal, altVal, bias)
                            let reason = "exposure_conflict: \(field): baseline '\(baseVal)' vs exposure \(String(format: "%+.1f", bias))EV '\(altVal)'"
                            reviewReasons.insert(reason)
                        }
                    } else if baseVal != altVal {
                        // Baseline is high confidence and alternate differs: preserve baseline and record conflict
                        conflicting[field] = (baseVal, altVal, bias)
                        let reason = "exposure_conflict: \(field): baseline '\(baseVal)' vs exposure \(String(format: "%+.1f", bias))EV '\(altVal)'"
                        reviewReasons.insert(reason)
                    }
                } else {
                    // Ancillary text fields (owner, secondName, address, issuingAgent, datingStamp)
                    if baseVal.isEmpty {
                        setFieldValue(&record, field: field, value: altVal)
                        fieldPhoto[field] = photoPath
                        fieldSource[field] = "exposure_\(String(format: "%+.1f", bias))EV"
                        fieldConfidence[field] = altIsHigh ? "high" : "uncertain"
                        enriched[field] = (altVal, bias)
                    } else if !baseIsHigh, altIsHigh, baseVal != altVal {
                        if previousExtracted[field] == nil {
                            previousExtracted[field] = baseVal
                        }
                        setFieldValue(&record, field: field, value: altVal)
                        fieldPhoto[field] = photoPath
                        fieldSource[field] = "exposure_\(String(format: "%+.1f", bias))EV"
                        fieldConfidence[field] = "high"
                        enriched[field] = (altVal, bias)
                    } else if baseVal != altVal {
                        conflicting[field] = (baseVal, altVal, bias)
                        let reason = "exposure_conflict: \(field): baseline '\(baseVal)' vs exposure \(String(format: "%+.1f", bias))EV '\(altVal)'"
                        reviewReasons.insert(reason)
                    }
                }
            }
        }

        // Synchronize composite "issueDate" confidence with issueMonth & issueYear
        if !userConfirmed.contains("issueDate") {
            let hasMonth = !record.issueMonth.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasYear = !record.issueYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasMonth || hasYear {
                let monthHigh = fieldConfidence["issueMonth"] == "high"
                let yearHigh = fieldConfidence["issueYear"] == "high"
                let dateConsistent = hasMonth && hasYear && isFieldValueValidated(
                    field: "issueYear",
                    value: record.issueYear,
                    effectiveSeries: record.series,
                    effectiveMonth: record.issueMonth
                )
                fieldConfidence["issueDate"] = (monthHigh && yearHigh && dateConsistent) ? "high" : "uncertain"
            } else {
                fieldConfidence["issueDate"] = nil
            }
        }

        record.previousExtracted = previousExtracted.isEmpty ? nil : previousExtracted
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

    private static func resolvedConfidence(for field: String, in map: [String: String]?) -> String {
        guard let map = map else { return "uncertain" }
        if let direct = map[field], !direct.isEmpty {
            return direct
        }
        if field == "issueMonth" || field == "issueYear", let dateConf = map["issueDate"], !dateConf.isEmpty {
            return dateConf
        }
        return "uncertain"
    }

    private static func isFieldValueValidated(
        field: String,
        value: String,
        effectiveSeries: String,
        effectiveMonth: String
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch field {
        case "series":
            return validSeriesValues().contains(trimmed.uppercased())
        case "serial":
            return !validatedSerial(trimmed, series: effectiveSeries).value.isEmpty
        case "denomination":
            let clean = trimmed.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
            return validFaceValues(for: effectiveSeries).contains(clean)
        case "issueMonth":
            return monthNumber(trimmed) != nil
        case "issueYear":
            guard trimmed.count == 4, let yearInt = Int(trimmed), (1935 ... 2026).contains(yearInt) else {
                return false
            }
            if !effectiveSeries.isEmpty {
                let consistency = BondValidationRules.validateSeriesIssueDate(
                    series: effectiveSeries,
                    month: effectiveMonth,
                    year: trimmed
                )
                return consistency.status != .inconsistent
            }
            return true
        default:
            return true
        }
    }

    private static func isHighConfidenceReading(
        field: String,
        value: String,
        in record: BondRecord,
        fallbackConfidenceMap: [String: String]?,
        context: (series: String, month: String)
    ) -> Bool {
        let explicitConf: String
        if let direct = record.fieldConfidence?[field], !direct.isEmpty {
            explicitConf = direct
        } else if field == "issueMonth" || field == "issueYear",
                  let dateConf = record.fieldConfidence?["issueDate"], !dateConf.isEmpty
        {
            explicitConf = dateConf
        } else if let fallback = fallbackConfidenceMap {
            explicitConf = resolvedConfidence(for: field, in: fallback)
        } else {
            // Missing confidence metadata defaults to "uncertain", never "high"
            explicitConf = "uncertain"
        }

        guard explicitConf == "high", isFieldValueValidated(
            field: field,
            value: value,
            effectiveSeries: context.series,
            effectiveMonth: context.month
        ) else {
            return false
        }
        if field == "serial" {
            return validatedSerial(value, series: context.series).isHigh
        }
        return true
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
