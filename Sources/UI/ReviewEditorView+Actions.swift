import AppKit
import Foundation

extension ReviewEditorView {
    // MARK: - Actions

    @objc func prevClicked() {
        delegate?.reviewEditorDidRequestPrevious(self)
    }

    @objc func nextClicked() {
        delegate?.reviewEditorDidRequestNext(self)
    }

    @objc func saveClicked() {
        delegate?.reviewEditorDidRequestSave(self, andNext: false)
    }

    @objc func saveAndNextClicked() {
        delegate?.reviewEditorDidRequestSave(self, andNext: true)
    }

    @objc func revertClicked() {
        discardDraft()
        delegate?.reviewEditorDidRequestRevert(self)
    }

    func discardDraft() {
        userEdits.removeAll()
        if let r = currentRecord {
            confirmedFields = Set(r.userConfirmedFields ?? [])
            resolvedReasons = Set(r.resolvedReviewReasons ?? [])
            acknowledgedWarnings = Set(r.acknowledgedWarnings ?? [])
            activeDraft = ReviewDraft(record: r)
        } else {
            confirmedFields.removeAll()
            resolvedReasons.removeAll()
            acknowledgedWarnings.removeAll()
            activeDraft = nil
        }
        hideConflictBanner()
    }

    @objc func reprocessClicked() {
        reprocessSpinner.startAnimation(nil)
        delegate?.reviewEditorDidRequestReprocess(self)
    }

    @objc func analyzeWithAIClicked() {
        delegate?.reviewEditorDidRequestAIAnalysis(self)
    }

    @objc func analyzeExistingAIClicked() {
        delegate?.reviewEditorDidRequestAnalyzeExistingAI(self)
    }

    func setReprocessing(_ inProgress: Bool) {
        if inProgress {
            reprocessSpinner.startAnimation(nil)
            reprocessBtn.isEnabled = false
        } else {
            reprocessSpinner.stopAnimation(nil)
            reprocessBtn.isEnabled = true
        }
    }

    @objc func confirmFieldClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        if key == "issueDate" {
            confirmedFields.insert("issueMonth")
            confirmedFields.insert("issueYear")
            confirmedFields.insert("issueDate")
        } else {
            confirmedFields.insert(key)
        }
        updateFieldBadgesAndErrors()
    }

    @objc func confirmAllClicked() {
        let keys = ["series", "serial", "denomination", "issueMonth", "issueYear", "issueDate", "owner", "secondName", "address", "issuingAgent", "datingStamp"]
        for k in keys {
            let val = getEffectiveValue(key: k)
            if !val.isEmpty {
                confirmedFields.insert(k)
            }
        }
        updateFieldBadgesAndErrors()
    }

    /// Confirms the currently focused field (via ⌘K), or all valid non-empty fields if no field is focused.
    func confirmCurrentOrAllValidFields() {
        if let window = self.window {
            if let firstResp = window.firstResponder as? NSTextView,
               let fieldEditorParent = firstResp.delegate as? NSTextField,
               let key = fieldEditorParent.identifier?.rawValue
            {
                if key == "issueYear" || key == "issueMonth" {
                    confirmedFields.insert("issueMonth")
                    confirmedFields.insert("issueYear")
                    confirmedFields.insert("issueDate")
                } else {
                    confirmedFields.insert(key)
                }
                updateFieldBadgesAndErrors()
                return
            } else if let popup = window.firstResponder as? NSPopUpButton,
                      let key = popup.identifier?.rawValue
            {
                if key == "issueMonth" {
                    confirmedFields.insert("issueMonth")
                    confirmedFields.insert("issueYear")
                    confirmedFields.insert("issueDate")
                } else {
                    confirmedFields.insert(key)
                }
                updateFieldBadgesAndErrors()
                return
            }
        }
        confirmAllClicked()
    }

    /// Programmatically applies a user edit to a field, updating UI controls and draft state.
    func applyFieldEdit(field: String, value: String) {
        if field == "series" || field == "denomination" || field == "secondRole" {
            setPopupSelection(key: field, value: value)
        } else if field == "issueMonth" {
            if let mNum = monthNumber(value), let idx = Int(mNum), idx >= 1, idx <= 12 {
                popupControls["issueMonth"]?.selectItem(at: idx)
            } else {
                popupControls["issueMonth"]?.selectItem(at: 0)
            }
        } else {
            setTextFieldValue(key: field, value: value)
        }
        userEdits[field] = value
        confirmedFields.insert(field)
        updateFieldBadgesAndErrors()
    }

    /// Returns the text field control for a given field key (for focus management and testing).
    func textField(forKey key: String) -> NSTextField? {
        return textFields[key]
    }

    /// Marks a specific review reason as resolved in the active draft.
    func markReasonResolved(_ reason: String) {
        resolvedReasons.insert(reason)
        updateReasonsBanner()
    }

    @objc func resolveReasonClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        resolvedReasons.insert(key)
        delegate?.reviewEditor(self, didResolveReason: key)
        updateReasonsBanner()
    }

    @objc func keepSeparateClicked() {
        guard let cand = candidateDuplicate else { return }
        delegate?.reviewEditor(self, didRequestKeepSeparate: cand)
    }

    @objc func mergeDuplicateClicked() {
        guard let cand = candidateDuplicate else { return }
        delegate?.reviewEditor(self, didRequestMergeCandidate: cand)
    }

    @objc func comparePhotoClicked() {
        guard let cand = candidateDuplicate else { return }
        delegate?.reviewEditor(self, didRequestCompareCandidatePhoto: cand)
    }

    @objc func popupChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let selectedTitle = sender.selectedItem?.title ?? ""
        if key == "issueMonth" {
            let mNum = String(selectedTitle.prefix(2))
            userEdits["issueMonth"] = mNum == "(M" ? "" : mNum
            confirmedFields.insert("issueMonth")
        } else if key == "secondRole" {
            userEdits["secondRole"] = selectedTitle == "(None)" ? "" : selectedTitle
        } else {
            userEdits[key] = selectedTitle
            confirmedFields.insert(key)
        }
        updateFieldBadgesAndErrors()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, let key = tf.identifier?.rawValue else { return }
        userEdits[key] = tf.stringValue
        confirmedFields.insert(key)
        updateFieldBadgesAndErrors()
    }

    var pendingEdits: [String: String] {
        activeDraft?.userEdits ?? userEdits
    }

    var pendingConfirmedFields: Set<String> {
        activeDraft?.confirmedFields ?? confirmedFields
    }

    var pendingResolvedReasons: Set<String> {
        activeDraft?.resolvedReasons ?? resolvedReasons
    }

    var pendingAcknowledgedWarnings: Set<String> {
        activeDraft?.acknowledgedWarnings ?? acknowledgedWarnings
    }

    var hasUnsavedChanges: Bool {
        if let draft = activeDraft {
            return draft.hasUnsavedChanges
        }
        return !userEdits.isEmpty || confirmedFields != Set(currentRecord?.userConfirmedFields ?? [])
    }

    var isShowingQueueCompleted: Bool {
        !completionBox.isHidden
    }

    var isShowingConflictBanner: Bool {
        !conflictBox.isHidden
    }

    var isShowingSuggestionsBanner: Bool {
        !suggestionsBox.isHidden
    }
}
