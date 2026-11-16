import AppKit
import Foundation

extension BondScannerApp {
    /// Resolve and verify the location before database, logging, export, or camera startup.
    func prepareCollectionLocation() throws {
        // Explicit development overrides remain isolated from the saved production setting.
        let overridden = !(ProcessInfo.processInfo.environment["BONDSCANNER_OUTPUT_ROOT"] ?? "").isEmpty
        let preferences = CollectionLocationPreferences()
        var state = overridden ? CollectionLocationState(activePath: nil, pending: nil) : try preferences.load()
        // A lock held for the entire process prevents another current version from
        // continuing to write the old collection while a switch is applied.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BondScanner", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lockPath = support.appendingPathComponent("collection.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw DatabaseError.permissionDenied("Could not open the collection process lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw DatabaseError.databaseLocked("Another Bond Scanner instance is using collection storage.")
        }
        collectionLockFD = fd
        if overridden {
            return
        }
        let previous = state.activePath ?? StorageConfiguration.defaultOutputRoot.path
        if let request = state.pending {
            guard request.sourcePath == previous else {
                throw DatabaseError.restoreFailed("The pending change does not match the saved collection location.")
            }
            while true {
                do {
                    _ = try preferences.applyPending(backups: backupsRoot)
                    state = try preferences.load()
                    break
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Collection location could not be changed"
                    alert.informativeText = "\(error.localizedDescription)\n\nThe previous collection remains at \(previous)."
                    alert.addButton(withTitle: "Retry")
                    alert.addButton(withTitle: "Keep Previous Location")
                    alert.addButton(withTitle: "Quit")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        continue
                    }
                    guard response == .alertSecondButtonReturn else { throw CollectionStartupCancelled.cancelled }
                    state.pending = nil
                    try preferences.save(state)
                    break
                }
            }
        }
        let path = state.activePath ?? StorageConfiguration.defaultOutputRoot.path
        var root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.path == path else { throw DatabaseError.restoreFailed("The saved location is not a canonical absolute path.") }
        while true {
            do {
                if state.activePath != nil || FileManager.default.fileExists(atPath: root.appendingPathComponent("bonds.sqlite3").path) {
                    _ = try CollectionValidator.validate(root: root, backups: backupsRoot)
                } else {
                    try CollectionValidator.validateFirstLaunch(root: root)
                }
                break
            } catch {
                let alert = NSAlert()
                alert.messageText = "Collection is unavailable"
                alert.informativeText = "\(error.localizedDescription)\n\nRetry, open an existing collection, or create a new one. Your previous collection will remain untouched."
                alert.addButton(withTitle: "Retry")
                alert.addButton(withTitle: "Open Existing Collection…")
                alert.addButton(withTitle: "Create New Collection…")
                alert.addButton(withTitle: "Quit")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    continue
                }
                let action: CollectionSwitchAction
                if response == .alertSecondButtonReturn {
                    action = .open
                } else if response == .alertThirdButtonReturn {
                    action = .new
                } else {
                    throw CollectionStartupCancelled.cancelled
                }
                do {
                    if let selected = try chooseRecoveryCollection(from: root, action: action, preferences: preferences) {
                        root = selected
                        state = try preferences.load()
                    }
                } catch {
                    showLocationError(error)
                }
            }
        }
        StorageConfiguration.shared.setLaunchOutputRoot(root)
    }

    func chooseRecoveryCollection(from previous: URL, action: CollectionSwitchAction, preferences: CollectionLocationPreferences) throws -> URL? {
        let picker = NSOpenPanel()
        picker.title = action == .open ? "Open Existing Collection" : "Choose an Empty Folder for the New Collection"
        picker.prompt = action == .open ? "Open Collection" : "Choose Folder"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = action == .new
        guard picker.runModal() == .OK, let destination = picker.url?.standardizedFileURL else { return nil }
        if action == .new {
            let confirm = NSAlert()
            confirm.messageText = "Create a new empty collection?"
            confirm.informativeText = "Your previous collection remains at \(previous.path). Its records and photographs will not be moved."
            confirm.addButton(withTitle: "Create Empty Collection")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return nil }
        }
        let request = PendingCollectionSwitch(sourcePath: previous.path, destinationPath: destination.path, action: action)
        let selected = try CollectionSwitchCoordinator.apply(request, backups: backupsRoot)
        var state = try preferences.load()
        state.activePath = selected.path
        state.pending = nil
        try preferences.save(state)
        return selected
    }

    @objc func openSettings() {
        if let settingsWindow = settingsWindow {
            refreshSettingsLocation()
            refreshSettingsCamera()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 490),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        let content = panel.contentView!

        // Section 1: Collection Storage
        let heading = NSTextField(labelWithString: "Collection Storage")
        heading.font = .boldSystemFont(ofSize: 15)
        heading.frame = NSRect(x: 24, y: 450, width: 570, height: 22)
        content.addSubview(heading)

        let location = NSTextField(wrappingLabelWithString: "")
        location.frame = NSRect(x: 24, y: 390, width: 570, height: 55)
        location.lineBreakMode = .byTruncatingMiddle
        content.addSubview(location)
        settingsLocationLabel = location

        let explanation = NSTextField(wrappingLabelWithString: "This folder contains the SQLite database, original and processed photos, and automatic CSV and JSON exports.")
        explanation.frame = NSRect(x: 24, y: 350, width: 570, height: 36)
        explanation.textColor = .secondaryLabelColor
        content.addSubview(explanation)

        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseCollectionFolder))
        choose.frame = NSRect(x: 24, y: 310, width: 130, height: 32)
        content.addSubview(choose)

        let finder = NSButton(title: "Open in Finder", target: self, action: #selector(openCollectionInFinder))
        finder.frame = NSRect(x: 162, y: 310, width: 130, height: 32)
        content.addSubview(finder)

        let restore = NSButton(title: "Restore Default Location", target: self, action: #selector(restoreDefaultCollection))
        restore.frame = NSRect(x: 300, y: 310, width: 180, height: 32)
        content.addSubview(restore)

        // Separator
        let sep = NSBox(frame: NSRect(x: 24, y: 290, width: 570, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)

        // Section 2: Camera
        let camHeading = NSTextField(labelWithString: "Camera")
        camHeading.font = .boldSystemFont(ofSize: 15)
        camHeading.frame = NSRect(x: 24, y: 255, width: 570, height: 22)
        content.addSubview(camHeading)

        let camLabel = NSTextField(labelWithString: "Webcam:")
        camLabel.font = .systemFont(ofSize: 13, weight: .medium)
        camLabel.frame = NSRect(x: 24, y: 220, width: 130, height: 20)
        content.addSubview(camLabel)

        let camPopUp = NSPopUpButton(frame: NSRect(x: 155, y: 216, width: 440, height: 26), pullsDown: false)
        camPopUp.target = self
        camPopUp.action = #selector(settingsCameraChanged(_:))
        content.addSubview(camPopUp)
        settingsCameraPopUp = camPopUp

        let expLabel = NSTextField(labelWithString: "Smart Exposure:")
        expLabel.font = .systemFont(ofSize: 13, weight: .medium)
        expLabel.frame = NSRect(x: 24, y: 175, width: 130, height: 20)
        content.addSubview(expLabel)

        let expPopUp = NSPopUpButton(frame: NSRect(x: 155, y: 171, width: 440, height: 26), pullsDown: false)
        expPopUp.target = self
        expPopUp.action = #selector(settingsSmartExposureChanged(_:))
        content.addSubview(expPopUp)
        settingsSmartExposurePopUp = expPopUp

        let camStatus = NSTextField(wrappingLabelWithString: "")
        camStatus.font = .systemFont(ofSize: 12)
        camStatus.textColor = .secondaryLabelColor
        camStatus.frame = NSRect(x: 24, y: 95, width: 570, height: 65)
        content.addSubview(camStatus)
        settingsCameraStatusLabel = camStatus

        let diagBtn = NSButton(title: "Hardware Diagnostics…", target: self, action: #selector(showHardwareDiagnostics))
        diagBtn.frame = NSRect(x: 24, y: 45, width: 180, height: 32)
        content.addSubview(diagBtn)

        settingsWindow = panel
        refreshSettingsLocation()
        refreshSettingsCamera()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshSettingsCamera() {
        guard let camPopUp = settingsCameraPopUp,
              let expPopUp = settingsSmartExposurePopUp,
              let statusLabel = settingsCameraStatusLabel
        else { return }

        // Populate camera popup
        camPopUp.removeAllItems()
        camPopUp.addItem(withTitle: "Automatic — Prefer USB Webcam (Recommended)")
        camPopUp.lastItem?.representedObject = "automatic"

        let currentSelection = webcamPreferences.loadSelection()
        var selectedIndex = 0

        for (idx, descriptor) in connectedDeviceDescriptors.enumerated() {
            camPopUp.addItem(withTitle: descriptor.displayNameWithCategory)
            camPopUp.lastItem?.representedObject = descriptor
            if case let .explicit(id) = currentSelection, id == descriptor.id {
                selectedIndex = idx + 1
            }
        }

        if currentSelection == .automaticPreferUSB {
            selectedIndex = 0
        }
        camPopUp.selectItem(at: selectedIndex)

        // Populate exposure mode popup
        expPopUp.removeAllItems()
        for mode in SmartExposureMode.allCases {
            expPopUp.addItem(withTitle: mode.title)
            expPopUp.lastItem?.representedObject = mode
        }
        let currentMode = smartExposurePreferences.loadMode()
        if let idx = SmartExposureMode.allCases.firstIndex(of: currentMode) {
            expPopUp.selectItem(at: idx)
        }

        // Status text
        let activeDeviceText = captureDevice.map { d -> String in
            let cat = WebcamResolver.categorize(device: d)
            return "Active Camera: [\(cat.displayBadge)] \(d.localizedName)"
        } ?? "Active Camera: None connected"

        let expText = "Smart Exposure: \(currentExposureCapabilities.statusDescription)"
        statusLabel.stringValue = "\(activeDeviceText)\n\(expText)"
    }

    @objc func settingsCameraChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        if let desc = item.representedObject as? WebcamDescriptor {
            switchCamera(to: desc, isExplicit: true)
        } else {
            selectAutomaticWebcam()
        }
        refreshCameraMenu()
        refreshSettingsCamera()
    }

    @objc func settingsSmartExposureChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let mode = item.representedObject as? SmartExposureMode else { return }
        smartExposurePreferences.saveMode(mode)
        refreshCameraMenu()
        refreshSettingsCamera()
        status("Smart Exposure set to \(mode.rawValue).")
    }

    func refreshSettingsLocation() {
        let pending = try? CollectionLocationPreferences().load().pending
        let suffix = pending.map { "\nPending after restart: \($0.destinationPath)" } ?? ""
        settingsLocationLabel?.stringValue = "Current collection: \(outputRoot.path)\(suffix)"
    }

    @objc func openCollectionInFinder() {
        NSWorkspace.shared.open(outputRoot)
    }

    @objc func chooseCollectionFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.prompt = "Choose Folder"
        if picker.runModal() == .OK, let url = picker.url {
            requestCollectionLocation(url)
        }
    }

    @objc func restoreDefaultCollection() {
        let destination = StorageConfiguration.defaultOutputRoot
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            } catch {
                showLocationError(error)
                return
            }
        }
        requestCollectionLocation(destination)
    }

    func showLocationError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    func requestCollectionLocation(_ url: URL) {
        do {
            guard ProcessInfo.processInfo.environment["BONDSCANNER_OUTPUT_ROOT"] == nil else {
                throw DatabaseError.restoreFailed("Location changes are unavailable while a development storage override is active.")
            }
            let destination = url.standardizedFileURL
            let preferences = CollectionLocationPreferences()
            var state = try preferences.load()
            let current = outputRoot.standardizedFileURL
            guard (state.activePath ?? StorageConfiguration.defaultOutputRoot.path) == current.path else {
                throw DatabaseError.restoreFailed("The saved location changed while the app was running. Restart before changing it.")
            }
            if destination == current {
                state.pending = nil
                try preferences.save(state)
                refreshSettingsLocation()
                return
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            let action: CollectionSwitchAction
            if names.contains("bonds.sqlite3") {
                _ = try CollectionValidator.validate(root: destination, backups: backupsRoot)
                let alert = NSAlert()
                alert.messageText = "Open this existing collection?"
                alert.informativeText = "The current collection will remain at \(current.path). Restart is required."
                alert.addButton(withTitle: "Open Existing Collection")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                action = .open
            } else {
                guard names.isEmpty else {
                    throw DatabaseError.restoreFailed("Choose an empty folder or a folder containing an existing Bond Scanner collection. No files were overwritten.")
                }
                let alert = NSAlert()
                alert.messageText = "Choose how to use this folder"
                alert.informativeText = "The current collection remains at \(current.path). Copying happens after you restart, including changes made before quitting."
                alert.addButton(withTitle: "Copy Existing Collection")
                alert.addButton(withTitle: "Start New Empty Collection")
                alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    action = .copy
                } else if response == .alertSecondButtonReturn {
                    let confirm = NSAlert()
                    confirm.messageText = "Start an empty collection?"
                    confirm.informativeText = "Your existing records and photographs will remain at \(current.path). They will not be moved."
                    confirm.addButton(withTitle: "Start Empty Collection")
                    confirm.addButton(withTitle: "Cancel")
                    guard confirm.runModal() == .alertFirstButtonReturn else { return }
                    action = .new
                } else {
                    return
                }
            }
            state.pending = PendingCollectionSwitch(sourcePath: current.path, destinationPath: destination.path, action: action)
            try preferences.save(state)
            refreshSettingsLocation()
            let alert = NSAlert()
            alert.messageText = "Restart Bond Scanner to change location"
            alert.informativeText = "The current collection remains in use until you quit."
            alert.runModal()
        } catch {
            showLocationError(error)
        }
    }

    func showStartupError(_ error: String) {
        let alert = NSAlert()
        alert.messageText = "Bond Scanner could not start"
        alert.informativeText = error
        alert.runModal()
        NSApp.terminate(nil)
    }

    func showCorruptionErrorWithRecoveryOption(detail: String) {
        let alert = NSAlert()
        alert.messageText = "Bond Scanner Database Corrupted"
        alert.informativeText = "The database file at \(databaseURL.path) failed integrity checks (\(detail)).\n\nWould you like to recover the database? The existing database and WAL/SHM files will be preserved in a timestamped archive before a clean replacement database is created."
        alert.addButton(withTitle: "Recover Database")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                let recovered = try DatabaseManager.recoverDatabase(at: databaseURL)
                DatabaseManager.setSharedInstance(recovered)
                records = []
                showRecoveryNotice()
            } catch {
                showStartupError("Database recovery failed: \(error.localizedDescription)")
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    func showRecoveryNotice() {
        let alert = NSAlert()
        alert.messageText = "Database Recovery Completed"
        alert.informativeText = "The corrupted database, WAL, and SHM files were safely archived in \(outputRoot.path).\nA fresh inventory has been initialized."
        alert.runModal()
    }
}
