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

    private static let nonDateImportantFields = [
        "series", "serial", "denomination",
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

    private struct ReconciliationContext {
        var record: BondRecord
        var fieldPhoto: [String: String]
        var fieldSource: [String: String]
        var fieldConfidence: [String: String]
        var previousExtracted: [String: String]
        var conflicting: [String: (baseline: String, alternate: String, biasEV: Float)] = [:]
        var enriched: [String: (value: String, biasEV: Float)] = [:]
        var reviewReasons: Set<String>
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

            for field in nonDateImportantFields {
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
                            // Confident, validated alternate reading replaces uncertain baseline reading,
                            // but the disagreement is recorded and requires human review.
                            if previousExtracted[field] == nil {
                                previousExtracted[field] = baseVal
                            }
                            setFieldValue(&record, field: field, value: altVal)
                            fieldPhoto[field] = photoPath
                            fieldSource[field] = "exposure_\(String(format: "%+.1f", bias))EV"
                            fieldConfidence[field] = "uncertain"
                            enriched[field] = (altVal, bias)
                            conflicting[field] = (baseVal, altVal, bias)
                            let reason = "exposure_conflict: \(field): baseline '\(baseVal)' vs exposure \(String(format: "%+.1f", bias))EV '\(altVal)'"
                            reviewReasons.insert(reason)
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

        var dateContext = ReconciliationContext(
            record: record,
            fieldPhoto: fieldPhoto,
            fieldSource: fieldSource,
            fieldConfidence: fieldConfidence,
            previousExtracted: previousExtracted,
            conflicting: conflicting,
            enriched: enriched,
            reviewReasons: reviewReasons
        )
        reconcileIssueDate(
            context: &dateContext,
            bracketedResults: bracketedResults,
            userConfirmed: userConfirmed
        )
        record = dateContext.record
        fieldPhoto = dateContext.fieldPhoto
        fieldSource = dateContext.fieldSource
        fieldConfidence = dateContext.fieldConfidence
        previousExtracted = dateContext.previousExtracted
        conflicting = dateContext.conflicting
        enriched = dateContext.enriched
        reviewReasons = dateContext.reviewReasons

        // Synchronize composite "issueDate" confidence with issueMonth & issueYear
        if !userConfirmed.contains("issueDate") {
            let hasMonth = !record.issueMonth.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasYear = !record.issueYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasMonth || hasYear {
                let monthHigh = fieldConfidence["issueMonth"] == "high"
                let yearHigh = fieldConfidence["issueYear"] == "high"
                let sameExposure = fieldPhoto["issueMonth"] == fieldPhoto["issueYear"]
                    && fieldSource["issueMonth"] == fieldSource["issueYear"]
                let dateConsistent = hasMonth && hasYear && isFieldValueValidated(
                    field: "issueYear",
                    value: record.issueYear,
                    effectiveSeries: record.series,
                    effectiveMonth: record.issueMonth
                )
                fieldConfidence["issueDate"] = (monthHigh && yearHigh && sameExposure && dateConsistent) ? "high" : "uncertain"
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

    private static func reconcileIssueDate(
        context: inout ReconciliationContext,
        bracketedResults: [(biasEV: Float, result: OCRResult, photoRel: String)],
        userConfirmed: Set<String>
    ) {
        let canEditMonth = !userConfirmed.contains("issueMonth") && !userConfirmed.contains("issueDate")
        let canEditYear = !userConfirmed.contains("issueYear") && !userConfirmed.contains("issueDate")
        guard canEditMonth || canEditYear else { return }

        let baseMonth = context.record.issueMonth.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseYear = context.record.issueYear.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Check all brackets for any conflicting validated month/year readings against non-empty baseline.
        for bracket in bracketedResults {
            let altRec = bracket.result.record
            let bias = bracket.biasEV
            let effectiveSeries = !context.record.series.isEmpty ? context.record.series : altRec.series
            let altMonth = altRec.issueMonth.trimmingCharacters(in: .whitespacesAndNewlines)
            let altYear = altRec.issueYear.trimmingCharacters(in: .whitespacesAndNewlines)

            if canEditMonth, !baseMonth.isEmpty, !altMonth.isEmpty,
               isFieldValueValidated(field: "issueMonth", value: altMonth, effectiveSeries: effectiveSeries, effectiveMonth: altMonth),
               baseMonth != altMonth
            {
                context.conflicting["issueMonth"] = (baseMonth, altMonth, bias)
                context.reviewReasons.insert("exposure_conflict: issueMonth: baseline '\(baseMonth)' vs exposure \(String(format: "%+.1f", bias))EV '\(altMonth)'")
                context.fieldConfidence["issueMonth"] = "uncertain"
            }
            let effectiveMonth = !baseMonth.isEmpty ? baseMonth : altMonth
            if canEditYear, !baseYear.isEmpty, !altYear.isEmpty,
               isFieldValueValidated(field: "issueYear", value: altYear, effectiveSeries: effectiveSeries, effectiveMonth: effectiveMonth),
               baseYear != altYear
            {
                context.conflicting["issueYear"] = (baseYear, altYear, bias)
                context.reviewReasons.insert("exposure_conflict: issueYear: baseline '\(baseYear)' vs exposure \(String(format: "%+.1f", bias))EV '\(altYear)'")
                context.fieldConfidence["issueYear"] = "uncertain"
            }
        }

        let baseMonthHigh = resolvedConfidence(for: "issueMonth", in: context.fieldConfidence) == "high"
        let baseYearHigh = resolvedConfidence(for: "issueYear", in: context.fieldConfidence) == "high"
        let basePairValid = !baseMonth.isEmpty && !baseYear.isEmpty && isFieldValueValidated(
            field: "issueMonth", value: baseMonth, effectiveSeries: context.record.series, effectiveMonth: baseMonth
        ) && isFieldValueValidated(
            field: "issueYear", value: baseYear, effectiveSeries: context.record.series, effectiveMonth: baseMonth
        )
        let basePairHigh = basePairValid && baseMonthHigh && baseYearHigh

        // Baseline already has a complete, validated, high-confidence pair.
        if basePairHigh {
            return
        }

        // 2. Prefer a complete, validated, high-confidence (month, year) pair from a single bracket exposure.
        if canEditMonth, canEditYear {
            for bracket in bracketedResults {
                let altRec = bracket.result.record
                let bias = bracket.biasEV
                let photoPath = bracket.photoRel
                let effectiveSeries = !context.record.series.isEmpty ? context.record.series : altRec.series
                let altMonth = altRec.issueMonth.trimmingCharacters(in: .whitespacesAndNewlines)
                let altYear = altRec.issueYear.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !altMonth.isEmpty, !altYear.isEmpty else { continue }
                let altMonthValid = isFieldValueValidated(
                    field: "issueMonth", value: altMonth, effectiveSeries: effectiveSeries, effectiveMonth: altMonth
                )
                let altYearValid = isFieldValueValidated(
                    field: "issueYear", value: altYear, effectiveSeries: effectiveSeries, effectiveMonth: altMonth
                )
                let altMonthHigh = isHighConfidenceReading(
                    field: "issueMonth", value: altMonth, in: altRec, fallbackConfidenceMap: nil, context: (series: effectiveSeries, month: altMonth)
                )
                let altYearHigh = isHighConfidenceReading(
                    field: "issueYear", value: altYear, in: altRec, fallbackConfidenceMap: nil, context: (series: effectiveSeries, month: altMonth)
                )
                guard altMonthValid, altYearValid, altMonthHigh, altYearHigh else { continue }

                let source = "exposure_\(String(format: "%+.1f", bias))EV"
                if !baseMonth.isEmpty, baseMonth != altMonth, context.previousExtracted["issueMonth"] == nil {
                    context.previousExtracted["issueMonth"] = baseMonth
                }
                if !baseYear.isEmpty, baseYear != altYear, context.previousExtracted["issueYear"] == nil {
                    context.previousExtracted["issueYear"] = baseYear
                }
                context.record.issueMonth = altMonth
                context.record.issueYear = altYear
                context.fieldPhoto["issueMonth"] = photoPath
                context.fieldPhoto["issueYear"] = photoPath
                context.fieldSource["issueMonth"] = source
                context.fieldSource["issueYear"] = source
                context.enriched["issueMonth"] = (altMonth, bias)
                context.enriched["issueYear"] = (altYear, bias)

                let hasConflict = context.conflicting["issueMonth"] != nil || context.conflicting["issueYear"] != nil
                context.fieldConfidence["issueMonth"] = hasConflict ? "uncertain" : "high"
                context.fieldConfidence["issueYear"] = hasConflict ? "uncertain" : "high"
                return
            }
        }

        // 3. No single exposure provided a complete pair; enrich missing components cautiously.
        for bracket in bracketedResults {
            let altRec = bracket.result.record
            let bias = bracket.biasEV
            let photoPath = bracket.photoRel
            let source = "exposure_\(String(format: "%+.1f", bias))EV"
            let effectiveSeries = !context.record.series.isEmpty ? context.record.series : altRec.series

            if canEditMonth {
                let altMonth = altRec.issueMonth.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentMonth = context.record.issueMonth.trimmingCharacters(in: .whitespacesAndNewlines)
                if !altMonth.isEmpty,
                   isFieldValueValidated(field: "issueMonth", value: altMonth, effectiveSeries: effectiveSeries, effectiveMonth: altMonth),
                   isHighConfidenceReading(field: "issueMonth", value: altMonth, in: altRec, fallbackConfidenceMap: nil, context: (series: effectiveSeries, month: altMonth))
                {
                    if currentMonth.isEmpty {
                        context.record.issueMonth = altMonth
                        context.fieldPhoto["issueMonth"] = photoPath
                        context.fieldSource["issueMonth"] = source
                        context.fieldConfidence["issueMonth"] = "high"
                        context.enriched["issueMonth"] = (altMonth, bias)
                    } else if currentMonth == altMonth, context.fieldConfidence["issueMonth"] != "high", context.conflicting["issueMonth"] == nil {
                        context.fieldPhoto["issueMonth"] = photoPath
                        context.fieldSource["issueMonth"] = source
                        context.fieldConfidence["issueMonth"] = "high"
                        context.enriched["issueMonth"] = (altMonth, bias)
                    }
                }
            }

            if canEditYear {
                let altYear = altRec.issueYear.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentYear = context.record.issueYear.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveMonth = !context.record.issueMonth.isEmpty ? context.record.issueMonth : altRec.issueMonth
                if !altYear.isEmpty,
                   isFieldValueValidated(field: "issueYear", value: altYear, effectiveSeries: effectiveSeries, effectiveMonth: effectiveMonth),
                   isHighConfidenceReading(field: "issueYear", value: altYear, in: altRec, fallbackConfidenceMap: nil, context: (series: effectiveSeries, month: effectiveMonth))
                {
                    if currentYear.isEmpty {
                        context.record.issueYear = altYear
                        context.fieldPhoto["issueYear"] = photoPath
                        context.fieldSource["issueYear"] = source
                        context.fieldConfidence["issueYear"] = "high"
                        context.enriched["issueYear"] = (altYear, bias)
                    } else if currentYear == altYear, context.fieldConfidence["issueYear"] != "high", context.conflicting["issueYear"] == nil {
                        context.fieldPhoto["issueYear"] = photoPath
                        context.fieldSource["issueYear"] = source
                        context.fieldConfidence["issueYear"] = "high"
                        context.enriched["issueYear"] = (altYear, bias)
                    }
                }
            }
        }

        // If month and year were assembled from different exposures, retain uncertainty and require confirmation.
        let finalMonth = context.record.issueMonth.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalYear = context.record.issueYear.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalMonth.isEmpty, !finalYear.isEmpty {
            let monthSrc = context.fieldSource["issueMonth"] ?? ""
            let yearSrc = context.fieldSource["issueYear"] ?? ""
            let monthPhoto = context.fieldPhoto["issueMonth"] ?? ""
            let yearPhoto = context.fieldPhoto["issueYear"] ?? ""
            if monthSrc != yearSrc || monthPhoto != yearPhoto {
                context.fieldConfidence["issueMonth"] = "uncertain"
                context.fieldConfidence["issueYear"] = "uncertain"
                context.reviewReasons.insert("exposure_split_date: issueMonth (\(monthSrc)) and issueYear (\(yearSrc)) combined from different exposures")
            }
        }
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
