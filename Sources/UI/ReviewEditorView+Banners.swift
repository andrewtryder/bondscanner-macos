import AppKit
import Foundation

extension ReviewEditorView {
    func recordContainsDraftChanges(_ r: BondRecord) -> Bool {
        for (field, editVal) in userEdits {
            let recVal: String
            switch field {
            case "series": recVal = r.series
            case "serial": recVal = r.serial
            case "denomination": recVal = r.denomination
            case "issueMonth": recVal = r.issueMonth
            case "issueYear": recVal = r.issueYear
            case "owner": recVal = r.owner
            case "secondName": recVal = r.secondName
            case "secondRole": recVal = r.secondRole
            case "address": recVal = r.address
            case "taxID": recVal = r.taxID
            case "issuingAgent": recVal = r.issuingAgent
            case "datingStamp": recVal = r.datingStamp
            case "notes": recVal = r.notes
            default: recVal = ""
            }
            if recVal != editVal {
                return false
            }
        }
        let recConfirmed = Set(r.userConfirmedFields ?? [])
        if !confirmedFields.isSubset(of: recConfirmed) {
            return false
        }
        let recResolved = Set(r.resolvedReviewReasons ?? [])
        if !resolvedReasons.isSubset(of: recResolved) {
            return false
        }
        let recAck = Set(r.acknowledgedWarnings ?? [])
        if !acknowledgedWarnings.isSubset(of: recAck) {
            return false
        }
        return true
    }

    func showConflictBanner(conflicts: [(field: String, yourEdit: String, externalVal: String)], externalRecord: BondRecord) {
        self.latestExternalRecord = externalRecord
        conflictStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        conflictBox.isHidden = false

        let header = NSTextField(labelWithString: "⚠️ Concurrent External Update Detected (\(conflicts.count) conflicting field\(conflicts.count == 1 ? "" : "s")):")
        header.font = .systemFont(ofSize: 11.5, weight: .bold)
        header.textColor = .systemRed
        conflictStack.addArrangedSubview(header)

        for c in conflicts {
            let row = NSTextField(labelWithString: "• \(c.field): Current Edit '\(c.yourEdit)' vs External '\(c.externalVal)'")
            row.font = .systemFont(ofSize: 11)
            conflictStack.addArrangedSubview(row)
        }

        let actionsRow = NSStackView()
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8

        let keepEditsBtn = NSButton(title: "Keep My Draft Edits", target: self, action: #selector(keepMyEditsClicked))
        keepEditsBtn.bezelStyle = .rounded
        keepEditsBtn.controlSize = .small
        actionsRow.addArrangedSubview(keepEditsBtn)

        let acceptExtBtn = NSButton(title: "Accept External Changes", target: self, action: #selector(acceptExternalChangesClicked))
        acceptExtBtn.bezelStyle = .rounded
        acceptExtBtn.controlSize = .small
        actionsRow.addArrangedSubview(acceptExtBtn)

        conflictStack.addArrangedSubview(actionsRow)
    }

    func hideConflictBanner() {
        conflictBox.isHidden = true
        conflictStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        latestExternalRecord = nil
    }

    @objc private func keepMyEditsClicked() {
        if let ext = latestExternalRecord {
            activeDraft?.baseRecord = ext
        } else if let current = currentRecord {
            activeDraft?.baseRecord = current
        }
        hideConflictBanner()
    }

    @objc private func acceptExternalChangesClicked() {
        let target = latestExternalRecord ?? currentRecord
        discardDraft()
        if let t = target {
            setRecord(t, candidate: candidateDuplicate, progress: nil)
        }
        hideConflictBanner()
    }

    func showSuggestionsBanner(suggestions: [String: String]) {
        self.currentSuggestions = suggestions
        suggestionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        suggestionsStack.spacing = 10
        guard !suggestions.isEmpty else {
            suggestionsBox.isHidden = true
            return
        }
        suggestionsBox.isHidden = false

        let header = NSTextField(labelWithString: "💡 OCR Reprocess Suggestions Available (\(suggestions.count)):")
        header.font = .systemFont(ofSize: 11.5, weight: .bold)
        header.textColor = .systemBlue
        suggestionsStack.addArrangedSubview(header)

        for (field, value) in suggestions.sorted(by: { $0.key < $1.key }) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10

            let lbl = NSTextField(labelWithString: "\(field): \(value)")
            lbl.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            row.addArrangedSubview(lbl)

            let applyBtn = NSButton(title: "Apply", target: self, action: #selector(applySuggestionClicked(_:)))
            applyBtn.bezelStyle = .rounded
            applyBtn.controlSize = .small
            applyBtn.identifier = NSUserInterfaceItemIdentifier(field)
            row.addArrangedSubview(applyBtn)

            suggestionsStack.addArrangedSubview(row)
        }
    }

    func hideSuggestionsBanner() {
        suggestionsBox.isHidden = true
        suggestionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        currentSuggestions.removeAll()
    }

    /// Displays AI output as draft-only edits. Applying one merely updates the
    /// current editor draft; the reviewer must still Save or Save & Next.
    func showAIAnalysis(_ analysis: BondAIAnalysis?, for record: BondRecord) {
        guard let analysis else { return }
        suggestionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        suggestionsStack.spacing = 10
        suggestionsBox.isHidden = false
        let isCurrent = analysis.recordID == record.id
            && analysis.recordRevision == (record.revision ?? 0)
            && analysis.promptVersion == BondAIAnalysis.currentPromptVersion
            && record.status == "REVIEW"
        let status: String
        if !isCurrent {
            status = "AI Analysis History — Outdated (not actionable)"
        } else {
            switch analysis.status {
            case .ready: status = "AI Analysis — Suggestions are unverified"
            case .abstained: status = "AI Analysis — Evidence insufficient"
            case .unavailable: status = "AI Analysis Unavailable"
            case .failed: status = "AI Analysis Could Not Complete"
            case .cancelled: status = "AI Analysis Cancelled"
            }
        }
        let header = NSTextField(labelWithString: status)
        header.font = .systemFont(ofSize: 11.5, weight: .bold)
        header.textColor = .systemBlue
        suggestionsStack.addArrangedSubview(header)
        let summary = NSTextField(wrappingLabelWithString: analysis.summary)
        summary.font = .systemFont(ofSize: 10.5)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 3
        suggestionsStack.addArrangedSubview(summary)

        currentSuggestions.removeAll()
        for suggestion in analysis.suggestions {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            let proposed = suggestion.proposedValue ?? "No proposed value (abstained)"
            let title = NSTextField(labelWithString: "\(suggestion.field): \(suggestion.existingValue) → \(proposed)")
            title.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            row.addArrangedSubview(title)
            let detail = NSTextField(wrappingLabelWithString: "\(suggestion.assessment.rawValue) • \(suggestion.evidence) • \(suggestion.ambiguity)\(suggestion.requiresOriginalInspection ? " • Inspect original photograph" : "")")
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 2
            row.addArrangedSubview(detail)
            // Stale output remains visible as audit history, but can never alter a
            // draft or become an accidental recommendation after OCR/review edits.
            if isCurrent, let value = suggestion.proposedValue, !suggestion.abstained {
                currentSuggestions[suggestion.field] = value
                let buttons = NSStackView()
                buttons.orientation = .horizontal
                buttons.spacing = 10
                let accept = NSButton(title: "Accept Suggestion", target: self, action: #selector(applySuggestionClicked(_:)))
                accept.bezelStyle = .rounded; accept.controlSize = .small
                accept.identifier = NSUserInterfaceItemIdentifier(suggestion.field)
                buttons.addArrangedSubview(accept)
                let keep = NSButton(title: "Keep Current", target: self, action: #selector(keepAISuggestionClicked(_:)))
                keep.bezelStyle = .rounded; keep.controlSize = .small
                keep.identifier = NSUserInterfaceItemIdentifier(suggestion.field)
                buttons.addArrangedSubview(keep)
                row.addArrangedSubview(buttons)
            }
            suggestionsStack.addArrangedSubview(row)
        }
    }

    @objc private func keepAISuggestionClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        currentSuggestions.removeValue(forKey: key)
        // This affects only the displayed proposal; it does not mutate the record.
        sender.superview?.superview?.isHidden = true
    }

    @objc private func applySuggestionClicked(_ sender: NSButton) {
        guard let field = sender.identifier?.rawValue, let value = currentSuggestions[field] else { return }
        if field == "series" || field == "denomination" || field == "secondRole" {
            setPopupSelection(key: field, value: value)
            userEdits[field] = value
            confirmedFields.insert(field)
            activeDraft?.userEdits[field] = value
            activeDraft?.confirmedFields.insert(field)
        } else if field == "issueMonth" {
            if let mNum = monthNumber(value), let idx = Int(mNum), idx >= 1, idx <= 12 {
                popupControls["issueMonth"]?.selectItem(at: idx)
            }
            userEdits["issueMonth"] = value
            confirmedFields.insert("issueMonth")
            activeDraft?.userEdits["issueMonth"] = value
            activeDraft?.confirmedFields.insert("issueMonth")
        } else {
            setTextFieldValue(key: field, value: value)
            userEdits[field] = value
            confirmedFields.insert(field)
            activeDraft?.userEdits[field] = value
            activeDraft?.confirmedFields.insert(field)
        }
        currentSuggestions.removeValue(forKey: field)
        if currentSuggestions.isEmpty {
            hideSuggestionsBanner()
        } else {
            showSuggestionsBanner(suggestions: currentSuggestions)
        }
        updateFieldBadgesAndErrors()
    }

    func showQueueCompleted(message: String = "All records in the current review queue have been reviewed.") {
        completionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        completionBox.isHidden = false

        let title = NSTextField(labelWithString: "🎉 Review Queue Completed")
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.textColor = .systemGreen
        completionStack.addArrangedSubview(title)

        let msg = NSTextField(labelWithString: message)
        msg.font = .systemFont(ofSize: 11.5)
        msg.textColor = .secondaryLabelColor
        completionStack.addArrangedSubview(msg)
    }

    func hideCompletionBanner() {
        completionBox.isHidden = true
        completionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }


    // MARK: - Badges and Provenance

    func updateFieldBadgesAndErrors() {
        guard let r = currentRecord else { return }

        let keys = ["series", "serial", "denomination", "issueDate", "owner", "secondName", "address", "issuingAgent", "datingStamp"]
        for key in keys {
            let isConfirmed = confirmedFields.contains(key)
            let isEdited = userEdits[key] != nil
            let conf = r.fieldConfidence?[key] ?? ""
            let val = getEffectiveValue(key: key)

            if let badge = badgeLabels[key] {
                if isConfirmed {
                    badge.stringValue = "✓ Confirmed"
                    badge.textColor = .systemGreen
                } else if isEdited {
                    badge.stringValue = "✏ Edited"
                    badge.textColor = .systemBlue
                } else if conf == "high" {
                    badge.stringValue = "OCR High"
                    badge.textColor = .systemGreen
                } else if conf == "uncertain" {
                    badge.stringValue = "⚠ Uncertain"
                    badge.textColor = .systemOrange
                } else if val.isEmpty {
                    badge.stringValue = "Missing"
                    badge.textColor = .systemRed
                } else {
                    badge.stringValue = ""
                }
            }

            if let prov = provenanceLabels[key] {
                if let src = r.fieldSource?[key], !src.isEmpty {
                    prov.stringValue = "(\(src))"
                } else {
                    prov.stringValue = ""
                }
            }
        }

        // Inline Validation Errors
        let valReport = BondValidationRules.validateBond(record: previewRecord(), userConfirmedFields: confirmedFields)

        // Serial error
        if !valReport.syntacticSerial.isValid, let err = errorLabels["serial"] {
            err.stringValue = valReport.syntacticSerial.failureReason ?? "Invalid serial syntax"
            err.isHidden = false
        } else {
            errorLabels["serial"]?.isHidden = true
        }

        // Denomination error
        if valReport.prefixDenominationConsistency.status == .inconsistent, let err = errorLabels["denomination"] {
            err.stringValue = valReport.prefixDenominationConsistency.message ?? "Denomination inconsistent with serial prefix"
            err.isHidden = false
        } else {
            errorLabels["denomination"]?.isHidden = true
        }

        // Date error
        if valReport.seriesDateConsistency.status == .inconsistent, let err = errorLabels["issueDate"] {
            err.stringValue = valReport.seriesDateConsistency.message ?? "Issue date inconsistent with series"
            err.isHidden = false
        } else {
            errorLabels["issueDate"]?.isHidden = true
        }
    }

    func getEffectiveValue(key: String) -> String {
        if let edit = userEdits[key] {
            return edit
        }
        if key == "issueDate" {
            let m = userEdits["issueMonth"] ?? currentRecord?.issueMonth ?? ""
            let y = userEdits["issueYear"] ?? currentRecord?.issueYear ?? ""
            return (m.isEmpty && y.isEmpty) ? "" : "\(m)/\(y)"
        }
        return textFields[key]?.stringValue ?? ""
    }

    func previewRecord() -> BondRecord {
        guard var r = currentRecord else { return BondRecord(id: "", capturedAt: "", series: "", serial: "", issueMonth: "", issueYear: "", denomination: "", owner: "", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "") }
        for (k, v) in userEdits {
            switch k {
            case "series": r.series = v
            case "serial": r.serial = v
            case "denomination": r.denomination = v
            case "issueMonth": r.issueMonth = v
            case "issueYear": r.issueYear = v
            case "owner": r.owner = v
            case "secondName": r.secondName = v
            case "secondRole": r.secondRole = v
            case "address": r.address = v
            case "issuingAgent": r.issuingAgent = v
            case "datingStamp": r.datingStamp = v
            case "notes": r.notes = v
            default: break
            }
        }
        return r
    }

    // MARK: - Reasons Banner

    func updateReasonsBanner() {
        reasonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let r = currentRecord else { return }

        let activeReasons = (r.reviewReasons ?? []).filter { !resolvedReasons.contains($0) }
        guard !activeReasons.isEmpty else { return }

        let banner = NSBox()
        banner.boxType = .custom
        banner.borderWidth = 1
        banner.borderColor = NSColor.systemOrange.withAlphaComponent(0.5)
        banner.fillColor = NSColor.systemOrange.withAlphaComponent(0.06)
        banner.cornerRadius = 6
        banner.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -8),
        ])

        let bannerTitle = NSTextField(labelWithString: "⚠️ Review Required (\(activeReasons.count) reasons)")
        bannerTitle.font = .systemFont(ofSize: 12, weight: .bold)
        bannerTitle.textColor = .systemOrange
        stack.addArrangedSubview(bannerTitle)

        for reasonKey in activeReasons {
            let fmt = FormattedReviewReason(rawKey: reasonKey)
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            let desc = NSTextField(labelWithString: "• \(fmt.title): \(fmt.detail)")
            desc.font = .systemFont(ofSize: 11)
            desc.lineBreakMode = .byWordWrapping
            row.addArrangedSubview(desc)

            if fmt.isResolvable {
                let resolveBtn = NSButton(title: "Resolve", target: self, action: #selector(resolveReasonClicked(_:)))
                resolveBtn.bezelStyle = .inline
                resolveBtn.controlSize = .small
                resolveBtn.identifier = NSUserInterfaceItemIdentifier(reasonKey)
                row.addArrangedSubview(resolveBtn)
            }
            stack.addArrangedSubview(row)
        }

        reasonsStack.addArrangedSubview(banner)
        NSLayoutConstraint.activate([
            banner.widthAnchor.constraint(equalTo: formContainer.widthAnchor),
        ])
    }

    // MARK: - Duplicate Resolution Card

    func updateDuplicateCard() {
        duplicateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let r = currentRecord, let cand = candidateDuplicate else {
            duplicateBox.isHidden = true
            return
        }

        duplicateBox.isHidden = false

        let header = NSTextField(labelWithString: "🔍 Possible Duplicate Detected (Near-Match with #\(cand.id.prefix(8)))")
        header.font = .systemFont(ofSize: 12, weight: .bold)
        header.textColor = .systemOrange
        duplicateStack.addArrangedSubview(header)

        // Comparison Table View / Stack
        let compStack = NSStackView()
        compStack.orientation = .vertical
        compStack.spacing = 4
        compStack.alignment = .leading
        compStack.translatesAutoresizingMaskIntoConstraints = false

        let compFields: [(String, String, String)] = [
            ("Serial", r.serial, cand.serial),
            ("Denomination", r.denomination, cand.denomination),
            ("Issue Date", "\(r.issueMonth)/\(r.issueYear)", "\(cand.issueMonth)/\(cand.issueYear)"),
            ("Series", r.series, cand.series),
            ("Owner", r.owner, cand.owner),
        ]

        for (lbl, v1, v2) in compFields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            let lTf = NSTextField(labelWithString: "\(lbl):")
            lTf.font = .systemFont(ofSize: 11, weight: .semibold)
            lTf.widthAnchor.constraint(equalToConstant: 90).isActive = true

            let v1Tf = NSTextField(labelWithString: "This: \(v1.isEmpty ? "—" : v1)")
            v1Tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            v1Tf.widthAnchor.constraint(equalToConstant: 140).isActive = true

            let isDiff = (v1 != v2)
            let v2Tf = NSTextField(labelWithString: "Candidate: \(v2.isEmpty ? "—" : v2)")
            v2Tf.font = .monospacedSystemFont(ofSize: 11, weight: isDiff ? .bold : .regular)
            if isDiff {
                v2Tf.textColor = .systemRed
            }

            row.addArrangedSubview(lTf)
            row.addArrangedSubview(v1Tf)
            row.addArrangedSubview(v2Tf)
            compStack.addArrangedSubview(row)
        }
        duplicateStack.addArrangedSubview(compStack)

        // Action Buttons Row
        let actionsRow = NSStackView()
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 10
        actionsRow.translatesAutoresizingMaskIntoConstraints = false

        let keepSepBtn = NSButton(title: "Keep Separate", target: self, action: #selector(keepSeparateClicked))
        keepSepBtn.bezelStyle = .rounded
        keepSepBtn.controlSize = .small
        keepSepBtn.toolTip = "Confirm these are two different bonds and keep both in database"
        actionsRow.addArrangedSubview(keepSepBtn)

        let mergeBtn = NSButton(title: "Confirm Same Bond (Merge)", target: self, action: #selector(mergeDuplicateClicked))
        mergeBtn.bezelStyle = .rounded
        mergeBtn.controlSize = .small
        mergeBtn.font = .systemFont(ofSize: 11, weight: .semibold)
        mergeBtn.toolTip = "Atomically merge candidate bond and its photographs into this record"
        actionsRow.addArrangedSubview(mergeBtn)

        let comparePhotoBtn = NSButton(title: "Compare Candidate Photo", target: self, action: #selector(comparePhotoClicked))
        comparePhotoBtn.bezelStyle = .rounded
        comparePhotoBtn.controlSize = .small
        actionsRow.addArrangedSubview(comparePhotoBtn)

        duplicateStack.addArrangedSubview(actionsRow)
    }

}
