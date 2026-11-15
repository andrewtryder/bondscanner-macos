import AppKit

/// Custom window subclass ensuring command key equivalents (⌘S, ⌘⏎, ⌘[, ⌘], ⌘K, etc.)
/// route reliably through `ReviewWindowController` even when a field editor (`NSTextField`)
/// or popup button currently holds first-responder focus.
final class ReviewWindow: NSWindow {
    weak var reviewController: ReviewWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller = reviewController, controller.handleKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Dedicated side-by-side Review & Correction Window Controller.
/// Combines full interactive photograph inspection on the left with rich
/// field correction, duplicate resolution, and keyboard shortcuts on the right.
final class ReviewWindowController: NSWindowController, NSWindowDelegate, ReviewCoordinatorDelegate, ReviewEditorViewDelegate {
    let coordinator: ReviewCoordinator
    private let splitView = NSSplitView()
    let photoView = ReviewPhotoView()
    let editorView = ReviewEditorView()

    var onRecordsChanged: (([BondRecord]) -> Void)?
    var unsavedChangesPromptHandler: (() -> NSApplication.ModalResponse)?
    var suppressModalAlerts: Bool = false
    private(set) var lastErrorAlertMessage: String?

    /// Logic tests exercise the controller and key-routing methods directly. Keeping
    /// its NSWindow ordered out prevents XCTest from leaving review windows on the
    /// desktop while preserving the same view/controller behavior under test.
    private var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(coordinator: ReviewCoordinator) {
        self.coordinator = coordinator

        let window = ReviewWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bond Review & Correction"
        window.minSize = NSSize(width: 950, height: 600)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.reviewController = self
        window.delegate = self

        coordinator.delegate = self
        editorView.delegate = self

        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayout() {
        guard let win = window else { return }

        let content = NSView(frame: win.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        win.contentView = content

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        splitView.addSubview(photoView)
        splitView.addSubview(editorView)

        content.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Initial split position ~55% photo, 45% editor
        splitView.setPosition(650, ofDividerAt: 0)

        // Initial record load if available
        if let rec = coordinator.currentRecord {
            loadRecordIntoViews(rec)
        } else if let first = coordinator.queuedRecords.first {
            coordinator.selectRecord(id: first.id)
        }
    }

    func showReviewWindow(selectingRecordId: String? = nil, filter: ReviewFilterCategory? = nil) {
        if let f = filter {
            coordinator.activeFilter = f
        }
        if let selId = selectingRecordId {
            coordinator.selectRecord(id: selId)
        } else if coordinator.currentRecordId == nil {
            if let firstUnresolved = coordinator.nextUnresolvedRecord(excludingCurrent: false) {
                coordinator.selectRecord(id: firstUnresolved.id)
            } else if let first = coordinator.queuedRecords.first {
                coordinator.selectRecord(id: first.id)
            }
        }
        guard !isRunningUnitTests else {
            window?.orderOut(nil)
            return
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadRecordIntoViews(_ record: BondRecord) {
        let origImg = coordinator.loadImage(relativePath: record.sourcePhoto.isEmpty ? record.photo : record.sourcePhoto)
        let procImg = coordinator.loadImage(relativePath: record.photo)
        photoView.setImages(original: origImg, processed: procImg)

        let candidate = coordinator.findDuplicateCandidate(for: record)
        editorView.setRecord(record, candidate: candidate, progress: coordinator.progress)
    }

    // MARK: - ReviewCoordinatorDelegate

    func reviewCoordinator(_ coordinator: ReviewCoordinator, didUpdateRecords records: [BondRecord]) {
        onRecordsChanged?(records)
        editorView.updateAIProgress(coordinator.aiProgressText)
    }

    func reviewCoordinator(_ coordinator: ReviewCoordinator, didSelectRecord record: BondRecord?) {
        guard let rec = record else {
            editorView.setRecord(nil, progress: coordinator.progress)
            photoView.setImages(original: nil, processed: nil)
            return
        }
        loadRecordIntoViews(rec)
    }

    func reviewCoordinator(_ coordinator: ReviewCoordinator, didUpdateSelectedRecord record: BondRecord) {
        let candidate = coordinator.findDuplicateCandidate(for: record)
        editorView.updateExternalRecord(record, candidate: candidate, progress: coordinator.progress)
    }

    func reviewCoordinator(_ coordinator: ReviewCoordinator, didChangeProgress progress: ReviewProgress) {
        editorView.updateProgress(progress)
        editorView.updateAIProgress(coordinator.aiProgressText)
    }

    // MARK: - ReviewEditorViewDelegate

    @discardableResult
    func reviewEditorDidRequestSave(_ editor: ReviewEditorView, andNext: Bool) -> Bool {
        guard let current = coordinator.currentRecord else { return false }

        do {
            if andNext {
                let next = try coordinator.saveAndNext(
                    record: current,
                    userEdits: editor.pendingEdits,
                    confirmedFields: editor.pendingConfirmedFields,
                    resolvedReasons: editor.pendingResolvedReasons,
                    acknowledgedWarnings: editor.pendingAcknowledgedWarnings
                )
                if next == nil {
                    editor.showQueueCompleted(message: "All items in this review queue have been reviewed.")
                }
            } else {
                _ = try coordinator.saveRecord(
                    record: current,
                    userEdits: editor.pendingEdits,
                    confirmedFields: editor.pendingConfirmedFields,
                    resolvedReasons: editor.pendingResolvedReasons,
                    acknowledgedWarnings: editor.pendingAcknowledgedWarnings
                )
            }
            return true
        } catch {
            showErrorAlert(title: "Save Failed", message: error.localizedDescription)
            return false
        }
    }

    func reviewEditorDidRequestPrevious(_ editor: ReviewEditorView) {
        guard confirmDiscardUnsavedChangesIfNeeded() else { return }
        _ = coordinator.previousRecord()
    }

    func reviewEditorDidRequestNext(_ editor: ReviewEditorView) {
        guard confirmDiscardUnsavedChangesIfNeeded() else { return }
        _ = coordinator.nextRecord()
    }

    func reviewEditorDidRequestRevert(_ editor: ReviewEditorView) {
        guard let current = coordinator.currentRecord else { return }
        editor.discardDraft()
        loadRecordIntoViews(current)
    }

    func reviewEditorDidRequestReprocess(_ editor: ReviewEditorView) {
        guard let current = coordinator.currentRecord else { return }
        editor.setReprocessing(true)
        let activeEdits = editor.pendingEdits

        Task { @MainActor in
            defer { editor.setReprocessing(false) }
            do {
                let result = try await coordinator.reprocessPhoto(for: current, userActiveEdits: activeEdits)
                if !result.suggestions.isEmpty {
                    editor.showSuggestionsBanner(suggestions: result.suggestions)
                    let fields = result.suggestions.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                    showInfoAlert(title: "Reprocess Completed", message: "Newly detected fields preserved as suggestions for your review: \(fields)")
                }
            } catch {
                showErrorAlert(title: "Reprocessing Error", message: error.localizedDescription)
            }
        }
    }

    func reviewEditorDidRequestAIAnalysis(_ editor: ReviewEditorView) {
        guard let current = coordinator.currentRecord else { return }
        coordinator.enqueueAIReview(recordID: current.id, force: true)
    }

    func reviewEditorDidRequestAnalyzeExistingAI(_ editor: ReviewEditorView) {
        coordinator.analyzeExistingReviews()
    }

    func reviewEditor(_ editor: ReviewEditorView, didResolveReason reason: String) {
        guard let current = coordinator.currentRecord else { return }
        var resolved = Set(current.resolvedReviewReasons ?? [])
        resolved.insert(reason)
        _ = try? coordinator.saveRecord(
            record: current,
            userEdits: editor.pendingEdits,
            confirmedFields: editor.pendingConfirmedFields,
            resolvedReasons: resolved,
            acknowledgedWarnings: editor.pendingAcknowledgedWarnings
        )
    }

    func reviewEditor(_ editor: ReviewEditorView, didAcknowledgeWarning warning: String) {
        guard let current = coordinator.currentRecord else { return }
        var ack = Set(current.acknowledgedWarnings ?? [])
        ack.insert(warning)
        _ = try? coordinator.saveRecord(
            record: current,
            userEdits: editor.pendingEdits,
            confirmedFields: editor.pendingConfirmedFields,
            resolvedReasons: editor.pendingResolvedReasons,
            acknowledgedWarnings: ack
        )
    }

    func reviewEditor(_ editor: ReviewEditorView, didRequestKeepSeparate candidate: BondRecord) {
        guard let current = coordinator.currentRecord else { return }
        do {
            try coordinator.keepSeparate(record: current, candidate: candidate)
        } catch {
            showErrorAlert(title: "Keep Separate Failed", message: error.localizedDescription)
        }
    }

    func reviewEditor(_ editor: ReviewEditorView, didRequestMergeCandidate candidate: BondRecord) {
        guard let current = coordinator.currentRecord else { return }
        if !suppressModalAlerts {
            let alert = NSAlert()
            alert.messageText = "Confirm Consolidating Same Bond?"
            alert.informativeText = "This will merge candidate bond #\(candidate.id.prefix(8)) into #\(current.id.prefix(8)). Both photographs will be preserved durably, and user-confirmed values will be kept."
            alert.addButton(withTitle: "Merge Bonds")
            alert.addButton(withTitle: "Cancel")
            let resp = alert.runModal()
            guard resp == .alertFirstButtonReturn else { return }
        }

        do {
            _ = try coordinator.confirmSameBond(
                primary: current,
                duplicate: candidate,
                preferredEdits: editor.pendingEdits
            )
        } catch {
            showErrorAlert(title: "Merge Failed", message: error.localizedDescription)
        }
    }

    func reviewEditor(_ editor: ReviewEditorView, didRequestCompareCandidatePhoto candidate: BondRecord) {
        let origImg = coordinator.loadImage(relativePath: candidate.sourcePhoto.isEmpty ? candidate.photo : candidate.sourcePhoto)
        let procImg = coordinator.loadImage(relativePath: candidate.photo)
        photoView.setImages(original: origImg, processed: procImg)
    }

    // MARK: - Keyboard Shortcuts & Navigation Safety

    func confirmDiscardUnsavedChangesIfNeeded() -> Bool {
        guard editorView.hasUnsavedChanges else { return true }
        let resp: NSApplication.ModalResponse
        if let customHandler = unsavedChangesPromptHandler {
            resp = customHandler()
        } else {
            let alert = NSAlert()
            alert.messageText = "Unsaved Changes"
            alert.informativeText = "You have unsaved field changes on this bond. Save before proceeding?"
            alert.addButton(withTitle: "Save Changes")
            alert.addButton(withTitle: "Discard Changes")
            alert.addButton(withTitle: "Cancel")
            resp = alert.runModal()
        }
        if resp == .alertFirstButtonReturn {
            return reviewEditorDidRequestSave(editorView, andNext: false)
        } else if resp == .alertSecondButtonReturn {
            editorView.discardDraft()
            return true
        } else {
            return false
        }
    }

    private func showErrorAlert(title: String, message: String) {
        lastErrorAlertMessage = message
        guard !suppressModalAlerts else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func showInfoAlert(title: String, message: String) {
        guard !suppressModalAlerts else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// Routes key equivalents (⌘S, ⌘⏎, ⌘[, ⌘], ⌘K, ⌘P, ⌘R, ⌘T, ⌘=, ⌘-, ⌘0)
    /// reliably even when a text field or popup button holds focus.
    @discardableResult
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 36 || event.keyCode == 76 || chars == "\r" || chars == "\n" {
            reviewEditorDidRequestSave(editorView, andNext: true)
            return true
        }

        switch chars {
        case "s":
            reviewEditorDidRequestSave(editorView, andNext: false)
            return true
        case "[":
            reviewEditorDidRequestPrevious(editorView)
            return true
        case "]":
            reviewEditorDidRequestNext(editorView)
            return true
        case "k":
            editorView.confirmCurrentOrAllValidFields()
            return true
        case "p":
            reviewEditorDidRequestReprocess(editorView)
            return true
        case "r":
            photoView.rotateClockwise()
            return true
        case "t":
            photoView.togglePhoto()
            return true
        case "=", "+":
            photoView.zoomIn()
            return true
        case "-":
            photoView.zoomOut()
            return true
        case "0":
            photoView.zoomToFit()
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyEquivalent(event) {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return confirmDiscardUnsavedChangesIfNeeded()
    }
}
