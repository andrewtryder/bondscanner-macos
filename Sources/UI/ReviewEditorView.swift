import AppKit

protocol ReviewEditorViewDelegate: AnyObject {
    @discardableResult
    func reviewEditorDidRequestSave(_ editor: ReviewEditorView, andNext: Bool) -> Bool
    func reviewEditorDidRequestPrevious(_ editor: ReviewEditorView)
    func reviewEditorDidRequestNext(_ editor: ReviewEditorView)
    func reviewEditorDidRequestRevert(_ editor: ReviewEditorView)
    func reviewEditorDidRequestReprocess(_ editor: ReviewEditorView)
    func reviewEditorDidRequestAIAnalysis(_ editor: ReviewEditorView)
    func reviewEditorDidRequestAnalyzeExistingAI(_ editor: ReviewEditorView)
    func reviewEditor(_ editor: ReviewEditorView, didResolveReason reason: String)
    func reviewEditor(_ editor: ReviewEditorView, didAcknowledgeWarning warning: String)
    func reviewEditor(_ editor: ReviewEditorView, didRequestKeepSeparate candidate: BondRecord)
    func reviewEditor(_ editor: ReviewEditorView, didRequestMergeCandidate candidate: BondRecord)
    func reviewEditor(_ editor: ReviewEditorView, didRequestCompareCandidatePhoto candidate: BondRecord)
}

/// Explicit draft representation preserving uncommitted edits, confirmations, and resolutions.
struct ReviewDraft {
    var recordId: String
    var baseRecord: BondRecord
    var userEdits: [String: String] = [:]
    var confirmedFields: Set<String> = []
    var resolvedReasons: Set<String> = []
    var acknowledgedWarnings: Set<String> = []

    init(record: BondRecord) {
        self.recordId = record.id
        self.baseRecord = record
        self.userEdits = [:]
        self.confirmedFields = Set(record.userConfirmedFields ?? [])
        self.resolvedReasons = Set(record.resolvedReviewReasons ?? [])
        self.acknowledgedWarnings = Set(record.acknowledgedWarnings ?? [])
    }

    var hasUnsavedChanges: Bool {
        if !userEdits.isEmpty {
            return true
        }
        if confirmedFields != Set(baseRecord.userConfirmedFields ?? []) {
            return true
        }
        if resolvedReasons != Set(baseRecord.resolvedReviewReasons ?? []) {
            return true
        }
        if acknowledgedWarnings != Set(baseRecord.acknowledgedWarnings ?? []) {
            return true
        }
        return false
    }
}

/// Rich AppKit editor panel for reviewing and correcting bond fields, resolving review reasons,
/// comparing near-match duplicates, and performing keyboard-first workflow navigation.
final class ReviewEditorView: NSView, NSTextFieldDelegate {
    weak var delegate: ReviewEditorViewDelegate?

    var currentRecord: BondRecord?
    var candidateDuplicate: BondRecord?
    var activeDraft: ReviewDraft?

    var userEdits: [String: String] = [:] {
        didSet { activeDraft?.userEdits = userEdits }
    }

    var confirmedFields: Set<String> = [] {
        didSet { activeDraft?.confirmedFields = confirmedFields }
    }

    var resolvedReasons: Set<String> = [] {
        didSet { activeDraft?.resolvedReasons = resolvedReasons }
    }

    var acknowledgedWarnings: Set<String> = [] {
        didSet { activeDraft?.acknowledgedWarnings = acknowledgedWarnings }
    }

    // Header Controls
    let headerBox = NSBox()
    let titleLabel = NSTextField(labelWithString: "Bond Review")
    let statusBadge = NSTextField(labelWithString: "REVIEW")
    let progressLabel = NSTextField(labelWithString: "Reviewed 0 / 0 — 0 remaining")
    var baseProgressText: String = "Reviewed 0 / 0 — 0 remaining"
    var currentAIProgressText: String = ""
    let prevBtn = NSButton(title: "‹ Prev", target: nil, action: nil)
    let nextBtn = NSButton(title: "Next ›", target: nil, action: nil)
    let analyzeBacklogBtn = NSButton(title: "Analyze Existing Reviews", target: nil, action: nil)

    // Scrollable Form Container
    let scrollView = NSScrollView()
    let formContainer = NSStackView()

    // Banners
    let reasonsStack = NSStackView()
    let duplicateBox = NSBox()
    let duplicateStack = NSStackView()
    let conflictBox = NSBox()
    let conflictStack = NSStackView()
    let suggestionsBox = NSBox()
    let suggestionsStack = NSStackView()
    let completionBox = NSBox()
    let completionStack = NSStackView()
    var currentSuggestions: [String: String] = [:]

    // Field Controls Map
    var textFields: [String: NSTextField] = [:]
    var popupControls: [String: NSPopUpButton] = [:]
    var badgeLabels: [String: NSTextField] = [:]
    var provenanceLabels: [String: NSTextField] = [:]
    var errorLabels: [String: NSTextField] = [:]

    // Bottom Action Bar
    let bottomBar = NSBox()
    let saveAndNextBtn = NSButton(title: "Save & Next", target: nil, action: nil)
    let saveBtn = NSButton(title: "Save", target: nil, action: nil)
    let revertBtn = NSButton(title: "Revert", target: nil, action: nil)
    let reprocessBtn = NSButton(title: "Reprocess Photo", target: nil, action: nil)
    let aiAnalyzeBtn = NSButton(title: "Analyze with AI", target: nil, action: nil)
    let reprocessSpinner = NSProgressIndicator()
    let confirmAllBtn = NSButton(title: "Confirm All Valid ✓", target: nil, action: nil)
    let shortcutsLabel = NSTextField(labelWithString: "Shortcuts: ⌘⏎ Save & Next  •  ⌘S Save  •  ⌘[ / ⌘] Prev/Next  •  ⌘K Confirm Field  •  ⌘P Reprocess  •  ⌘R Rotate  •  ⌘T Toggle Photo  •  ⌘0 Fit")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        setupHeader()
        setupBottomBar()
        setupForm()

        addSubview(headerBox)
        addSubview(scrollView)
        addSubview(bottomBar)

        headerBox.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            headerBox.topAnchor.constraint(equalTo: topAnchor),
            headerBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBox.heightAnchor.constraint(equalToConstant: 66),

            scrollView.topAnchor.constraint(equalTo: headerBox.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupHeader() {
        headerBox.boxType = .custom
        headerBox.borderWidth = 0
        headerBox.fillColor = NSColor.controlBackgroundColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusBadge.font = .systemFont(ofSize: 11, weight: .bold)
        statusBadge.textColor = .white
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 4
        statusBadge.layer?.masksToBounds = true
        statusBadge.alignment = .center
        statusBadge.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.cell?.truncatesLastVisibleLine = true
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        prevBtn.bezelStyle = .rounded
        prevBtn.controlSize = .small
        prevBtn.target = self
        prevBtn.action = #selector(prevClicked)
        prevBtn.toolTip = "Previous Record (⌘[)"
        prevBtn.translatesAutoresizingMaskIntoConstraints = false

        nextBtn.bezelStyle = .rounded
        nextBtn.controlSize = .small
        nextBtn.target = self
        nextBtn.action = #selector(nextClicked)
        nextBtn.toolTip = "Next Record (⌘])"
        nextBtn.translatesAutoresizingMaskIntoConstraints = false

        analyzeBacklogBtn.bezelStyle = .rounded
        analyzeBacklogBtn.controlSize = .small
        analyzeBacklogBtn.target = self
        analyzeBacklogBtn.action = #selector(analyzeExistingAIClicked)
        analyzeBacklogBtn.toolTip = "Analyze unresolved REVIEW records sequentially using the on-device model"
        analyzeBacklogBtn.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        analyzeBacklogBtn.setContentHuggingPriority(.required, for: .horizontal)
        prevBtn.setContentHuggingPriority(.required, for: .horizontal)
        nextBtn.setContentHuggingPriority(.required, for: .horizontal)

        headerBox.addSubview(titleLabel)
        headerBox.addSubview(statusBadge)
        headerBox.addSubview(progressLabel)
        headerBox.addSubview(prevBtn)
        headerBox.addSubview(nextBtn)
        headerBox.addSubview(analyzeBacklogBtn)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 10),

            statusBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            statusBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            statusBadge.heightAnchor.constraint(equalToConstant: 18),

            analyzeBacklogBtn.leadingAnchor.constraint(greaterThanOrEqualTo: statusBadge.trailingAnchor, constant: 10),
            analyzeBacklogBtn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            prevBtn.leadingAnchor.constraint(greaterThanOrEqualTo: analyzeBacklogBtn.trailingAnchor, constant: 10),
            prevBtn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            nextBtn.leadingAnchor.constraint(greaterThanOrEqualTo: prevBtn.trailingAnchor, constant: 6),
            nextBtn.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor, constant: -16),
            nextBtn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            progressLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 16),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerBox.trailingAnchor, constant: -16),
            progressLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
        ])
    }

    private func setupBottomBar() {
        bottomBar.boxType = .custom
        bottomBar.borderWidth = 1
        bottomBar.borderColor = NSColor.separatorColor
        bottomBar.fillColor = NSColor.controlBackgroundColor

        saveAndNextBtn.bezelStyle = .rounded
        saveAndNextBtn.controlSize = .regular
        saveAndNextBtn.keyEquivalent = "\r" // Return
        saveAndNextBtn.keyEquivalentModifierMask = [.command]
        saveAndNextBtn.target = self
        saveAndNextBtn.action = #selector(saveAndNextClicked)
        saveAndNextBtn.font = .systemFont(ofSize: 13, weight: .semibold)
        saveAndNextBtn.translatesAutoresizingMaskIntoConstraints = false

        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .regular
        saveBtn.target = self
        saveBtn.action = #selector(saveClicked)
        saveBtn.toolTip = "Save changes to current record (⌘S)"
        saveBtn.translatesAutoresizingMaskIntoConstraints = false

        revertBtn.bezelStyle = .rounded
        revertBtn.controlSize = .regular
        revertBtn.target = self
        revertBtn.action = #selector(revertClicked)
        revertBtn.toolTip = "Discard uncommitted changes"
        revertBtn.translatesAutoresizingMaskIntoConstraints = false

        reprocessBtn.bezelStyle = .rounded
        reprocessBtn.controlSize = .small
        reprocessBtn.target = self
        reprocessBtn.action = #selector(reprocessClicked)
        reprocessBtn.toolTip = "Reprocess saved photograph with Vision OCR (⌘P)"
        reprocessBtn.translatesAutoresizingMaskIntoConstraints = false

        aiAnalyzeBtn.bezelStyle = .rounded
        aiAnalyzeBtn.controlSize = .small
        aiAnalyzeBtn.target = self
        aiAnalyzeBtn.action = #selector(analyzeWithAIClicked)
        aiAnalyzeBtn.toolTip = "Prepare unverified suggestions with Apple’s on-device model"
        aiAnalyzeBtn.translatesAutoresizingMaskIntoConstraints = false

        reprocessSpinner.style = .spinning
        reprocessSpinner.controlSize = .small
        reprocessSpinner.isDisplayedWhenStopped = false
        reprocessSpinner.translatesAutoresizingMaskIntoConstraints = false

        confirmAllBtn.bezelStyle = .rounded
        confirmAllBtn.controlSize = .small
        confirmAllBtn.target = self
        confirmAllBtn.action = #selector(confirmAllClicked)
        confirmAllBtn.toolTip = "Confirm all valid fields at once"
        confirmAllBtn.translatesAutoresizingMaskIntoConstraints = false

        shortcutsLabel.font = .systemFont(ofSize: 10.5)
        shortcutsLabel.textColor = .secondaryLabelColor
        shortcutsLabel.lineBreakMode = .byTruncatingTail
        shortcutsLabel.cell?.truncatesLastVisibleLine = true
        shortcutsLabel.translatesAutoresizingMaskIntoConstraints = false

        bottomBar.addSubview(saveAndNextBtn)
        bottomBar.addSubview(saveBtn)
        bottomBar.addSubview(revertBtn)
        bottomBar.addSubview(reprocessBtn)
        bottomBar.addSubview(aiAnalyzeBtn)
        bottomBar.addSubview(reprocessSpinner)
        bottomBar.addSubview(confirmAllBtn)
        bottomBar.addSubview(shortcutsLabel)

        NSLayoutConstraint.activate([
            // Row 1 (Secondary Tools)
            reprocessBtn.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            reprocessBtn.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 10),

            aiAnalyzeBtn.leadingAnchor.constraint(equalTo: reprocessBtn.trailingAnchor, constant: 8),
            aiAnalyzeBtn.centerYAnchor.constraint(equalTo: reprocessBtn.centerYAnchor),

            reprocessSpinner.leadingAnchor.constraint(equalTo: aiAnalyzeBtn.trailingAnchor, constant: 8),
            reprocessSpinner.centerYAnchor.constraint(equalTo: reprocessBtn.centerYAnchor),

            confirmAllBtn.leadingAnchor.constraint(greaterThanOrEqualTo: reprocessSpinner.trailingAnchor, constant: 12),
            confirmAllBtn.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            confirmAllBtn.centerYAnchor.constraint(equalTo: reprocessBtn.centerYAnchor),

            // Row 2 (Primary Actions)
            revertBtn.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            revertBtn.topAnchor.constraint(equalTo: reprocessBtn.bottomAnchor, constant: 10),

            saveBtn.leadingAnchor.constraint(greaterThanOrEqualTo: revertBtn.trailingAnchor, constant: 12),
            saveBtn.trailingAnchor.constraint(equalTo: saveAndNextBtn.leadingAnchor, constant: -10),
            saveBtn.centerYAnchor.constraint(equalTo: revertBtn.centerYAnchor),

            saveAndNextBtn.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            saveAndNextBtn.centerYAnchor.constraint(equalTo: revertBtn.centerYAnchor),
            saveAndNextBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            // Row 3 (Shortcuts)
            shortcutsLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            shortcutsLabel.trailingAnchor.constraint(lessThanOrEqualTo: bottomBar.trailingAnchor, constant: -16),
            shortcutsLabel.topAnchor.constraint(equalTo: saveAndNextBtn.bottomAnchor, constant: 8),
            shortcutsLabel.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -8),
        ])
    }

    private func setupForm() {
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = NSColor.windowBackgroundColor

        formContainer.orientation = .vertical
        formContainer.alignment = .leading
        formContainer.spacing = 10
        formContainer.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(formContainer)

        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            formContainer.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 12),
            formContainer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 14),
            formContainer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -14),
            formContainer.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),
        ])

        // Configure End-of-Queue Completion Card
        completionBox.boxType = .custom
        completionBox.borderWidth = 1
        completionBox.borderColor = NSColor.systemGreen.withAlphaComponent(0.6)
        completionBox.fillColor = NSColor.systemGreen.withAlphaComponent(0.08)
        completionBox.cornerRadius = 6
        completionBox.translatesAutoresizingMaskIntoConstraints = false
        completionBox.isHidden = true

        completionStack.orientation = .vertical
        completionStack.alignment = .leading
        completionStack.spacing = 6
        completionStack.translatesAutoresizingMaskIntoConstraints = false
        completionBox.addSubview(completionStack)

        NSLayoutConstraint.activate([
            completionStack.topAnchor.constraint(equalTo: completionBox.topAnchor, constant: 10),
            completionStack.leadingAnchor.constraint(equalTo: completionBox.leadingAnchor, constant: 12),
            completionStack.trailingAnchor.constraint(equalTo: completionBox.trailingAnchor, constant: -12),
            completionStack.bottomAnchor.constraint(equalTo: completionBox.bottomAnchor, constant: -10),
        ])
        formContainer.addArrangedSubview(completionBox)
        completionBox.widthAnchor.constraint(equalTo: formContainer.widthAnchor).isActive = true

        // Configure Concurrent Conflict Card
        conflictBox.boxType = .custom
        conflictBox.borderWidth = 1
        conflictBox.borderColor = NSColor.systemRed.withAlphaComponent(0.6)
        conflictBox.fillColor = NSColor.systemRed.withAlphaComponent(0.08)
        conflictBox.cornerRadius = 6
        conflictBox.translatesAutoresizingMaskIntoConstraints = false
        conflictBox.isHidden = true

        conflictStack.orientation = .vertical
        conflictStack.alignment = .leading
        conflictStack.spacing = 6
        conflictStack.translatesAutoresizingMaskIntoConstraints = false
        conflictBox.addSubview(conflictStack)

        NSLayoutConstraint.activate([
            conflictStack.topAnchor.constraint(equalTo: conflictBox.topAnchor, constant: 10),
            conflictStack.leadingAnchor.constraint(equalTo: conflictBox.leadingAnchor, constant: 12),
            conflictStack.trailingAnchor.constraint(equalTo: conflictBox.trailingAnchor, constant: -12),
            conflictStack.bottomAnchor.constraint(equalTo: conflictBox.bottomAnchor, constant: -10),
        ])
        formContainer.addArrangedSubview(conflictBox)
        conflictBox.widthAnchor.constraint(equalTo: formContainer.widthAnchor).isActive = true

        // Configure OCR Suggestions Card
        suggestionsBox.boxType = .custom
        suggestionsBox.borderWidth = 1
        suggestionsBox.borderColor = NSColor.systemBlue.withAlphaComponent(0.6)
        suggestionsBox.fillColor = NSColor.systemBlue.withAlphaComponent(0.08)
        suggestionsBox.cornerRadius = 6
        suggestionsBox.translatesAutoresizingMaskIntoConstraints = false
        suggestionsBox.isHidden = true

        suggestionsStack.orientation = .vertical
        suggestionsStack.alignment = .leading
        suggestionsStack.spacing = 6
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionsBox.addSubview(suggestionsStack)

        NSLayoutConstraint.activate([
            suggestionsStack.topAnchor.constraint(equalTo: suggestionsBox.topAnchor, constant: 10),
            suggestionsStack.leadingAnchor.constraint(equalTo: suggestionsBox.leadingAnchor, constant: 12),
            suggestionsStack.trailingAnchor.constraint(equalTo: suggestionsBox.trailingAnchor, constant: -12),
            suggestionsStack.bottomAnchor.constraint(equalTo: suggestionsBox.bottomAnchor, constant: -10),
        ])
        formContainer.addArrangedSubview(suggestionsBox)
        suggestionsBox.widthAnchor.constraint(equalTo: formContainer.widthAnchor).isActive = true

        // Configure Reasons Stack
        reasonsStack.orientation = .vertical
        reasonsStack.alignment = .leading
        reasonsStack.spacing = 6
        reasonsStack.translatesAutoresizingMaskIntoConstraints = false
        formContainer.addArrangedSubview(reasonsStack)
        reasonsStack.widthAnchor.constraint(equalTo: formContainer.widthAnchor).isActive = true

        // Configure Duplicate Resolution Card
        duplicateBox.boxType = .custom
        duplicateBox.borderWidth = 1
        duplicateBox.borderColor = NSColor.systemOrange.withAlphaComponent(0.6)
        duplicateBox.fillColor = NSColor.systemOrange.withAlphaComponent(0.08)
        duplicateBox.cornerRadius = 6
        duplicateBox.translatesAutoresizingMaskIntoConstraints = false
        duplicateBox.isHidden = true

        duplicateStack.orientation = .vertical
        duplicateStack.alignment = .leading
        duplicateStack.spacing = 8
        duplicateStack.translatesAutoresizingMaskIntoConstraints = false
        duplicateBox.addSubview(duplicateStack)

        NSLayoutConstraint.activate([
            duplicateStack.topAnchor.constraint(equalTo: duplicateBox.topAnchor, constant: 10),
            duplicateStack.leadingAnchor.constraint(equalTo: duplicateBox.leadingAnchor, constant: 12),
            duplicateStack.trailingAnchor.constraint(equalTo: duplicateBox.trailingAnchor, constant: -12),
            duplicateStack.bottomAnchor.constraint(equalTo: duplicateBox.bottomAnchor, constant: -10),
        ])
        formContainer.addArrangedSubview(duplicateBox)
        duplicateBox.widthAnchor.constraint(equalTo: formContainer.widthAnchor).isActive = true

        // Form Fields
        addPopupRow(key: "series", label: "Series:", options: ["E", "EE", "I", "H", "HH", "OTHER"])
        addTextFieldRow(key: "serial", label: "Serial Number:", monospaced: true)
        addPopupRow(key: "denomination", label: "Denomination:", options: ["25", "50", "75", "100", "200", "500", "1000", "5000", "10000"])
        addDateRow()
        addTextFieldRow(key: "owner", label: "Registered Owner:")
        addTextFieldRow(key: "secondName", label: "Co-Owner / POD:")
        addPopupRow(key: "secondRole", label: "Second Role:", options: ["", "POD", "OR", "BENEFICIARY"])
        addTextFieldRow(key: "address", label: "Owner Address:")
        addTextFieldRow(key: "issuingAgent", label: "Issuing Agent:")
        addTextFieldRow(key: "datingStamp", label: "Dating Stamp:")
        addTextFieldRow(key: "notes", label: "Notes:")
    }

    private func addTextFieldRow(key: String, label text: String, monospaced: Bool = false) {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false

        let headerLine = NSStackView()
        headerLine.orientation = .horizontal
        headerLine.alignment = .centerY
        headerLine.spacing = 6
        headerLine.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 11.5, weight: .semibold)
        headerLine.addArrangedSubview(lbl)

        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabels[key] = badge
        headerLine.addArrangedSubview(badge)

        let prov = NSTextField(labelWithString: "")
        prov.font = .systemFont(ofSize: 10)
        prov.textColor = .secondaryLabelColor
        provenanceLabels[key] = prov
        headerLine.addArrangedSubview(prov)

        headerLine.addArrangedSubview(NSView()) // Spacer

        let confirmBtn = NSButton(title: "Confirm ✓", target: self, action: #selector(confirmFieldClicked(_:)))
        confirmBtn.bezelStyle = .inline
        confirmBtn.controlSize = .small
        confirmBtn.identifier = NSUserInterfaceItemIdentifier(key)
        headerLine.addArrangedSubview(confirmBtn)

        let tf = NSTextField()
        tf.font = monospaced ? .monospacedSystemFont(ofSize: 12.5, weight: .medium) : .systemFont(ofSize: 12)
        tf.delegate = self
        tf.identifier = NSUserInterfaceItemIdentifier(key)
        tf.translatesAutoresizingMaskIntoConstraints = false
        textFields[key] = tf

        let err = NSTextField(labelWithString: "")
        err.font = .systemFont(ofSize: 10.5, weight: .medium)
        err.textColor = .systemRed
        err.isHidden = true
        errorLabels[key] = err

        row.addArrangedSubview(headerLine)
        row.addArrangedSubview(tf)
        row.addArrangedSubview(err)

        formContainer.addArrangedSubview(row)

        NSLayoutConstraint.activate([
            headerLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            tf.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            tf.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            tf.heightAnchor.constraint(equalToConstant: 24),
            row.widthAnchor.constraint(equalTo: formContainer.widthAnchor),
        ])
    }

    private func addPopupRow(key: String, label text: String, options: [String]) {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false

        let headerLine = NSStackView()
        headerLine.orientation = .horizontal
        headerLine.alignment = .centerY
        headerLine.spacing = 6
        headerLine.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 11.5, weight: .semibold)
        headerLine.addArrangedSubview(lbl)

        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabels[key] = badge
        headerLine.addArrangedSubview(badge)

        headerLine.addArrangedSubview(NSView())

        let confirmBtn = NSButton(title: "Confirm ✓", target: self, action: #selector(confirmFieldClicked(_:)))
        confirmBtn.bezelStyle = .inline
        confirmBtn.controlSize = .small
        confirmBtn.identifier = NSUserInterfaceItemIdentifier(key)
        headerLine.addArrangedSubview(confirmBtn)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for opt in options {
            popup.addItem(withTitle: opt.isEmpty ? "(None)" : opt)
        }
        popup.controlSize = .regular
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.identifier = NSUserInterfaceItemIdentifier(key)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popupControls[key] = popup

        let err = NSTextField(labelWithString: "")
        err.font = .systemFont(ofSize: 10.5, weight: .medium)
        err.textColor = .systemRed
        err.isHidden = true
        errorLabels[key] = err

        row.addArrangedSubview(headerLine)
        row.addArrangedSubview(popup)
        row.addArrangedSubview(err)

        formContainer.addArrangedSubview(row)

        NSLayoutConstraint.activate([
            headerLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            popup.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            row.widthAnchor.constraint(equalTo: formContainer.widthAnchor),
        ])
    }

    private func addDateRow() {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false

        let headerLine = NSStackView()
        headerLine.orientation = .horizontal
        headerLine.alignment = .centerY
        headerLine.spacing = 6
        headerLine.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: "Issue Date (Month / Year):")
        lbl.font = .systemFont(ofSize: 11.5, weight: .semibold)
        headerLine.addArrangedSubview(lbl)

        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabels["issueDate"] = badge
        headerLine.addArrangedSubview(badge)

        headerLine.addArrangedSubview(NSView())

        let confirmBtn = NSButton(title: "Confirm ✓", target: self, action: #selector(confirmFieldClicked(_:)))
        confirmBtn.bezelStyle = .inline
        confirmBtn.controlSize = .small
        confirmBtn.identifier = NSUserInterfaceItemIdentifier("issueDate")
        headerLine.addArrangedSubview(confirmBtn)

        let inputStack = NSStackView()
        inputStack.orientation = .horizontal
        inputStack.spacing = 8
        inputStack.translatesAutoresizingMaskIntoConstraints = false

        let monthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        monthPopup.addItem(withTitle: "(Month)")
        let months = ["01 - JAN", "02 - FEB", "03 - MAR", "04 - APR", "05 - MAY", "06 - JUN", "07 - JUL", "08 - AUG", "09 - SEP", "10 - OCT", "11 - NOV", "12 - DEC"]
        for m in months {
            monthPopup.addItem(withTitle: m)
        }
        monthPopup.target = self
        monthPopup.action = #selector(popupChanged(_:))
        monthPopup.identifier = NSUserInterfaceItemIdentifier("issueMonth")
        popupControls["issueMonth"] = monthPopup
        inputStack.addArrangedSubview(monthPopup)

        let yearTf = NSTextField()
        yearTf.placeholderString = "YYYY (e.g. 1995)"
        yearTf.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        yearTf.delegate = self
        yearTf.identifier = NSUserInterfaceItemIdentifier("issueYear")
        textFields["issueYear"] = yearTf
        inputStack.addArrangedSubview(yearTf)

        let err = NSTextField(labelWithString: "")
        err.font = .systemFont(ofSize: 10.5, weight: .medium)
        err.textColor = .systemRed
        err.isHidden = true
        errorLabels["issueDate"] = err

        row.addArrangedSubview(headerLine)
        row.addArrangedSubview(inputStack)
        row.addArrangedSubview(err)

        formContainer.addArrangedSubview(row)

        NSLayoutConstraint.activate([
            headerLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            inputStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            inputStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            monthPopup.widthAnchor.constraint(equalToConstant: 120),
            yearTf.widthAnchor.constraint(equalToConstant: 100),
            row.widthAnchor.constraint(equalTo: formContainer.widthAnchor),
        ])
    }

    // MARK: - Populating Record

    // MARK: - Populating Record

    func setRecord(_ record: BondRecord?, candidate: BondRecord? = nil, progress: ReviewProgress? = nil) {
        if let p = progress {
            updateProgress(p)
        }

        guard let r = record else {
            self.currentRecord = nil
            self.candidateDuplicate = nil
            self.activeDraft = nil
            self.userEdits.removeAll()
            self.confirmedFields.removeAll()
            self.resolvedReasons.removeAll()
            self.acknowledgedWarnings.removeAll()
            titleLabel.stringValue = "No Record Selected"
            statusBadge.stringValue = "—"
            statusBadge.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
            clearFields()
            return
        }

        // If the same record is currently selected and has unsaved edits in draft that are not yet in `r`, protect the draft!
        if let existing = activeDraft, existing.recordId == r.id, existing.hasUnsavedChanges, !recordContainsDraftChanges(r) {
            updateExternalRecord(r, candidate: candidate, progress: progress)
            return
        }

        self.currentRecord = r
        self.candidateDuplicate = candidate
        self.userEdits.removeAll()
        self.confirmedFields = Set(r.userConfirmedFields ?? [])
        self.resolvedReasons = Set(r.resolvedReviewReasons ?? [])
        self.acknowledgedWarnings = Set(r.acknowledgedWarnings ?? [])
        self.activeDraft = ReviewDraft(record: r)
        hideConflictBanner()
        hideSuggestionsBanner()
        hideCompletionBanner()

        titleLabel.stringValue = "Bond #\(r.id.prefix(8))"
        updateStatusBadge(status: r.status)

        // Populate Fields
        setPopupSelection(key: "series", value: r.series)
        setTextFieldValue(key: "serial", value: r.serial)
        setPopupSelection(key: "denomination", value: r.denomination)

        // Month / Year
        if let mNum = monthNumber(r.issueMonth), let idx = Int(mNum), idx >= 1, idx <= 12 {
            popupControls["issueMonth"]?.selectItem(at: idx)
        } else {
            popupControls["issueMonth"]?.selectItem(at: 0)
        }
        setTextFieldValue(key: "issueYear", value: r.issueYear)

        setTextFieldValue(key: "owner", value: r.owner)
        setTextFieldValue(key: "secondName", value: r.secondName)
        setPopupSelection(key: "secondRole", value: r.secondRole)
        setTextFieldValue(key: "address", value: r.address)
        setTextFieldValue(key: "issuingAgent", value: r.issuingAgent)
        setTextFieldValue(key: "datingStamp", value: r.datingStamp)
        setTextFieldValue(key: "notes", value: r.notes)

        updateFieldBadgesAndErrors()
        updateReasonsBanner()
        updateDuplicateCard()
        showAIAnalysis(r.aiAnalysis, for: r)
    }

    /// Safely handles external updates (background OCR completion, queue updates, etc.)
    /// for the currently open record without erasing active drafts.
    func updateExternalRecord(_ record: BondRecord, candidate: BondRecord? = nil, progress: ReviewProgress? = nil) {
        if let p = progress {
            updateProgress(p)
        }

        self.candidateDuplicate = candidate
        updateDuplicateCard()

        guard let draft = activeDraft, draft.recordId == record.id else {
            setRecord(record, candidate: candidate, progress: progress)
            return
        }

        // If no unsaved edits exist in draft, reload cleanly
        if !draft.hasUnsavedChanges {
            setRecord(record, candidate: candidate, progress: progress)
            return
        }

        // Draft has unsaved edits: refresh only non-editable metadata and detect genuine concurrent edits
        self.currentRecord?.notes = record.notes
        self.currentRecord?.photo = record.photo
        self.currentRecord?.sourcePhoto = record.sourcePhoto
        self.currentRecord?.associatedPhotos = record.associatedPhotos
        self.currentRecord?.fieldConfidence = record.fieldConfidence
        self.currentRecord?.fieldSource = record.fieldSource
        self.currentRecord?.rawOCR = record.rawOCR
        self.currentRecord?.additionalOCR = record.additionalOCR
        self.currentRecord?.aiAnalysis = record.aiAnalysis

        // Compare editable fields to detect genuine concurrent edits between baseRecord and external update
        let fields: [(key: String, baseVal: String, extVal: String)] = [
            ("series", draft.baseRecord.series, record.series),
            ("serial", draft.baseRecord.serial, record.serial),
            ("denomination", draft.baseRecord.denomination, record.denomination),
            ("issueMonth", draft.baseRecord.issueMonth, record.issueMonth),
            ("issueYear", draft.baseRecord.issueYear, record.issueYear),
            ("owner", draft.baseRecord.owner, record.owner),
            ("secondName", draft.baseRecord.secondName, record.secondName),
            ("secondRole", draft.baseRecord.secondRole, record.secondRole),
            ("address", draft.baseRecord.address, record.address),
            ("issuingAgent", draft.baseRecord.issuingAgent, record.issuingAgent),
            ("datingStamp", draft.baseRecord.datingStamp, record.datingStamp),
        ]

        var conflicts: [(field: String, yourEdit: String, externalVal: String)] = []
        for f in fields where f.extVal != f.baseVal {
            let currentVal = userEdits[f.key] ?? f.baseVal
            if currentVal != f.extVal {
                conflicts.append((field: f.key, yourEdit: currentVal, externalVal: f.extVal))
            }
        }

        if !conflicts.isEmpty {
            showConflictBanner(conflicts: conflicts, externalRecord: record)
        }

        updateFieldBadgesAndErrors()
        updateReasonsBanner()
        showAIAnalysis(record.aiAnalysis, for: record)
    }

    func updateProgress(_ progress: ReviewProgress) {
        baseProgressText = progress.displayString
        refreshProgressLabel()
    }

    func updateAIProgress(_ value: String) {
        currentAIProgressText = value
        refreshProgressLabel()
    }

    func refreshProgressLabel() {
        let trimmed = currentAIProgressText.trimmingCharacters(in: .whitespacesAndNewlines)
        progressLabel.stringValue = trimmed.isEmpty ? baseProgressText : "\(baseProgressText)  •  \(trimmed)"
    }

    var latestExternalRecord: BondRecord?

    func clearFields() {
        for tf in textFields.values {
            tf.stringValue = ""
        }
        for p in popupControls.values {
            p.selectItem(at: 0)
        }
        for b in badgeLabels.values {
            b.stringValue = ""
        }
        for p in provenanceLabels.values {
            p.stringValue = ""
        }
        for e in errorLabels.values {
            e.isHidden = true
        }
        reasonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        duplicateBox.isHidden = true
        hideConflictBanner()
        hideSuggestionsBanner()
        hideCompletionBanner()
    }

    func updateStatusBadge(status: String) {
        statusBadge.stringValue = status
        switch status {
        case "OK":
            statusBadge.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case "REVIEW":
            statusBadge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case "DUPLICATE":
            statusBadge.layer?.backgroundColor = NSColor.systemPurple.cgColor
        case "PROCESSING":
            statusBadge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        default:
            statusBadge.layer?.backgroundColor = NSColor.systemGray.cgColor
        }
    }

    func setTextFieldValue(key: String, value: String) {
        textFields[key]?.stringValue = value
    }

    func setPopupSelection(key: String, value: String) {
        guard let popup = popupControls[key] else { return }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let item = popup.itemArray.first(where: { $0.title.uppercased() == clean }) {
            popup.select(item)
        } else if clean.isEmpty {
            popup.selectItem(at: 0)
        } else {
            popup.addItem(withTitle: value)
            popup.selectItem(withTitle: value)
        }
    }

}
