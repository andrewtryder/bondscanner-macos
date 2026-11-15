import AppKit

#if BONDSCANNER_OCR_HARNESS
    ocrHarnessMain()
#else
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = BondScannerApp()
    app.delegate = delegate
    app.run()
#endif
