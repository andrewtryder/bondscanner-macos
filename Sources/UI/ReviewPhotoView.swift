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
    private let loupeBtn = NSButton(title: "🔍 Loupe", target: nil, action: nil)
    private let loupeView = LoupeView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
    private(set) var loupeEnabled = true

    private var originalImage: NSImage?
    private var processedImage: NSImage?
    private(set) var showingProcessed = false
    private(set) var rotationQuarterTurns: Int = 0 // 0, 1, 2, 3 -> 0, 90, 180, 270 degrees

    var currentZoomScale: CGFloat {
        innerImageView.currentZoomScale
    }

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
        for btn in [zoomOutBtn, zoomInBtn, zoomFitBtn, zoomActualBtn, loupeBtn, rotateBtn, togglePhotoBtn] {
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
        loupeBtn.action = #selector(toggleLoupeClicked)
        loupeBtn.toolTip = "Toggle Hovering Magnifying Loupe"
        loupeBtn.state = .on
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
        toolbar.addArrangedSubview(loupeBtn)
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
        addSubview(loupeView)
        loupeView.isHidden = true

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

        innerImageView.onMouseHover = { [weak self] viewPoint, imgPoint in
            guard let self = self else { return }
            guard self.loupeEnabled, let img = self.activeImage, let imgPt = imgPoint, let vPt = viewPoint else {
                self.loupeView.isHidden = true
                return
            }
            let windowPoint = self.innerImageView.convert(vPt, to: nil)
            let photoPoint = self.convert(windowPoint, from: nil)

            let loupeDiameter: CGFloat = 160
            let loupeRadius = loupeDiameter / 2.0

            var centerX = photoPoint.x
            // Position above cursor so user's cursor doesn't obscure the magnified region
            var centerY = photoPoint.y + 105
            if centerY + loupeRadius > self.bounds.height - 35 {
                // If near the top toolbar, flip below the cursor
                centerY = photoPoint.y - 105
            }
            // Clamp within view bounds
            centerX = max(loupeRadius + 10, min(centerX, self.bounds.width - loupeRadius - 10))
            centerY = max(loupeRadius + 10, min(centerY, self.bounds.height - loupeRadius - 10))

            self.loupeView.frame = NSRect(
                x: centerX - loupeRadius,
                y: centerY - loupeRadius,
                width: loupeDiameter,
                height: loupeDiameter
            )
            self.loupeView.sourceImage = img
            self.loupeView.quarterTurns = self.rotationQuarterTurns
            self.loupeView.focusImagePoint = imgPt
            self.loupeView.isHidden = false
        }
    }

    func setImages(original: NSImage?, processed: NSImage?) {
        self.originalImage = original
        self.processedImage = processed
        self.showingProcessed = false
        self.rotationQuarterTurns = 0
        self.loupeView.isHidden = true

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
        loupeView.isHidden = true
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

    @objc private func toggleLoupeClicked() {
        loupeEnabled.toggle()
        loupeBtn.state = loupeEnabled ? .on : .off
        if !loupeEnabled {
            loupeView.isHidden = true
        }
    }

    @objc private func rotateClicked() {
        rotateClockwise()
    }

    func togglePhoto() {
        showingProcessed.toggle()
        loupeView.isHidden = true
        togglePhotoBtn.title = showingProcessed ? "Photo: Processed" : "Photo: Original"
        displayActiveImage(fitInitially: false)
    }

    @objc private func togglePhotoClicked() {
        togglePhoto()
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

// MARK: - Magnifying Loupe Overlay

private final class LoupeView: NSView {
    var sourceImage: NSImage?
    var quarterTurns: Int = 0
    var focusImagePoint: NSPoint? {
        didSet { needsDisplay = true }
    }

    var magnification: CGFloat = 2.8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = frameRect.width / 2.0
        layer?.masksToBounds = true
        layer?.borderWidth = 3.0
        layer?.borderColor = NSColor.white.cgColor
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2.0
        layer?.masksToBounds = true
        layer?.borderWidth = 3.0
        layer?.borderColor = NSColor.white.cgColor
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Transparent to clicks and drags so viewer remains fully interactive
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = sourceImage, let pt = focusImagePoint else { return }

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()

        let path = NSBezierPath(ovalIn: bounds)
        path.addClip()

        NSColor.black.setFill()
        path.fill()

        NSGraphicsContext.current?.imageInterpolation = .high

        let centerX = bounds.width / 2.0
        let centerY = bounds.height / 2.0
        context?.translateBy(x: centerX, y: centerY)

        // Rotate by quarter turns to match photo viewer orientation
        let angle = -CGFloat(quarterTurns) * (.pi / 2.0)
        context?.rotate(by: angle)

        let drawW = img.size.width * magnification
        let drawH = img.size.height * magnification
        let originX = -pt.x * magnification
        let originY = -pt.y * magnification

        let destRect = NSRect(x: originX, y: originY, width: drawW, height: drawH)
        img.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        context?.restoreGState()

        // Subtle center reticle (12pt crosshair)
        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        let reticle = NSBezierPath()
        reticle.lineWidth = 1.0
        reticle.move(to: NSPoint(x: centerX - 8, y: centerY))
        reticle.line(to: NSPoint(x: centerX - 2, y: centerY))
        reticle.move(to: NSPoint(x: centerX + 2, y: centerY))
        reticle.line(to: NSPoint(x: centerX + 8, y: centerY))
        reticle.move(to: NSPoint(x: centerX, y: centerY - 8))
        reticle.line(to: NSPoint(x: centerX, y: centerY - 2))
        reticle.move(to: NSPoint(x: centerX, y: centerY + 2))
        reticle.line(to: NSPoint(x: centerX, y: centerY + 8))
        reticle.stroke()

        // Inner circular border ring for optical lens effect
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let innerRing = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        innerRing.lineWidth = 2.0
        innerRing.stroke()
    }
}

// MARK: - Zoomable & Rotatable Image View

private final class ZoomableImageView: NSView {
    var onZoomChanged: ((CGFloat) -> Void)?
    var onMouseHover: ((NSPoint?, NSPoint?) -> Void)?
    private(set) var isFitMode = true

    private var image: NSImage?
    private var quarterTurns: Int = 0
    private var zoomScale: CGFloat = 1.0
    private var trackingArea: NSTrackingArea?

    var currentZoomScale: CGFloat {
        zoomScale
    }

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    func imagePoint(from viewPoint: NSPoint) -> NSPoint? {
        guard let img = image else { return nil }
        let isRotated = (quarterTurns % 2 != 0)
        let naturalW = isRotated ? img.size.height : img.size.width
        let naturalH = isRotated ? img.size.width : img.size.height
        let targetW = naturalW * zoomScale
        let targetH = naturalH * zoomScale
        let drawX = (bounds.width - targetW) / 2.0
        let drawY = (bounds.height - targetH) / 2.0

        let imageRect = NSRect(x: drawX, y: drawY, width: targetW, height: targetH)
        guard imageRect.contains(viewPoint) else { return nil }

        let centerX = drawX + targetW / 2.0
        let centerY = drawY + targetH / 2.0

        let relX = (viewPoint.x - centerX) / zoomScale
        let relY = (viewPoint.y - centerY) / zoomScale

        let angle = CGFloat(quarterTurns) * (.pi / 2.0)
        let cosA = cos(angle)
        let sinA = sin(angle)
        let localX = relX * cosA - relY * sinA
        let localY = relX * sinA + relY * cosA

        let imgX = localX + img.size.width / 2.0
        let imgY = localY + img.size.height / 2.0

        guard imgX >= 0, imgX <= img.size.width, imgY >= 0, imgY <= img.size.height else { return nil }
        return NSPoint(x: imgX, y: imgY)
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragStartLocation == nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imgPt = imagePoint(from: viewPoint)
        onMouseHover?(viewPoint, imgPt)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseHover?(nil, nil)
    }

    // MARK: - Pinch & Scroll Wheel Zoom

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        multiplyZoom(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = event.scrollingDeltaY
            let factor = delta > 0 ? 1.08 : 0.92
            multiplyZoom(by: factor)
        } else {
            super.scrollWheel(with: event)
        }
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
        onMouseHover?(nil, nil)
        dragStartLocation = event.locationInWindow
        dragStartOrigin = enclosingScrollView?.contentView.bounds.origin
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseHover?(nil, nil)
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
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imgPt = imagePoint(from: viewPoint)
        onMouseHover?(viewPoint, imgPt)
    }
}
