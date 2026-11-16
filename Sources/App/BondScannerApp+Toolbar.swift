import AppKit
import Foundation

// MARK: - Toolbar

private extension NSToolbarItem.Identifier {
    static let scan = NSToolbarItem.Identifier("bondscanner.scan")
    static let auto = NSToolbarItem.Identifier("bondscanner.auto")
    static let fast = NSToolbarItem.Identifier("bondscanner.fast")
    static let rearm = NSToolbarItem.Identifier("bondscanner.rearm")
    static let review = NSToolbarItem.Identifier("bondscanner.review")
    static let importPhotos = NSToolbarItem.Identifier("bondscanner.import")
    static let exportCSV = NSToolbarItem.Identifier("bondscanner.export")
    static let undo = NSToolbarItem.Identifier("bondscanner.undo")
    static let more = NSToolbarItem.Identifier("bondscanner.more")
    static let drawer = NSToolbarItem.Identifier("bondscanner.drawer")
}

extension BondScannerApp: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.scan, .auto, .fast, .rearm, .flexibleSpace, .review, .importPhotos, .exportCSV, .undo, .more, .drawer]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
    {
        switch itemIdentifier {
        case .scan:
            let button = NSButton(title: "Scan", target: self, action: #selector(scanNow))
            button.image = symbolImage("camera.viewfinder", description: "Scan now")
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
            return wrap(button, id: itemIdentifier, label: "Scan now", tooltip: "Scan the bond in view now (Space)", action: #selector(scanNow))
        case .auto:
            let button = makeToggleButton(title: "Auto", symbol: "bolt.fill", isOn: automatic, action: #selector(toggleAuto))
            button.toolTip = "Automatically capture a bond when one is held steady in the guide"
            autoButton = button
            return wrap(button, id: itemIdentifier, label: "Auto", tooltip: button.toolTip ?? "", action: #selector(toggleAuto))
        case .fast:
            let button = makeToggleButton(title: "Fast", symbol: "hare.fill", isOn: fastScanEnabled, action: #selector(toggleFastScan))
            button.toolTip = "Fast Scan: quicker frame lock and re-arm"
            fastButton = button
            return wrap(button, id: itemIdentifier, label: "Fast", tooltip: button.toolTip ?? "", action: #selector(toggleFastScan))
        case .rearm:
            return makeIconItem(itemIdentifier, label: "Re-arm", symbol: "arrow.clockwise",
                                tooltip: "Re-arm automatic scanning", action: #selector(rearm))
        case .review:
            return makeIconItem(itemIdentifier, label: "Review", symbol: "checklist",
                                tooltip: "Review unresolved bonds", action: #selector(openReviewWorkflow))
        case .importPhotos:
            return makeIconItem(itemIdentifier, label: "Import", symbol: "square.and.arrow.down",
                                tooltip: "Import bond photos", action: #selector(importPhotos))
        case .exportCSV:
            return makeIconItem(itemIdentifier, label: "Export CSV", symbol: "square.and.arrow.up",
                                tooltip: "Export bonds to CSV", action: #selector(exportCSVAction))
        case .undo:
            return makeIconItem(itemIdentifier, label: "Undo", symbol: "arrow.uturn.backward",
                                tooltip: "Undo the last scan", action: #selector(undoLast))
        case .drawer:
            return makeIconItem(itemIdentifier, label: "Bonds", symbol: "sidebar.right",
                                tooltip: "Show or hide the bonds list", action: #selector(toggleDrawer))
        case .more:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            let menu = NSMenu()
            let folder = NSMenuItem(title: "Open Scans Folder", action: #selector(openFolder), keyEquivalent: "")
            folder.target = self
            folder.image = symbolImage("folder", description: "Open scans folder")
            let log = NSMenuItem(title: "Open Debug Log", action: #selector(openDebugLog), keyEquivalent: "")
            log.target = self
            log.image = symbolImage("doc.text", description: "Open debug log")
            menu.addItem(folder)
            menu.addItem(log)
            item.menu = menu
            item.showsIndicator = false
            item.image = symbolImage("ellipsis.circle", description: "More")
            item.label = "More"
            item.paletteLabel = "More"
            item.toolTip = "Open scans folder or debug log"
            return item
        default:
            return nil
        }
    }

    private func makeToggleButton(title: String, symbol: String, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = symbolImage(symbol, description: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .texturedRounded
        button.setButtonType(.pushOnPushOff)
        button.state = isOn ? .on : .off
        return button
    }

    private func wrap(_ button: NSButton, id: NSToolbarItem.Identifier, label: String, tooltip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        let menuItem = NSMenuItem(title: label, action: action, keyEquivalent: "")
        menuItem.target = self
        item.menuFormRepresentation = menuItem
        return item
    }

    private func makeIconItem(_ id: NSToolbarItem.Identifier, label: String, symbol: String, tooltip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.image = symbolImage(symbol, description: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}
