import AppKit

/// Interactive bond photograph viewer with fit-to-window, smooth zoom, pan,
/// non-destructive rotation, and original vs. processed photo comparison.
final class ReviewPhotoView: NSView {
    private let scrollView = NSScrollView()
    private let innerImageView = ZoomableImageView()

    private let toolbar = NSStackView()
    private let zoomOutBtn = NSButton(title: "−", target: nil, action: nil)
    private let zoomInBtn = NSButton(title: "+", target: nil, action: nil)
    private let zoomFitBtn = NSButton(title: "Fit", target: nil, action: nil)
    private let zoomActualBtn = NSButton(title: "100%", target: nil, action: nil)
    private let rotateBtn = NSButton(title: "Rotate ⟳", target: nil, action: nil)
    private let togglePhotoBtn = NSButton(title: "Photo: Original", target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "100%")

    private var originalImage: NSImage?
    private var processedImage: NSImage?
    private var showingProcessed = false
    private var rotationQuarterTurns: Int = 0 // 0, 1, 2, 3 -> 0, 90, 180, 270 degrees

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

        // Configure Toolbar Buttons
        for btn in [zoomOutBtn, zoomInBtn, zoomFitBtn, zoomActualBtn, rotateBtn, togglePhotoBtn] {
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.target = self
        }

        zoomOutBtn.action = #selector(zoomOutClicked)
        zoomOutBtn.toolTip = "Zoom Out (⌘-)"
        zoomInBtn.action = #selector(zoomInClicked)
        zoomInBtn.toolTip = "Zoom In (⌘=)"
        zoomFitBtn.action = #selector(zoomFitClicked)
        zoomFitBtn.toolTip = "Zoom to Fit (⌘0)"
        zoomActualBtn.action = #selector(zoomActualClicked)
        zoomActualBtn.toolTip = "Actual Size 100%"
        rotateBtn.action = #selector(rotateClicked)
        rotateBtn.toolTip = "Rotate View 90° Clockwise (⌘R)"
        togglePhotoBtn.action = #selector(togglePhotoClicked)
        togglePhotoBtn.toolTip = "Toggle between Original and Rectified/Processed photo"

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor

        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addArrangedSubview(zoomOutBtn)
        toolbar.addArrangedSubview(zoomFitBtn)
        toolbar.addArrangedSubview(zoomActualBtn)
        toolbar.addArrangedSubview(zoomInBtn)
        toolbar.addArrangedSubview(zoomLabel)
        toolbar.addArrangedSubview(NSView()) // Spacer
        toolbar.addArrangedSubview(rotateBtn)
        toolbar.addArrangedSubview(togglePhotoBtn)

        // Configure Scroll View
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = innerImageView
        scrollView.backgroundColor = NSColor.black

        addSubview(toolbar)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        innerImageView.onZoomChanged = { [weak self] scale in
            self?.updateZoomLabel(scale)
        }
    }

    func setImages(original: NSImage?, processed: NSImage?) {
        self.originalImage = original
        self.processedImage = processed
        self.showingProcessed = false
        self.rotationQuarterTurns = 0

        togglePhotoBtn.isEnabled = (original != nil && processed != nil)
        togglePhotoBtn.title = "Photo: Original"

        displayActiveImage(fitInitially: true)
    }

    private var activeImage: NSImage? {
        showingProcessed ? (processedImage ?? originalImage) : (originalImage ?? processedImage)
    }

    private func displayActiveImage(fitInitially: Bool = false) {
        innerImageView.setImage(activeImage, quarterTurns: rotationQuarterTurns)
        if fitInitially {
            zoomToFit()
        }
    }

    func zoomIn() {
        innerImageView.multiplyZoom(by: 1.25)
    }

    func zoomOut() {
        innerImageView.multiplyZoom(by: 0.80)
    }

    func zoomToFit() {
        guard let img = activeImage else { return }
        let scrollSize = scrollView.contentSize
        guard scrollSize.width > 20, scrollSize.height > 20 else {
            innerImageView.setZoom(1.0)
            return
        }

        let imgSize = img.size
        let isRotated = (rotationQuarterTurns % 2 != 0)
        let effectiveW = isRotated ? imgSize.height : imgSize.width
        let effectiveH = isRotated ? imgSize.width : imgSize.height

        guard effectiveW > 0, effectiveH > 0 else { return }
        let scaleW = (scrollSize.width - 20) / effectiveW
        let scaleH = (scrollSize.height - 20) / effectiveH
        let fitScale = max(0.05, min(scaleW, scaleH))
        innerImageView.setZoom(fitScale)
    }

    func zoomToActual() {
        innerImageView.setZoom(1.0)
    }

    func rotateClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
        innerImageView.setImage(activeImage, quarterTurns: rotationQuarterTurns)
        zoomToFit()
    }

    @objc private func zoomInClicked() {
        zoomIn()
    }

    @objc private func zoomOutClicked() {
        zoomOut()
    }

    @objc private func zoomFitClicked() {
        zoomToFit()
    }

    @objc private func zoomActualClicked() {
        zoomToActual()
    }

    @objc private func rotateClicked() {
        rotateClockwise()
    }

    @objc private func togglePhotoClicked() {
        showingProcessed.toggle()
        togglePhotoBtn.title = showingProcessed ? "Photo: Processed" : "Photo: Original"
        displayActiveImage(fitInitially: false)
    }

    private func updateZoomLabel(_ scale: CGFloat) {
        let percent = Int(round(scale * 100))
        zoomLabel.stringValue = "\(percent)%"
    }

    override func layout() {
        super.layout()
        if innerImageView.isFitMode {
            zoomToFit()
        }
    }
}

// MARK: - Zoomable & Rotatable Image View

private final class ZoomableImageView: NSView {
    var onZoomChanged: ((CGFloat) -> Void)?
    private(set) var isFitMode = true

    private var image: NSImage?
    private var quarterTurns: Int = 0
    private var zoomScale: CGFloat = 1.0

    private var dragStartLocation: NSPoint?
    private var dragStartOrigin: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    func setImage(_ img: NSImage?, quarterTurns: Int) {
        self.image = img
        self.quarterTurns = quarterTurns
        updateFrame()
        needsDisplay = true
    }

    func setZoom(_ scale: CGFloat) {
        self.zoomScale = max(0.05, min(scale, 10.0))
        self.isFitMode = false
        updateFrame()
        onZoomChanged?(self.zoomScale)
        needsDisplay = true
    }

    func multiplyZoom(by factor: CGFloat) {
        setZoom(self.zoomScale * factor)
    }

    private func updateFrame() {
        guard let img = image else {
            frame = .zero
            return
        }
        let isRotated = (quarterTurns % 2 != 0)
        let naturalW = isRotated ? img.size.height : img.size.width
        let naturalH = isRotated ? img.size.width : img.size.height

        let w = max(10, naturalW * zoomScale)
        let h = max(10, naturalH * zoomScale)

        // Center within visible clip view if smaller
        let clipSize = enclosingScrollView?.contentSize ?? .zero
        let finalW = max(w, clipSize.width)
        let finalH = max(h, clipSize.height)

        frame = NSRect(x: 0, y: 0, width: finalW, height: finalH)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }

        NSGraphicsContext.current?.imageInterpolation = .high

        let isRotated = (quarterTurns % 2 != 0)
        let naturalW = isRotated ? img.size.height : img.size.width
        let naturalH = isRotated ? img.size.width : img.size.height
        let targetW = naturalW * zoomScale
        let targetH = naturalH * zoomScale

        let drawX = (bounds.width - targetW) / 2.0
        let drawY = (bounds.height - targetH) / 2.0

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()

        // Translate to center of drawing rect
        let centerX = drawX + targetW / 2.0
        let centerY = drawY + targetH / 2.0
        context?.translateBy(x: centerX, y: centerY)

        // Rotate by quarter turns
        let angle = -CGFloat(quarterTurns) * (.pi / 2.0)
        context?.rotate(by: angle)

        // Draw image centered
        let destRect = NSRect(
            x: -img.size.width * zoomScale / 2.0,
            y: -img.size.height * zoomScale / 2.0,
            width: img.size.width * zoomScale,
            height: img.size.height * zoomScale
        )
        img.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        context?.restoreGState()
    }

    // MARK: - Drag to Pan

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStartLocation = event.locationInWindow
        dragStartOrigin = enclosingScrollView?.contentView.bounds.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLoc = dragStartLocation,
              let startOrigin = dragStartOrigin,
              let clipView = enclosingScrollView?.contentView else { return }

        let currentLoc = event.locationInWindow
        let deltaX = currentLoc.x - startLoc.x
        let deltaY = currentLoc.y - startLoc.y

        var newOrigin = NSPoint(x: startOrigin.x - deltaX, y: startOrigin.y - deltaY)
        let maxOriginX = max(0, bounds.width - clipView.bounds.width)
        let maxOriginY = max(0, bounds.height - clipView.bounds.height)

        newOrigin.x = max(0, min(newOrigin.x, maxOriginX))
        newOrigin.y = max(0, min(newOrigin.y, maxOriginY))

        clipView.bounds.origin = newOrigin
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
        dragStartOrigin = nil
    }
}
