import AppKit

protocol ReviewEditorViewDelegate: AnyObject {
    func reviewEditorDidRequestSave(_ editor: ReviewEditorView, andNext: Bool)
    func reviewEditorDidRequestPrevious(_ editor: ReviewEditorView)
    func reviewEditorDidRequestNext(_ editor: ReviewEditorView)
    func reviewEditorDidRequestRevert(_ editor: ReviewEditorView)
    func reviewEditorDidRequestReprocess(_ editor: ReviewEditorView)
    func reviewEditor(_ editor: ReviewEditorView, didResolveReason reason: String)
    func reviewEditor(_ editor: ReviewEditorView, didAcknowledgeWarning warning: String)
    func reviewEditor(_ editor: ReviewEditorView, didRequestKeepSeparate candidate: BondRecord)
    func reviewEditor(_ editor: ReviewEditorView, didRequestMergeCandidate candidate: BondRecord)
    func reviewEditor(_ editor: ReviewEditorView, didRequestCompareCandidatePhoto candidate: BondRecord)
}

/// Rich AppKit editor panel for reviewing and correcting bond fields, resolving review reasons,
/// comparing near-match duplicates, and performing keyboard-first workflow navigation.
final class ReviewEditorView: NSView, NSTextFieldDelegate {
    weak var delegate: ReviewEditorViewDelegate?

    private var currentRecord: BondRecord?
    private var candidateDuplicate: BondRecord?

    // Tracks uncommitted field modifications in current review session
    private var userEdits: [String: String] = [:]
    private var confirmedFields: Set<String> = []
    private var resolvedReasons: Set<String> = []
    private var acknowledgedWarnings: Set<String> = []

    // Header Controls
    private let headerBox = NSBox()
    private let titleLabel = NSTextField(labelWithString: "Bond Review")
    private let statusBadge = NSTextField(labelWithString: "REVIEW")
    private let progressLabel = NSTextField(labelWithString: "Reviewed 0 / 0 — 0 remaining")
    private let prevBtn = NSButton(title: "‹ Prev", target: nil, action: nil)
    private let nextBtn = NSButton(title: "Next ›", target: nil, action: nil)

    // Scrollable Form Container
    private let scrollView = NSScrollView()
    private let formContainer = NSStackView()

    // Banners
    private let reasonsStack = NSStackView()
    private let duplicateBox = NSBox()
    private let duplicateStack = NSStackView()

    // Field Controls Map
    private var textFields: [String: NSTextField] = [:]
    private var popupControls: [String: NSPopUpButton] = [:]
    private var badgeLabels: [String: NSTextField] = [:]
    private var provenanceLabels: [String: NSTextField] = [:]
    private var errorLabels: [String: NSTextField] = [:]

    // Bottom Action Bar
    private let bottomBar = NSBox()
    private let saveAndNextBtn = NSButton(title: "Save & Next", target: nil, action: nil)
    private let saveBtn = NSButton(title: "Save", target: nil, action: nil)
    private let revertBtn = NSButton(title: "Revert", target: nil, action: nil)
    private let reprocessBtn = NSButton(title: "Reprocess Photo", target: nil, action: nil)
    private let reprocessSpinner = NSProgressIndicator()
    private let confirmAllBtn = NSButton(title: "Confirm All Valid ✓", target: nil, action: nil)
    private let shortcutsLabel = NSTextField(labelWithString: "Shortcuts: ⌘⏎ Save & Next  •  ⌘S Save  •  ⌘[ / ⌘] Prev/Next  •  ⌘K Confirm Field  •  ⌘0 Fit Photo")

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
            headerBox.heightAnchor.constraint(equalToConstant: 58),

            scrollView.topAnchor.constraint(equalTo: headerBox.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 80),
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

        headerBox.addSubview(titleLabel)
        headerBox.addSubview(statusBadge)
        headerBox.addSubview(progressLabel)
        headerBox.addSubview(prevBtn)
        headerBox.addSubview(nextBtn)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 10),

            statusBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            statusBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            statusBadge.heightAnchor.constraint(equalToConstant: 18),

            progressLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 14),
            progressLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            nextBtn.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor, constant: -14),
            nextBtn.centerYAnchor.constraint(equalTo: headerBox.centerYAnchor),

            prevBtn.trailingAnchor.constraint(equalTo: nextBtn.leadingAnchor, constant: -6),
            prevBtn.centerYAnchor.constraint(equalTo: headerBox.centerYAnchor),
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
        reprocessBtn.controlSize = .regular
        reprocessBtn.target = self
        reprocessBtn.action = #selector(reprocessClicked)
        reprocessBtn.toolTip = "Reprocess saved photograph with Vision OCR (⌘P)"
        reprocessBtn.translatesAutoresizingMaskIntoConstraints = false

        reprocessSpinner.style = .spinning
        reprocessSpinner.controlSize = .small
        reprocessSpinner.isDisplayedWhenStopped = false
        reprocessSpinner.translatesAutoresizingMaskIntoConstraints = false

        confirmAllBtn.bezelStyle = .inline
        confirmAllBtn.controlSize = .small
        confirmAllBtn.target = self
        confirmAllBtn.action = #selector(confirmAllClicked)
        confirmAllBtn.toolTip = "Confirm all valid fields at once"
        confirmAllBtn.translatesAutoresizingMaskIntoConstraints = false

        shortcutsLabel.font = .systemFont(ofSize: 10.5)
        shortcutsLabel.textColor = .secondaryLabelColor
        shortcutsLabel.translatesAutoresizingMaskIntoConstraints = false

        bottomBar.addSubview(saveAndNextBtn)
        bottomBar.addSubview(saveBtn)
        bottomBar.addSubview(revertBtn)
        bottomBar.addSubview(reprocessBtn)
        bottomBar.addSubview(reprocessSpinner)
        bottomBar.addSubview(confirmAllBtn)
        bottomBar.addSubview(shortcutsLabel)

        NSLayoutConstraint.activate([
            saveAndNextBtn.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -14),
            saveAndNextBtn.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 10),
            saveAndNextBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            saveBtn.trailingAnchor.constraint(equalTo: saveAndNextBtn.leadingAnchor, constant: -8),
            saveBtn.centerYAnchor.constraint(equalTo: saveAndNextBtn.centerYAnchor),

            revertBtn.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -8),
            revertBtn.centerYAnchor.constraint(equalTo: saveAndNextBtn.centerYAnchor),

            reprocessBtn.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
            reprocessBtn.centerYAnchor.constraint(equalTo: saveAndNextBtn.centerYAnchor),

            reprocessSpinner.leadingAnchor.constraint(equalTo: reprocessBtn.trailingAnchor, constant: 6),
            reprocessSpinner.centerYAnchor.constraint(equalTo: reprocessBtn.centerYAnchor),

            confirmAllBtn.leadingAnchor.constraint(equalTo: reprocessSpinner.trailingAnchor, constant: 12),
            confirmAllBtn.centerYAnchor.constraint(equalTo: saveAndNextBtn.centerYAnchor),

            shortcutsLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
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

        // Configure Reasons Stack
        reasonsStack.orientation = .vertical
        reasonsStack.alignment = .leading
        reasonsStack.spacing = 6
        reasonsStack.translatesAutoresizingMaskIntoConstraints = false
        formContainer.addArrangedSubview(reasonsStack)

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

        NSLayoutConstraint.activate([
            headerLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            tf.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            tf.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            tf.heightAnchor.constraint(equalToConstant: 24),
            row.widthAnchor.constraint(equalTo: formContainer.widthAnchor),
        ])

        formContainer.addArrangedSubview(row)
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

        NSLayoutConstraint.activate([
            headerLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            popup.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            row.widthAnchor.constraint(equalTo: formContainer.widthAnchor),
        ])

        formContainer.addArrangedSubview(row)
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

        NSLayoutConstraint.activate([
            headerLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            inputStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            inputStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            monthPopup.widthAnchor.constraint(equalToConstant: 120),
            yearTf.widthAnchor.constraint(equalToConstant: 100),
            row.widthAnchor.constraint(equalTo: formContainer.widthAnchor),
        ])

        formContainer.addArrangedSubview(row)
    }

    // MARK: - Populating Record

    func setRecord(_ record: BondRecord?, candidate: BondRecord? = nil, progress: ReviewProgress? = nil) {
        self.currentRecord = record
        self.candidateDuplicate = candidate
        self.userEdits.removeAll()
        self.confirmedFields = Set(record?.userConfirmedFields ?? [])
        self.resolvedReasons = Set(record?.resolvedReviewReasons ?? [])
        self.acknowledgedWarnings = Set(record?.acknowledgedWarnings ?? [])

        if let p = progress {
            progressLabel.stringValue = p.displayString
        }

        guard let r = record else {
            titleLabel.stringValue = "No Record Selected"
            statusBadge.stringValue = "—"
            statusBadge.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
            clearFields()
            return
        }

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
    }

    private func clearFields() {
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
    }

    private func updateStatusBadge(status: String) {
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

    private func setTextFieldValue(key: String, value: String) {
        textFields[key]?.stringValue = value
    }

    private func setPopupSelection(key: String, value: String) {
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

    // MARK: - Badges and Provenance

    private func updateFieldBadgesAndErrors() {
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

    private func getEffectiveValue(key: String) -> String {
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

    private func previewRecord() -> BondRecord {
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

    private func updateReasonsBanner() {
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

    private func updateDuplicateCard() {
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

    // MARK: - Actions

    @objc private func prevClicked() {
        delegate?.reviewEditorDidRequestPrevious(self)
    }

    @objc private func nextClicked() {
        delegate?.reviewEditorDidRequestNext(self)
    }

    @objc private func saveClicked() {
        delegate?.reviewEditorDidRequestSave(self, andNext: false)
    }

    @objc private func saveAndNextClicked() {
        delegate?.reviewEditorDidRequestSave(self, andNext: true)
    }

    @objc private func revertClicked() {
        delegate?.reviewEditorDidRequestRevert(self)
    }

    @objc private func reprocessClicked() {
        reprocessSpinner.startAnimation(nil)
        delegate?.reviewEditorDidRequestReprocess(self)
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

    @objc private func confirmFieldClicked(_ sender: NSButton) {
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

    @objc private func confirmAllClicked() {
        let keys = ["series", "serial", "denomination", "issueMonth", "issueYear", "issueDate", "owner", "secondName", "address", "issuingAgent", "datingStamp"]
        for k in keys {
            let val = getEffectiveValue(key: k)
            if !val.isEmpty {
                confirmedFields.insert(k)
            }
        }
        updateFieldBadgesAndErrors()
    }

    @objc private func resolveReasonClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        resolvedReasons.insert(key)
        delegate?.reviewEditor(self, didResolveReason: key)
        updateReasonsBanner()
    }

    @objc private func keepSeparateClicked() {
        guard let cand = candidateDuplicate else { return }
        delegate?.reviewEditor(self, didRequestKeepSeparate: cand)
    }

    @objc private func mergeDuplicateClicked() {
        guard let cand = candidateDuplicate else { return }
        delegate?.reviewEditor(self, didRequestMergeCandidate: cand)
    }

    @objc private func comparePhotoClicked() {
        guard let cand = candidateDuplicate else { return }
        delegate?.reviewEditor(self, didRequestCompareCandidatePhoto: cand)
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
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
        userEdits
    }

    var pendingConfirmedFields: Set<String> {
        confirmedFields
    }

    var pendingResolvedReasons: Set<String> {
        resolvedReasons
    }

    var pendingAcknowledgedWarnings: Set<String> {
        acknowledgedWarnings
    }

    var hasUnsavedChanges: Bool {
        !userEdits.isEmpty || confirmedFields != Set(currentRecord?.userConfirmedFields ?? [])
    }
}
