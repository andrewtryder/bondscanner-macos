import AppKit

enum BondSortField: String, CaseIterable {
    case date = "Date"
    case serial = "Serial"
    case number = "Number"
    case issueDate = "Issue Date"
    case status = "Status"
}

struct BondDrawerRow {
    let number: Int
    let record: BondRecord

    var issueDateDisplay: String {
        if record.issueMonth.isEmpty && record.issueYear.isEmpty { return "—" }
        if record.issueMonth.isEmpty { return record.issueYear }
        if record.issueYear.isEmpty { return record.issueMonth }
        return "\(record.issueMonth)/\(record.issueYear)"
    }

    var issueDateSortKey: String {
        let year = record.issueYear.isEmpty ? "0000" : record.issueYear
        let month = record.issueMonth.isEmpty ? "00" : record.issueMonth
        return "\(year)-\(month)"
    }

    var denominationDisplay: String {
        record.denomination.isEmpty ? "—" : "$\(record.denomination)"
    }
}

func sortedAndFilteredBondRows(
    from records: [BondRecord],
    sortField: BondSortField,
    ascending: Bool,
    reviewOnly: Bool
) -> [BondDrawerRow] {
    var rows = records.enumerated().map { BondDrawerRow(number: $0.offset + 1, record: $0.element) }
    if reviewOnly {
        rows = rows.filter { $0.record.status != "OK" }
    }
    rows.sort { lhs, rhs in
        let cmp: ComparisonResult
        switch sortField {
        case .number:
            if lhs.number != rhs.number {
                cmp = lhs.number < rhs.number ? .orderedAscending : .orderedDescending
            } else {
                cmp = .orderedSame
            }
        case .serial:
            let ls = lhs.record.serial
            let rs = rhs.record.serial
            if ls.isEmpty != rs.isEmpty {
                // Keep blank/pending serials at the end regardless of direction.
                return !ls.isEmpty
            }
            cmp = ls.localizedStandardCompare(rs)
        case .date:
            cmp = lhs.record.capturedAt.compare(rhs.record.capturedAt)
        case .issueDate:
            let li = lhs.issueDateSortKey
            let ri = rhs.issueDateSortKey
            if (li == "0000-00") != (ri == "0000-00") {
                return li != "0000-00"
            }
            cmp = li.compare(ri)
        case .status:
            cmp = lhs.record.status.localizedCaseInsensitiveCompare(rhs.record.status)
        }

        if cmp == .orderedSame {
            return ascending ? lhs.number < rhs.number : lhs.number > rhs.number
        }
        return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
    }
    return rows
}

/// Collapsible right-side database drawer displaying scanned bonds with sorting and review filtering.
final class BondsDrawerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onCollapseRequested: (() -> Void)?
    var onOpenPhotoRequested: ((BondRecord) -> Void)?

    private var allRecords: [BondRecord] = []
    private var displayedRows: [BondDrawerRow] = []
    private var sortField: BondSortField = .date
    private var sortAscending = false
    private var reviewOnly = false

    private let titleLabel = NSTextField(labelWithString: "Database (0)")
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let directionButton = NSButton(title: "↓", target: nil, action: nil)
    private let filterControl = NSSegmentedControl(labels: ["All", "Review"], trackingMode: .selectOne, target: nil, action: nil)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private let isoParserWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let todayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    private enum ColumnID {
        static let number = NSUserInterfaceItemIdentifier("number")
        static let serial = NSUserInterfaceItemIdentifier("serial")
        static let issue = NSUserInterfaceItemIdentifier("issue")
        static let denom = NSUserInterfaceItemIdentifier("denom")
        static let status = NSUserInterfaceItemIdentifier("status")
        static let date = NSUserInterfaceItemIdentifier("date")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let collapseButton = NSButton(title: "Hide ›", target: self, action: #selector(collapseClicked))
        collapseButton.bezelStyle = .rounded
        collapseButton.controlSize = .small
        collapseButton.translatesAutoresizingMaskIntoConstraints = false

        let sortLabel = NSTextField(labelWithString: "Sort:")
        sortLabel.font = .systemFont(ofSize: 11.5)
        sortLabel.textColor = .secondaryLabelColor
        sortLabel.translatesAutoresizingMaskIntoConstraints = false

        for field in BondSortField.allCases {
            sortPopup.addItem(withTitle: field.rawValue)
        }
        sortPopup.selectItem(withTitle: sortField.rawValue)
        sortPopup.controlSize = .small
        sortPopup.target = self
        sortPopup.action = #selector(sortFieldChanged)
        sortPopup.translatesAutoresizingMaskIntoConstraints = false

        directionButton.bezelStyle = .rounded
        directionButton.controlSize = .small
        directionButton.target = self
        directionButton.action = #selector(directionToggled)
        directionButton.toolTip = "Toggle ascending / descending sort"
        directionButton.translatesAutoresizingMaskIntoConstraints = false

        filterControl.selectedSegment = 0
        filterControl.controlSize = .small
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.translatesAutoresizingMaskIntoConstraints = false

        let controlsRow = NSStackView(views: [sortLabel, sortPopup, directionButton, filterControl])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 6
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        configureTableColumns()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(labelWithString: "Double-click a row to open its saved bond photo.")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(collapseButton)
        addSubview(controlsRow)
        addSubview(scrollView)
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),

            collapseButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            collapseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            controlsRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            controlsRow.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
            controlsRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: controlsRow.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -6),

            hintLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        syncSortDescriptors()
    }

    private func configureTableColumns() {
        let specs: [(NSUserInterfaceItemIdentifier, String, CGFloat, String)] = [
            (ColumnID.number, "#", 42, "number"),
            (ColumnID.serial, "Serial", 116, "serial"),
            (ColumnID.issue, "Issue", 62, "issueDate"),
            (ColumnID.denom, "Denom", 50, "denom"),
            (ColumnID.status, "Status", 72, "status"),
            (ColumnID.date, "Scanned", 94, "date")
        ]
        for (id, title, width, sortKey) in specs {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = 38
            col.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true)
            tableView.addTableColumn(col)
        }
    }

    func updateRecords(_ records: [BondRecord]) {
        self.allRecords = records
        refreshDisplayedRows()
    }

    private func refreshDisplayedRows() {
        displayedRows = sortedAndFilteredBondRows(
            from: allRecords,
            sortField: sortField,
            ascending: sortAscending,
            reviewOnly: reviewOnly
        )
        if reviewOnly {
            titleLabel.stringValue = "Review (\(displayedRows.count) of \(allRecords.count))"
        } else {
            titleLabel.stringValue = "Database (\(allRecords.count))"
        }
        tableView.reloadData()
    }

    private func syncSortDescriptors() {
        directionButton.title = sortAscending ? "↑" : "↓"
        sortPopup.selectItem(withTitle: sortField.rawValue)
        let key: String
        switch sortField {
        case .number: key = "number"
        case .serial: key = "serial"
        case .issueDate: key = "issueDate"
        case .status: key = "status"
        case .date: key = "date"
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: sortAscending)]
    }

    @objc private func collapseClicked() {
        onCollapseRequested?()
    }

    @objc private func sortFieldChanged() {
        guard let title = sortPopup.selectedItem?.title, let selected = BondSortField(rawValue: title) else { return }
        sortField = selected
        // Default to descending for Date/Number, ascending for Serial/Issue/Status when switched via dropdown.
        sortAscending = (selected == .serial || selected == .issueDate || selected == .status)
        syncSortDescriptors()
        refreshDisplayedRows()
    }

    @objc private func directionToggled() {
        sortAscending.toggle()
        syncSortDescriptors()
        refreshDisplayedRows()
    }

    @objc private func filterChanged() {
        reviewOnly = (filterControl.selectedSegment == 1)
        refreshDisplayedRows()
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < displayedRows.count else { return }
        onOpenPhotoRequested?(displayedRows[row].record)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        switch key {
        case "number": sortField = .number
        case "serial": sortField = .serial
        case "issueDate": sortField = .issueDate
        case "status": sortField = .status
        case "date": sortField = .date
        default: sortField = .date
        }
        sortAscending = descriptor.ascending
        directionButton.title = sortAscending ? "↑" : "↓"
        sortPopup.selectItem(withTitle: sortField.rawValue)
        refreshDisplayedRows()
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier, row >= 0 && row < displayedRows.count else { return nil }
        let entry = displayedRows[row]
        let cellId = NSUserInterfaceItemIdentifier("cell_\(colId.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        guard let tf = cell.textField else { return cell }
        tf.textColor = .labelColor
        tf.font = .systemFont(ofSize: 11.5)

        switch colId {
        case ColumnID.number:
            tf.stringValue = "\(entry.number)"
            tf.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            tf.textColor = .secondaryLabelColor
        case ColumnID.serial:
            tf.stringValue = entry.record.serial.isEmpty ? "(pending)" : entry.record.serial
            tf.font = .monospacedSystemFont(ofSize: 11.5, weight: entry.record.serial.isEmpty ? .regular : .medium)
            if entry.record.serial.isEmpty { tf.textColor = .secondaryLabelColor }
        case ColumnID.issue:
            tf.stringValue = entry.issueDateDisplay
            tf.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        case ColumnID.denom:
            tf.stringValue = entry.denominationDisplay
            tf.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        case ColumnID.status:
            tf.stringValue = entry.record.status
            tf.font = .systemFont(ofSize: 11, weight: .semibold)
            switch entry.record.status {
            case "OK": tf.textColor = .systemGreen
            case "PROCESSING": tf.textColor = .systemBlue
            case "REVIEW", "DUPLICATE": tf.textColor = .systemOrange
            default: tf.textColor = .secondaryLabelColor
            }
        case ColumnID.date:
            tf.stringValue = formatCapturedTimestamp(entry.record.capturedAt)
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.textColor = .secondaryLabelColor
        default:
            tf.stringValue = ""
        }
        return cell
    }

    private func formatCapturedTimestamp(_ iso: String) -> String {
        guard let date = isoParserWithFractional.date(from: iso) ?? isoParser.date(from: iso) else {
            return String(iso.prefix(10))
        }
        if Calendar.current.isDateInToday(date) {
            return todayTimeFormatter.string(from: date)
        }
        return shortDateFormatter.string(from: date)
    }
}
