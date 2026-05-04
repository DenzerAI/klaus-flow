import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox

private let nxDeviceLCmdKeyMask: UInt = 0x00000008
private let nxDeviceRCmdKeyMask: UInt = 0x00000010

private enum OutputMode: Int {
    case paste = 0
    case pasteSend = 1

    static let defaultsKey = "KlausFlowOutputMode"

    var title: String {
        switch self {
        case .paste:
            return "Einfügen"
        case .pasteSend:
            return "Einfügen + Senden"
        }
    }
}

private enum PillState {
    case hidden
    case recording
    case processing
    case success
    case failure

    var symbol: String {
        switch self {
        case .hidden:
            return " "
        case .recording:
            return "●"
        case .processing:
            return "…"
        case .success:
            return "✓"
        case .failure:
            return "✕"
        }
    }

    var accent: NSColor {
        switch self {
        case .hidden:
            return NSColor.white.withAlphaComponent(0.0)
        case .recording:
            return NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.42, alpha: 1.0)
        case .processing:
            return NSColor(calibratedRed: 0.92, green: 0.82, blue: 0.48, alpha: 1.0)
        case .success:
            return NSColor.white.withAlphaComponent(0.98)
        case .failure:
            return NSColor.white.withAlphaComponent(0.98)
        }
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FlowPillController: NSWindowController {
    private let symbolLabel = NSTextField(labelWithString: " ")
    private let blurView = NSVisualEffectView()
    private let logoView = NSImageView()
    private let ambientGlowLayer = CAGradientLayer()
    private let topHighlightLayer = CAGradientLayer()
    private let bottomShadeLayer = CAGradientLayer()
    private let waveContainer = CALayer()
    private let dotsContainer = CALayer()
    private var recordingBars: [CALayer] = []
    private var dotLayers: [CALayer] = []
    private var waveSamples: [CGFloat] = []
    private var hideWorkItem: DispatchWorkItem?
    private var processingDotsTimer: Timer?
    private var processingDotsStep = 0
    private var recordingPhase: CGFloat = 0.0
    private let processingPulseKey = "pill.processingPulse"
    private let symbolPopKey = "pill.symbolPop"
    private var recordingLevel: CGFloat = 0.0

    override init(window: NSWindow?) {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 110, height: 46),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        super.init(window: panel)
        setupUI(panel)
        hideImmediately()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(_ panel: NSPanel) {
        blurView.frame = panel.contentView?.bounds ?? .zero
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 23
        blurView.layer?.cornerCurve = .continuous
        blurView.layer?.masksToBounds = false
        blurView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.003).cgColor
        blurView.layer?.borderWidth = 0
        blurView.layer?.shadowColor = NSColor.black.cgColor
        blurView.layer?.shadowOpacity = 0.045
        blurView.layer?.shadowRadius = 20
        blurView.layer?.shadowOffset = CGSize(width: 0, height: -6)

        let maskLayer = CAShapeLayer()
        let maskRect = blurView.bounds
        let maskPath = NSBezierPath(roundedRect: maskRect, xRadius: 23, yRadius: 23)
        maskLayer.path = maskPath.cgPath
        maskLayer.fillColor = NSColor.white.cgColor
        blurView.layer?.mask = maskLayer
        blurView.layer?.allowsEdgeAntialiasing = true
        panel.contentView = blurView

        if let rootLayer = blurView.layer {
            ambientGlowLayer.type = .radial
            ambientGlowLayer.colors = [
                NSColor.white.withAlphaComponent(0.13).cgColor,
                NSColor.white.withAlphaComponent(0.045).cgColor,
                NSColor.clear.cgColor
            ]
            ambientGlowLayer.startPoint = CGPoint(x: 0.32, y: 0.1)
            ambientGlowLayer.endPoint = CGPoint(x: 0.76, y: 0.92)
            ambientGlowLayer.opacity = 0.95
            rootLayer.addSublayer(ambientGlowLayer)

            topHighlightLayer.colors = [
                NSColor.white.withAlphaComponent(0.12).cgColor,
                NSColor.white.withAlphaComponent(0.03).cgColor,
                NSColor.clear.cgColor
            ]
            topHighlightLayer.locations = [0.0, 0.38, 1.0]
            topHighlightLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
            topHighlightLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
            topHighlightLayer.opacity = 0.9
            rootLayer.addSublayer(topHighlightLayer)

            bottomShadeLayer.colors = [
                NSColor.clear.cgColor,
                NSColor.black.withAlphaComponent(0.04).cgColor,
                NSColor.black.withAlphaComponent(0.08).cgColor
            ]
            bottomShadeLayer.locations = [0.0, 0.72, 1.0]
            bottomShadeLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
            bottomShadeLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
            bottomShadeLayer.opacity = 0.7
            rootLayer.addSublayer(bottomShadeLayer)

            waveContainer.opacity = 0.0
            rootLayer.addSublayer(waveContainer)
            for _ in 0..<17 {
                let bar = CALayer()
                bar.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
                bar.cornerRadius = 0.75
                bar.opacity = 0.16
                waveContainer.addSublayer(bar)
                recordingBars.append(bar)
            }

            dotsContainer.opacity = 0.0
            rootLayer.addSublayer(dotsContainer)
            for _ in 0..<3 {
                let dot = CALayer()
                dot.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
                dot.cornerRadius = 3.0
                dot.opacity = 0.28
                dotsContainer.addSublayer(dot)
                dotLayers.append(dot)
            }
        }

        logoView.image = loadLogoImage()
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.contentTintColor = NSColor.white.withAlphaComponent(0.98)
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.isHidden = true
        logoView.wantsLayer = true
        blurView.addSubview(logoView)

        symbolLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        symbolLabel.textColor = .white
        symbolLabel.alignment = .center
        symbolLabel.translatesAutoresizingMaskIntoConstraints = false
        symbolLabel.isHidden = true
        symbolLabel.wantsLayer = true
        blurView.addSubview(symbolLabel)

        NSLayoutConstraint.activate([
            logoView.centerXAnchor.constraint(equalTo: blurView.centerXAnchor),
            logoView.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 36),
            logoView.heightAnchor.constraint(equalToConstant: 20),
            symbolLabel.centerXAnchor.constraint(equalTo: blurView.centerXAnchor),
            symbolLabel.centerYAnchor.constraint(equalTo: blurView.centerYAnchor, constant: -0.5)
        ])
        layoutDynamicLayers()
    }

    func show(state: PillState, mode: OutputMode, autoHideAfter delay: TimeInterval? = nil) {
        DispatchQueue.main.async {
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
            self.applyState(state)
            self.positionPanel()
            self.window?.alphaValue = 0.0
            self.window?.orderFrontRegardless()
            self.animateIn()

            if let delay {
                let item = DispatchWorkItem { [weak self] in
                    self?.hideImmediately()
                }
                self.hideWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }
    }

    func hideImmediately() {
        DispatchQueue.main.async {
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
            guard let window = self.window else { return }
            self.stopAnimations()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 0.0
            } completionHandler: {
                window.orderOut(nil)
            }
        }
    }

    private func positionPanel() {
        guard let window else { return }
        let screen = NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - (window.frame.width / 2)
        let y = visible.maxY - 10
        window.setFrameTopLeftPoint(NSPoint(x: x, y: y))
    }

    private func animateIn() {
        guard let window, let layer = blurView.layer else { return }
        window.alphaValue = 0.0
        layer.removeAllAnimations()
        layer.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.95
        animation.toValue = 1.0
        animation.duration = 0.26
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "pill.scale")
        layer.transform = CATransform3DIdentity
    }

    private func loadLogoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "klaus-flow-logo", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        return nil
    }

    private func layoutDynamicLayers() {
        guard let rootLayer = blurView.layer else { return }
        if let mask = rootLayer.mask as? CAShapeLayer {
            let maskPath = NSBezierPath(roundedRect: rootLayer.bounds, xRadius: 23, yRadius: 23)
            mask.path = maskPath.cgPath
        }
        ambientGlowLayer.frame = rootLayer.bounds.insetBy(dx: -14, dy: -12)
        topHighlightLayer.frame = rootLayer.bounds.insetBy(dx: -2, dy: -2)
        bottomShadeLayer.frame = rootLayer.bounds.insetBy(dx: -2, dy: -2)
        waveContainer.frame = rootLayer.bounds
        dotsContainer.frame = rootLayer.bounds

        let targetSamples = recordingBars.count
        if waveSamples.count != targetSamples {
            waveSamples = Array(repeating: 0.0, count: targetSamples)
            redrawWaveform()
        }

        let barWidth: CGFloat = 1.5
        let spacing: CGFloat = 2.0
        let totalWidth = (CGFloat(recordingBars.count) * barWidth) + (CGFloat(max(0, recordingBars.count - 1)) * spacing)
        let startX = floor((rootLayer.bounds.width - totalWidth) / 2.0)
        let centerY = rootLayer.bounds.midY
        for (index, bar) in recordingBars.enumerated() {
            let x = startX + (CGFloat(index) * (barWidth + spacing))
            bar.frame = CGRect(x: x, y: centerY - 0.4, width: barWidth, height: 0.8)
            bar.cornerRadius = barWidth / 2
        }

        let dotSize: CGFloat = 6.0
        let dotSpacing: CGFloat = 8.0
        let dotTotal = (CGFloat(dotLayers.count) * dotSize) + (CGFloat(max(0, dotLayers.count - 1)) * dotSpacing)
        let dotStartX = floor((rootLayer.bounds.width - dotTotal) / 2.0)
        for (index, dot) in dotLayers.enumerated() {
            let x = dotStartX + (CGFloat(index) * (dotSize + dotSpacing))
            dot.frame = CGRect(x: x, y: centerY - (dotSize / 2), width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
        }
    }

    private func applyState(_ state: PillState) {
        guard let layer = blurView.layer else { return }
        stopAnimations()
        layoutDynamicLayers()
        logoView.isHidden = true
        symbolLabel.isHidden = true
        waveContainer.opacity = 0.0
        dotsContainer.opacity = 0.0
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.004).cgColor
        ambientGlowLayer.opacity = 0.9
        topHighlightLayer.opacity = 0.82
        bottomShadeLayer.opacity = 0.62

        switch state {
        case .hidden:
            break
        case .recording:
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.006).cgColor
            ambientGlowLayer.opacity = 0.96
            topHighlightLayer.opacity = 0.86
            bottomShadeLayer.opacity = 0.58
            waveContainer.opacity = 1.0
            redrawWaveform()
        case .processing:
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.006).cgColor
            ambientGlowLayer.opacity = 1.0
            topHighlightLayer.opacity = 0.9
            bottomShadeLayer.opacity = 0.54
            dotsContainer.opacity = 1.0
            startProcessingAnimation()
        case .success, .failure:
            symbolLabel.isHidden = false
            symbolLabel.stringValue = state.symbol
            symbolLabel.textColor = state.accent
            startSymbolAnimation()
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.008).cgColor
            ambientGlowLayer.opacity = 0.88
            topHighlightLayer.opacity = 0.72
            bottomShadeLayer.opacity = 0.5
        }
    }

    private func stopAnimations() {
        processingDotsTimer?.invalidate()
        processingDotsTimer = nil
        processingDotsStep = 0
        blurView.layer?.removeAnimation(forKey: processingPulseKey)
        blurView.layer?.removeAnimation(forKey: symbolPopKey)
        blurView.layer?.removeAnimation(forKey: "pill.processingShimmer")
        blurView.layer?.removeAnimation(forKey: "pill.flash")
        logoView.layer?.removeAllAnimations()
        symbolLabel.layer?.removeAllAnimations()
        let centerY = waveContainer.bounds.midY
        for bar in recordingBars {
            let x = bar.frame.origin.x
            let width = bar.bounds.width > 0 ? bar.bounds.width : 1.5
            bar.frame = CGRect(x: x, y: centerY - 0.4, width: width, height: 0.8)
            bar.opacity = 0.08
        }
        for dot in dotLayers {
            dot.transform = CATransform3DIdentity
            dot.opacity = 0.28
        }
    }

    func resetRecordingWave() {
        DispatchQueue.main.async {
            self.waveSamples = Array(repeating: 0.0, count: self.recordingBars.count)
            self.recordingLevel = 0.0
            self.recordingPhase = 0.0
            self.redrawWaveform()
        }
    }

    func updateRecordingLevel(_ level: CGFloat) {
        DispatchQueue.main.async {
            self.recordingLevel = max(0.0, min(1.0, level))
            guard self.waveContainer.opacity > 0.0 else { return }
            if self.waveSamples.isEmpty {
                self.waveSamples = Array(repeating: 0.0, count: self.recordingBars.count)
            }
            let gated = max(0.0, (self.recordingLevel - 0.08) / 0.92)
            let sample = gated <= 0.0 ? 0.0 : pow(gated, 1.02)
            self.recordingPhase += 0.18 + (sample * 0.34)

            let count = max(1, self.recordingBars.count - 1)
            var nextSamples: [CGFloat] = []
            nextSamples.reserveCapacity(self.recordingBars.count)

            for index in self.recordingBars.indices {
                let position = CGFloat(index) / CGFloat(count)
                let centeredDistance = abs(position - 0.5) * 2.0
                let envelope = pow(max(0.0, 1.0 - centeredDistance), 0.72)
                let traveling = (sin(self.recordingPhase + (position * 8.0)) * 0.5) + 0.5
                let secondary = (sin((self.recordingPhase * 1.7) - (position * 11.0)) * 0.5) + 0.5
                let modulation = (traveling * 0.62) + (secondary * 0.38)
                let target = sample <= 0.001
                    ? 0.0
                    : min(1.0, (sample * envelope * (0.42 + (0.92 * modulation))) + (sample * envelope * 0.08))
                let current = index < self.waveSamples.count ? self.waveSamples[index] : 0.0
                let response = target > current ? 0.8 : 0.34
                nextSamples.append(current + ((target - current) * response))
            }
            self.waveSamples = nextSamples
            self.redrawWaveform()
        }
    }

    private func redrawWaveform() {
        let centerY = waveContainer.bounds.midY
        guard !waveSamples.isEmpty else {
            return
        }
        let maxExtra: CGFloat = 34
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.045)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (index, bar) in recordingBars.enumerated() {
            let sample = index < waveSamples.count ? waveSamples[index] : 0.0
            let amount = 0.5 + (maxExtra * sample)
            let width = bar.bounds.width > 0 ? bar.bounds.width : 1.5
            bar.frame = CGRect(x: bar.frame.origin.x, y: centerY - (amount / 2), width: width, height: amount)
            let glow = pow(sample, 0.7)
            bar.opacity = Float(0.04 + (0.96 * glow))
        }
        CATransaction.commit()
    }

    private func startProcessingAnimation() {
        advanceProcessingDots()
        let timer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
            self?.advanceProcessingDots()
        }
        processingDotsTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        let shimmer = CABasicAnimation(keyPath: "opacity")
        shimmer.fromValue = 0.94
        shimmer.toValue = 1.0
        shimmer.duration = 0.9
        shimmer.autoreverses = true
        shimmer.repeatCount = .infinity
        shimmer.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blurView.layer?.add(shimmer, forKey: "pill.processingShimmer")
    }

    private func advanceProcessingDots() {
        let states: [[CGFloat]] = [
            [1.0, 0.24, 0.24],
            [1.0, 1.0, 0.24],
            [1.0, 1.0, 1.0],
            [0.24, 1.0, 1.0],
            [0.24, 0.24, 1.0],
            [0.24, 0.24, 0.24]
        ]
        let state = states[processingDotsStep % states.count]
        processingDotsStep += 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for (index, dot) in dotLayers.enumerated() {
            let emphasis = state[index]
            dot.opacity = Float(emphasis)
            let scale = 0.84 + (0.22 * emphasis)
            let lift = -1.8 * emphasis
            dot.transform = CATransform3DConcat(
                CATransform3DMakeScale(scale, scale, 1.0),
                CATransform3DMakeTranslation(0, lift, 0)
            )
        }
        CATransaction.commit()
    }

    private func startSymbolAnimation() {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.78, 1.08, 1.0]
        pop.keyTimes = [0.0, 0.58, 1.0]
        pop.duration = 0.24
        pop.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        symbolLabel.layer?.add(pop, forKey: symbolPopKey)

        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.75
        flash.toValue = 1.0
        flash.duration = 0.18
        flash.autoreverses = true
        flash.repeatCount = 1
        blurView.layer?.add(flash, forKey: "pill.flash")
    }
}

final class KlausFlowApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let pill = FlowPillController()
    private let successSoundNames = ["Tink", "Glass", "Funk", "Pop"]
    private let fillerWords = ["äh", "ähm", "ähhh", "ähhhm", "hm", "hmm", "hmmm", "mhm", "mmh", "mmhm", "uh", "uhm", "um"]
    private let knownHallucinationPhrases = [
        "vielen dank furs zuschauen",
        "danke furs zuschauen",
        "bis zum nachsten mal",
        "untertitel im auftrag des zdf",
        "untertitelung des zdf",
        "danke furs ansehen",
        "tschuss und bis zum nachsten mal"
    ]
    private let knownBogusDomainHints = [
        "hansgrohe-int.com",
        "www.hansgrohe-int.com"
    ]
    private let releaseGraceInterval: TimeInterval = 0.08
    private let localPasteDispatchDelayNs: UInt64 = 50_000_000
    private let localPasteSendDelayNs: UInt64 = 250_000_000
    private let fallbackHotKeySignature: OSType = 0x4b465057

    private var statusItem: NSStatusItem?
    private var modeItems: [OutputMode: NSMenuItem] = [:]
    private var soundItems: [String: NSMenuItem] = [:]
    private var volumeValueItem: NSMenuItem?
    private var polishMenuItem: NSMenuItem?
    private var translateMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var roleplayMenuItem: NSMenuItem?
    private var emojiMenuItem: NSMenuItem?
    private var customPromptMenuItem: NSMenuItem?
    private var autoDetectMenuItem: NSMenuItem?
    private var historyMenu: NSMenu?
    private var transcriptionHistory: [TranscriptionEntry] = []
    private let historyCapacity = 10

    private struct TranscriptionEntry: Codable {
        let text: String
        let date: Date
    }

    private var isRecording = false
    private var isProcessing = false
    private var rightCommandDown = false
    private var leftCommandDown = false
    private var fallbackHotkeyDown = false
    private var pttDown = false
    private var cancelledWhileHeld = false
    private var leftCommandLocked = false
    private var accessibilityPrompted = false
    private var pendingStopWorkItem: DispatchWorkItem?
    private var recordingStartedAt = Date.distantPast
    private var recordingMaxLevel: CGFloat = 0.0
    private let minSpeechRecordingDuration: TimeInterval = 0.3
    private let minSpeechPeakLevel: CGFloat = 0.05
    private var audioRecorder: AVAudioRecorder?
    private var audioURL: URL?
    private var currentProcessingTask: Task<Void, Never>?
    private var hotkeyPollTimer: Timer?
    private var recordingMeterTimer: Timer?
    private var fallbackHotKeyRef: EventHotKeyRef?
    private var fallbackHotKeyHandler: EventHandlerRef?
    private let allowEitherCommand = false

    private var outputMode: OutputMode {
        get {
            let raw = UserDefaults.standard.integer(forKey: OutputMode.defaultsKey)
            return OutputMode(rawValue: raw) ?? .pasteSend
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: OutputMode.defaultsKey)
            refreshMenu()
        }
    }

    private var cleanTextEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "KlausFlowCleanTextEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "KlausFlowCleanTextEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowCleanTextEnabled")
            refreshMenu()
        }
    }

    private var polishEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "KlausFlowPolishEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "KlausFlowPolishEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowPolishEnabled")
            refreshMenu()
        }
    }

    private var translateEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "KlausFlowTranslateEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowTranslateEnabled")
            refreshMenu()
        }
    }

    private var roleplayEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "KlausFlowRoleplayEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowRoleplayEnabled")
            refreshMenu()
        }
    }

    private var emojiEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "KlausFlowEmojiEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowEmojiEnabled")
            refreshMenu()
        }
    }

    private var customPromptEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "KlausFlowCustomPromptEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowCustomPromptEnabled")
            refreshMenu()
        }
    }

    private var customPromptText: String {
        get {
            return UserDefaults.standard.string(forKey: "KlausFlowCustomPromptText")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowCustomPromptText")
        }
    }

    private var autoDetectLanguage: Bool {
        get {
            if UserDefaults.standard.object(forKey: "KlausFlowAutoDetectLanguage") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "KlausFlowAutoDetectLanguage")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowAutoDetectLanguage")
            refreshMenu()
        }
    }

    private var paused: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "KlausFlowPaused")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowPaused")
            refreshMenu()
            updateStatusBarIconForPause()
        }
    }

    private var polishModel: String {
        get {
            let defaults = UserDefaults.standard.string(forKey: "KlausFlowPolishModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return defaults?.isEmpty == false ? defaults! : "llama-3.3-70b-versatile"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowPolishModel")
        }
    }

    private var successSoundName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "KlausFlowSoundName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return successSoundNames.contains(stored) ? stored : "Tink"
        }
        set {
            let name = successSoundNames.contains(newValue) ? newValue : "Tink"
            UserDefaults.standard.set(name, forKey: "KlausFlowSoundName")
            refreshMenu()
        }
    }

    private var successSoundVolume: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: "KlausFlowSoundVolume") as? Double ?? 0.18
            return max(0.0, min(1.0, stored))
        }
        set {
            UserDefaults.standard.set(max(0.0, min(1.0, newValue)), forKey: "KlausFlowSoundVolume")
            refreshMenu()
        }
    }

    private var groqAPIKey: String {
        get {
            let defaults = UserDefaults.standard.string(forKey: "KlausFlowGroqAPIKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let env = ProcessInfo.processInfo.environment["GROQ_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return [defaults, env].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowGroqAPIKey")
        }
    }

    private var groqModel: String {
        get {
            let defaults = UserDefaults.standard.string(forKey: "KlausFlowGroqModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return defaults?.isEmpty == false ? defaults! : "whisper-large-v3"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "KlausFlowGroqModel")
        }
    }

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private var flowHomeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".klaus-flow", isDirectory: true)
    }

    private var dictionaryFileURL: URL {
        flowHomeURL.appendingPathComponent("dictionary.json")
    }

    func run() {
        ensureDictionaryFileExists()
        loadHistory()
        requestPermissions()
        setupStatusBar()
        setupHotkeys()
        print("Klaus Flow ready: hold RIGHT COMMAND or CTRL+SHIFT+SPACE to transcribe")
    }

    private func setupStatusBar() {
        let icon = makeStatusBarIcon()
        statusItem = NSStatusBar.system.statusItem(withLength: max(28, icon.size.width + 8))
        statusItem?.button?.image = icon
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.imageScaling = .scaleProportionallyUpOrDown
        statusItem?.button?.toolTip = "Klaus Flow"

        let menu = NSMenu()
        menu.delegate = self

        let modeTitle = NSMenuItem(title: "Aktion", action: nil, keyEquivalent: "")
        modeTitle.isEnabled = false
        menu.addItem(modeTitle)

        for mode in [OutputMode.paste, .pasteSend] {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            modeItems[mode] = item
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let dictionaryItem = NSMenuItem(title: "Wörterbuch öffnen…", action: #selector(openDictionary(_:)), keyEquivalent: "")
        dictionaryItem.target = self
        menu.addItem(dictionaryItem)

        let polishItem = NSMenuItem(title: "Grammatik", action: #selector(togglePolish(_:)), keyEquivalent: "")
        polishItem.target = self
        polishItem.state = polishEnabled ? .on : .off
        polishMenuItem = polishItem
        menu.addItem(polishItem)

        let translateItem = NSMenuItem(title: "Übersetzen → Englisch", action: #selector(toggleTranslate(_:)), keyEquivalent: "")
        translateItem.target = self
        translateItem.state = translateEnabled ? .on : .off
        translateMenuItem = translateItem
        menu.addItem(translateItem)

        let roleplayItem = NSMenuItem(title: "Roleplay: Altdeutsch", action: #selector(toggleRoleplay(_:)), keyEquivalent: "")
        roleplayItem.target = self
        roleplayItem.state = roleplayEnabled ? .on : .off
        roleplayMenuItem = roleplayItem
        menu.addItem(roleplayItem)

        let emojiItem = NSMenuItem(title: "Emoji-Modus", action: #selector(toggleEmoji(_:)), keyEquivalent: "")
        emojiItem.target = self
        emojiItem.state = emojiEnabled ? .on : .off
        emojiMenuItem = emojiItem
        menu.addItem(emojiItem)

        let customItem = NSMenuItem(title: "Custom Prompt…", action: #selector(configureCustomPrompt(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.state = customPromptEnabled ? .on : .off
        customPromptMenuItem = customItem
        menu.addItem(customItem)

        let autoDetectItem = NSMenuItem(title: "Sprache auto-erkennen", action: #selector(toggleAutoDetect(_:)), keyEquivalent: "")
        autoDetectItem.target = self
        autoDetectItem.state = autoDetectLanguage ? .on : .off
        autoDetectMenuItem = autoDetectItem
        menu.addItem(autoDetectItem)

        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "Letzte Transkriptionen", action: nil, keyEquivalent: "")
        let hMenu = NSMenu()
        historyMenu = hMenu
        menu.setSubmenu(hMenu, for: historyItem)
        menu.addItem(historyItem)
        rebuildHistoryMenu()

        menu.addItem(NSMenuItem.separator())

        let toneItem = NSMenuItem(title: "Klang", action: nil, keyEquivalent: "")
        let toneMenu = NSMenu()
        for name in successSoundNames {
            let item = NSMenuItem(title: name, action: #selector(selectSound(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            soundItems[name] = item
            toneMenu.addItem(item)
        }
        menu.setSubmenu(toneMenu, for: toneItem)
        menu.addItem(toneItem)

        let volumeLabel = NSMenuItem(title: soundVolumeLabel(), action: nil, keyEquivalent: "")
        volumeLabel.isEnabled = false
        volumeValueItem = volumeLabel
        menu.addItem(volumeLabel)

        let slider = NSSlider(value: successSoundVolume, minValue: 0.0, maxValue: 1.0, target: self, action: #selector(soundVolumeChanged(_:)))
        slider.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        let sliderItem = NSMenuItem()
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        slider.frame.origin = NSPoint(x: 10, y: 2)
        wrapper.addSubview(slider)
        sliderItem.view = wrapper
        menu.addItem(sliderItem)

        menu.addItem(NSMenuItem.separator())

        let permissionsItem = NSMenuItem(title: "Rechte prüfen", action: #selector(checkPermissions(_:)), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let logsItem = NSMenuItem(title: "Logs öffnen…", action: #selector(openLogs(_:)), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        let keyItem = NSMenuItem(title: "Groq-Schlüssel…", action: #selector(configureGroqKey(_:)), keyEquivalent: "")
        keyItem.target = self
        menu.addItem(keyItem)

        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(title: "Pausieren", action: #selector(togglePause(_:)), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.state = paused ? .on : .off
        pauseMenuItem = pauseItem
        menu.addItem(pauseItem)

        let quitItem = NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        refreshMenu()
    }

    private func makeStatusBarIcon() -> NSImage {
        let iconPath = flowHomeURL.appendingPathComponent("klaus-flow-icon.png")
        if let image = NSImage(contentsOf: iconPath) {
            let targetHeight: CGFloat = 18.0
            let aspect = max(1.0, image.size.width / max(image.size.height, 1))
            let targetWidth = round(targetHeight * aspect)
            image.size = NSSize(width: targetWidth, height: targetHeight)
            return image
        }
        if let url = Bundle.main.url(forResource: "klaus-flow-logo", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            let targetHeight: CGFloat = 16.2
            let aspect = max(1.0, image.size.width / max(image.size.height, 1))
            let targetWidth = min(32.4, max(19.8, round(targetHeight * aspect)))
            image.size = NSSize(width: targetWidth, height: targetHeight)
            image.isTemplate = true
            return image
        }

        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size).insetBy(dx: 1.8, dy: 1.8)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.39

        let ring = NSBezierPath()
        ring.appendOval(in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let innerRadius = radius * 0.48
        ring.appendOval(in: NSRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
        ring.windingRule = .evenOdd
        NSColor.black.setFill()
        ring.fill()

        let diskRect = NSRect(
            x: bounds.minX + 0.4,
            y: center.y - 1.2,
            width: bounds.width - 0.8,
            height: 2.4
        )
        let disk = NSBezierPath(roundedRect: diskRect, xRadius: 1.2, yRadius: 1.2)
        disk.fill()

        let crescent = NSBezierPath()
        crescent.lineWidth = 1.35
        crescent.lineCapStyle = .round
        crescent.appendArc(
            withCenter: center,
            radius: radius * 0.9,
            startAngle: 35,
            endAngle: 145,
            clockwise: false
        )
        NSColor.black.setStroke()
        crescent.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func setupHotkeys() {
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.syncHotkeyState()
            self?.pollEscapeKey()
        }
        hotkeyPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        setupFallbackHotkey()
    }

    private func setupFallbackHotkey() {
        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let app = Unmanaged<KlausFlowApp>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == app.fallbackHotKeySignature else { return noErr }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                app.fallbackHotkeyDown = pressed
                app.syncHotkeyState()
            }
            return noErr
        }

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), handler, eventTypes.count, eventTypes, userData, &fallbackHotKeyHandler)

        let hotKeyID = EventHotKeyID(signature: fallbackHotKeySignature, id: 1)
        let modifiers = UInt32(controlKey | shiftKey)
        RegisterEventHotKey(UInt32(kVK_Space), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &fallbackHotKeyRef)
    }

    private var escapeWasDown = false

    private func pollEscapeKey() {
        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(53))
        if escapeDown && !escapeWasDown && isRecording {
            logLine("FLOW escape_pressed — cancelling recording")
            cancelRecording()
        }
        escapeWasDown = escapeDown
    }

    private func requestPermissions() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        logLine("FLOW microphone_status \(status.rawValue)")

        switch status {
        case .authorized:
            print("FLOW microphone permission: true")
        case .notDetermined:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.logLine("FLOW microphone permission: \(granted)")
                    NSApp.setActivationPolicy(.accessory)
                    if !granted {
                        self.openMicrophoneSettings()
                    }
                }
            }
        case .denied, .restricted:
            print("FLOW microphone permission: false")
            openMicrophoneSettings()
        @unknown default:
            print("FLOW microphone permission: false")
        }
    }

    private func openMicrophoneSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ]
        for value in urls {
            if let url = URL(string: value) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == 54 || event.keyCode == 55 else { return }
        let rawFlags = event.modifierFlags.rawValue
        rightCommandDown = (rawFlags & nxDeviceRCmdKeyMask) != 0
        leftCommandDown = (rawFlags & nxDeviceLCmdKeyMask) != 0
        leftCommandLocked = leftCommandDown && !rightCommandDown && !allowEitherCommand
        syncHotkeyState()
    }

    private func syncHotkeyState() {
        let pressed = fallbackHotkeyDown || rightCommandDown || (allowEitherCommand && leftCommandDown)
        guard pressed != pttDown else { return }
        pttDown = pressed
        logLine("FLOW ptt_state pressed=\(pressed) rightCommand=\(rightCommandDown) leftCommand=\(leftCommandDown) fallback=\(fallbackHotkeyDown)")
        if !pressed {
            cancelledWhileHeld = false
            scheduleStopRecordingIfNeeded()
        } else if !cancelledWhileHeld {
            startRecordingIfNeeded()
        }
    }

    private func scheduleStopRecordingIfNeeded() {
        pendingStopWorkItem?.cancel()
        guard isRecording else { return }
        logLine("FLOW recording_release_grace scheduled interval=\(releaseGraceInterval)")
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStopWorkItem = nil
            guard !self.pttDown else { return }
            self.stopRecordingIfNeeded()
        }
        pendingStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseGraceInterval, execute: item)
    }

    private func startRecordingIfNeeded() {
        guard !isRecording else { return }
        if paused || isProcessing {
            return
        }

        var lastError: Error?
        for attempt in 1...2 {
            var localURL: URL?
            do {
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("klaus-flow-\(UUID().uuidString).m4a")
                localURL = tmp
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                    AVEncoderBitRateKey: 48_000
                ]
                let recorder = try AVAudioRecorder(url: tmp, settings: settings)
                recorder.isMeteringEnabled = true
                recorder.prepareToRecord()
                guard recorder.record() else {
                    throw NSError(domain: "flow", code: 12, userInfo: [NSLocalizedDescriptionKey: "Aufnahme konnte nicht gestartet werden"])
                }
                audioRecorder = recorder
                audioURL = tmp
                isRecording = true
                recordingStartedAt = Date()
                recordingMaxLevel = 0.0
                logLine("FLOW recording_started path=\(tmp.path)")
                pill.resetRecordingWave()
                pill.show(state: .recording, mode: outputMode)
                startRecordingMeterUpdates()
                return
            } catch {
                lastError = error
                stopRecordingMeterUpdates()
                audioRecorder?.stop()
                audioRecorder = nil
                if let localURL {
                    try? FileManager.default.removeItem(at: localURL)
                }
                audioURL = nil
                if attempt == 1 {
                    Thread.sleep(forTimeInterval: 0.03)
                }
            }
        }
        print("FLOW recording_failed \(lastError?.localizedDescription ?? "unknown")")
        pill.show(state: .failure, mode: outputMode, autoHideAfter: 1.2)
    }

    private func stopRecordingIfNeeded() {
        guard isRecording else { return }
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        isRecording = false

        stopRecordingMeterUpdates()
        audioRecorder?.stop()
        audioRecorder = nil
        let duration = max(0, Date().timeIntervalSince(recordingStartedAt))
        recordingStartedAt = Date.distantPast
        logLine("FLOW recording_stopped duration=\(String(format: "%.2f", duration)) pttDown=\(pttDown)")

        guard let url = audioURL else {
            pill.show(state: .failure, mode: outputMode, autoHideAfter: 1.2)
            return
        }

        let capturedMaxLevel = recordingMaxLevel
        if duration < minSpeechRecordingDuration || capturedMaxLevel < minSpeechPeakLevel {
            logLine("FLOW recording_skipped_silence duration=\(String(format: "%.2f", duration)) maxLevel=\(String(format: "%.3f", capturedMaxLevel))")
            try? FileManager.default.removeItem(at: url)
            audioURL = nil
            recordingMaxLevel = 0.0
            pill.show(state: .failure, mode: outputMode, autoHideAfter: 1.2)
            return
        }
        recordingMaxLevel = 0.0

        isProcessing = true
        pill.show(state: .processing, mode: outputMode)

        currentProcessingTask = Task {
            defer {
                self.isProcessing = false
                self.audioURL = nil
                self.currentProcessingTask = nil
            }
            await self.processAudio(url)
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        logLine("FLOW recording_cancelled")
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        isRecording = false
        pttDown = false
        cancelledWhileHeld = true

        stopRecordingMeterUpdates()
        audioRecorder?.stop()
        audioRecorder = nil
        if let url = audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioURL = nil
        recordingStartedAt = Date.distantPast
        recordingMaxLevel = 0.0

        pill.show(state: .failure, mode: outputMode, autoHideAfter: 1.2)
    }

    private func startRecordingMeterUpdates() {
        stopRecordingMeterUpdates()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.audioRecorder, self.isRecording else { return }
            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            let peakPower = recorder.peakPower(forChannel: 0)
            let average = self.normalizedAudioLevel(fromPower: averagePower)
            let peak = self.normalizedAudioLevel(fromPower: peakPower)
            let level = min(1.0, max(0.0, (average * 0.3) + (peak * 0.7)))
            if peak > self.recordingMaxLevel {
                self.recordingMaxLevel = peak
            }
            self.pill.updateRecordingLevel(level)
        }
        recordingMeterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingMeterUpdates() {
        recordingMeterTimer?.invalidate()
        recordingMeterTimer = nil
        pill.updateRecordingLevel(0.0)
    }

    private func normalizedAudioLevel(fromPower power: Float) -> CGFloat {
        guard power.isFinite else { return 0.0 }
        if power <= -60 { return 0.0 }
        let normalized = max(0.0, min(1.0, (power + 60.0) / 60.0))
        return CGFloat(pow(normalized, 1.35))
    }

    private func processAudio(_ fileURL: URL) async {
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        do {
            let transcript = try await transcribe(fileURL)
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = cleanTextEnabled ? cleanTranscript(trimmed) : trimmed
            logLine("FLOW transcript_raw \(trimmed)")
            logLine("FLOW transcript_final \(cleaned)")
            guard !cleaned.isEmpty else {
                await showPill(.failure, autoHideAfter: 1.2)
                return
            }
            var finalText = cleaned
            if polishEnabled {
                do {
                    logLine("FLOW polish_before \(cleaned)")
                    let polished = try await polishGrammar(cleaned)
                    logLine("FLOW polish_after \(polished)")
                    finalText = polished
                } catch {
                    logLine("FLOW polish_error \(error.localizedDescription)")
                }
            }
            if translateEnabled {
                do {
                    logLine("FLOW translate_before \(finalText)")
                    let translated = try await translateToEnglish(finalText)
                    logLine("FLOW translate_after \(translated)")
                    finalText = translated
                } catch {
                    logLine("FLOW translate_error \(error.localizedDescription)")
                }
            }
            if roleplayEnabled {
                do {
                    logLine("FLOW roleplay_before \(finalText)")
                    let medieval = try await roleplayAltdeutsch(finalText)
                    logLine("FLOW roleplay_after \(medieval)")
                    finalText = medieval
                } catch {
                    logLine("FLOW roleplay_error \(error.localizedDescription)")
                }
            }
            if customPromptEnabled && !customPromptText.isEmpty {
                do {
                    logLine("FLOW custom_prompt_before \(finalText)")
                    let custom = try await applyCustomPrompt(finalText)
                    logLine("FLOW custom_prompt_after \(custom)")
                    finalText = custom
                } catch {
                    logLine("FLOW custom_prompt_error \(error.localizedDescription)")
                }
            }
            if emojiEnabled {
                do {
                    logLine("FLOW emoji_before \(finalText)")
                    let withEmoji = try await addEmojis(finalText)
                    logLine("FLOW emoji_after \(withEmoji)")
                    finalText = withEmoji
                } catch {
                    logLine("FLOW emoji_error \(error.localizedDescription)")
                }
            }
            guard !finalText.isEmpty else {
                await showPill(.failure, autoHideAfter: 1.2)
                return
            }

            addToHistory(finalText)

            // Klaus Bot integration: if WoW is active AND bot is running, send as command
            if isFrontmostAppWoW(), await sendToKlausBotIfRunning(finalText) {
                logLine("FLOW sent_to_klaus_bot \(finalText)")
                playSuccessSound()
                await showPill(.success, autoHideAfter: 1.0)
                return
            }

            let pb = NSPasteboard.general
            pb.clearContents()
            let copied = pb.setString(finalText, forType: .string)
            guard copied else {
                await showPill(.failure, autoHideAfter: 1.2)
                return
            }

            let action = await performLocalPasteActionIfPossible()
            logLine("FLOW local_action mode=\(outputMode.title) pasted=\(action.pasted) sent=\(action.sent)")
            let completed: Bool
            switch outputMode {
            case .paste:
                if action.pasted {
                    playSuccessSound()
                }
                completed = action.pasted
            case .pasteSend:
                if action.pasted {
                    playSuccessSound()
                }
                completed = action.pasted && action.sent
            }
            guard completed else {
                await showPill(.failure, autoHideAfter: 1.2)
                return
            }
            await showPill(.success, autoHideAfter: 1.0)
        } catch {
            logLine("FLOW process_error \(error.localizedDescription)")
            await showPill(.failure, autoHideAfter: 1.2)
        }
    }

    @MainActor
    private func showPill(_ state: PillState, autoHideAfter delay: TimeInterval? = nil) {
        pill.show(state: state, mode: outputMode, autoHideAfter: delay)
    }

    private func transcribeWithGroq(_ fileURL: URL, prompt: String) async throws -> String {
        let apiKey = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw NSError(domain: "flow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Groq API Key fehlt"])
        }

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        let contentType: String
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            contentType = "audio/wav"
        case "m4a":
            contentType = "audio/m4a"
        default:
            contentType = "application/octet-stream"
        }
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)

        var fields: [(String, String)] = [
            ("model", groqModel),
            ("temperature", "0"),
            ("response_format", "json"),
            ("prompt", prompt)
        ]
        if !autoDetectLanguage {
            fields.insert(("language", "de"), at: 1)
        }

        for (name, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "flow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Groq ohne HTTP-Antwort"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "flow", code: 3, userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "Groq Transcription fehlgeschlagen" : text])
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let text = json["text"] as? String else {
            throw NSError(domain: "flow", code: 4, userInfo: [NSLocalizedDescriptionKey: "Groq-Antwort ohne Text"])
        }
        return text
    }

    private func polishGrammar(_ text: String) async throws -> String {
        let apiKey = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return text }

        let systemPrompt = """
            Du korrigierst gesprochenes Deutsch. Regeln:
            - Nur Grammatik, Kasus, Numerus und Zeichensetzung korrigieren.
            - Wortwahl, Stil und Satzstruktur NICHT ändern.
            - Keine Wörter hinzufügen oder entfernen.
            - Englische Wörter und Phrasen NIEMALS übersetzen oder eindeutschen. Sie sind absichtlich englisch.
            - Nur den korrigierten Text ausgeben, nichts anderes.
            """

        let payload: [String: Any] = [
            "model": polishModel,
            "temperature": 0,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let errText = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "flow", code: 10, userInfo: [NSLocalizedDescriptionKey: "Groq polish fehlgeschlagen: \(errText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "flow", code: 11, userInfo: [NSLocalizedDescriptionKey: "Groq polish: Antwort ohne content"])
        }

        let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return polished.isEmpty ? text : polished
    }

    private func translateToEnglish(_ text: String) async throws -> String {
        let apiKey = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return text }

        let systemPrompt = """
            Du bist ein professioneller Übersetzer. Übersetze den folgenden deutschen Text ins Englische.
            - Übersetze sinngemäß, nicht Wort für Wort.
            - Der englische Text muss grammatikalisch perfekt und natürlich klingen.
            - Behalte den Ton und Stil des Originals bei.
            - Fachbegriffe und Eigennamen beibehalten.
            - Nur die englische Übersetzung ausgeben, nichts anderes.
            """

        let payload: [String: Any] = [
            "model": polishModel,
            "temperature": 0,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let errText = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "flow", code: 20, userInfo: [NSLocalizedDescriptionKey: "Groq translate fehlgeschlagen: \(errText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "flow", code: 21, userInfo: [NSLocalizedDescriptionKey: "Groq translate: Antwort ohne content"])
        }

        let translated = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty ? text : translated
    }

    private func roleplayAltdeutsch(_ text: String) async throws -> String {
        let apiKey = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return text }

        let systemPrompt = """
            Formuliere den Text in Altdeutsch um. Kurz und knapp — gleiche Länge wie das Original.
            - "Ihr/Euch" statt "du/dich", mittelalterliches Vokabular.
            - KEINE zusätzlichen Wörter, Sätze oder Ausschmückungen hinzufügen.
            - Gleiche Anzahl Sätze wie im Original.
            - Eigennamen und Fachbegriffe beibehalten.
            - Nur den umgewandelten Text ausgeben.
            """

        let payload: [String: Any] = [
            "model": polishModel,
            "temperature": 0.7,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let errText = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "flow", code: 30, userInfo: [NSLocalizedDescriptionKey: "Groq roleplay fehlgeschlagen: \(errText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "flow", code: 31, userInfo: [NSLocalizedDescriptionKey: "Groq roleplay: Antwort ohne content"])
        }

        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text : result
    }

    private func addEmojis(_ text: String) async throws -> String {
        let apiKey = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return text }

        let systemPrompt = """
            Füge passende Emojis zum Text hinzu. Regeln:
            - Maximal 1-2 Emojis pro Satz, dezent und passend.
            - Emojis ans Satzende oder an passende Stellen setzen.
            - Den Text selbst NICHT verändern — nur Emojis hinzufügen.
            - Nur den Text mit Emojis ausgeben, nichts anderes.
            """

        let payload: [String: Any] = [
            "model": polishModel,
            "temperature": 0.3,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let errText = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "flow", code: 40, userInfo: [NSLocalizedDescriptionKey: "Groq emoji fehlgeschlagen: \(errText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "flow", code: 41, userInfo: [NSLocalizedDescriptionKey: "Groq emoji: Antwort ohne content"])
        }

        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text : result
    }

    private func applyCustomPrompt(_ text: String) async throws -> String {
        let apiKey = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return text }
        let prompt = customPromptText
        guard !prompt.isEmpty else { return text }

        let payload: [String: Any] = [
            "model": polishModel,
            "temperature": 0.3,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let errText = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "flow", code: 50, userInfo: [NSLocalizedDescriptionKey: "Groq custom prompt fehlgeschlagen: \(errText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "flow", code: 51, userInfo: [NSLocalizedDescriptionKey: "Groq custom prompt: Antwort ohne content"])
        }

        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text : result
    }

    private func transcribe(_ fileURL: URL) async throws -> String {
        let prompt = buildConditioningPrompt()
        let text = try await transcribeWithGroq(fileURL, prompt: prompt)
        logLine("FLOW transcribe backend=groq")
        if isLikelyHallucination(text) || isLikelyBogusDomain(text) {
            logLine("FLOW hallucination_rejected text=\(normalizedComparisonText(text))")
            throw NSError(domain: "flow", code: 205, userInfo: [NSLocalizedDescriptionKey: "Transkription war unklar"])
        }
        return text
    }

    private func buildConditioningPrompt() -> String {
        var terms: [String] = []
        if let config = loadDictionaryConfig() {
            var seen = Set<String>()
            for value in config.replacements.values {
                if seen.insert(value).inserted {
                    terms.append(value)
                }
            }
        }
        if terms.isEmpty {
            terms = ["Klaus Flow", "Groq", "Claude", "OpenClaw"]
        }
        return terms.joined(separator: ", ")
    }

    private func cleanTranscript(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = removeFillerWords(from: text)
        text = applyDictionaryReplacements(to: text)

        text = text
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: "\\s*([,.;:!?])\\s*", with: "$1 ", options: .regularExpression)
            .replacingOccurrences(of: "([,.;:!?]){2,}", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\s([,.;:!?])(?=\\s)", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let first = text.first {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        return text
    }

    private func removeFillerWords(from text: String) -> String {
        let escaped = fillerWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let patterns = [
            "(?i)(^|[\\s(\\[\"'„“”‚‘’])(?:\(escaped))(?=($|[\\s,.;:!?\\)\\]\"'„“”‚‘’]))",
            "(?i)([.!?]\\s*)(?:\(escaped))(?=($|[\\s,.;:!?]))"
        ]

        var cleaned = text
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }

        cleaned = cleaned
            .replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    private func normalizedComparisonText(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
        return folded
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = normalizedComparisonText(text)
        guard !normalized.isEmpty else { return true }
        if knownHallucinationPhrases.contains(where: { phrase in
            normalized == phrase || normalized.contains(phrase)
        }) {
            return true
        }
        return looksLikeConditioningEcho(normalized)
    }

    private func looksLikeConditioningEcho(_ normalized: String) -> Bool {
        let outputTokens = normalized.split(separator: " ").map(String.init)
        guard !outputTokens.isEmpty, outputTokens.count <= 8 else { return false }
        let promptNormalized = normalizedComparisonText(buildConditioningPrompt())
        let promptTokens = Set(promptNormalized.split(separator: " ").map(String.init))
        guard !promptTokens.isEmpty else { return false }
        let echoCount = outputTokens.filter { promptTokens.contains($0) }.count
        let ratio = Double(echoCount) / Double(outputTokens.count)
        return ratio >= 0.8
    }

    private func isLikelyBogusDomain(_ text: String) -> Bool {
        let normalized = normalizedComparisonText(text)
        guard !normalized.isEmpty else { return false }
        if knownBogusDomainHints.contains(where: { normalized.contains($0.replacingOccurrences(of: ".", with: " ")) || normalized.contains($0) }) {
            return true
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenCount = trimmed.split(whereSeparator: \.isWhitespace).count
        let domainLikePattern = #"^(?:https?:\/\/)?(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:\/\S*)?$"#
        let matchesDomain = trimmed.range(of: domainLikePattern, options: [.regularExpression, .caseInsensitive]) != nil
        return tokenCount <= 2 && matchesDomain
    }


    private struct DictionaryConfig: Codable {
        let replacements: [String: String]
    }

    private func applyDictionaryReplacements(to text: String) -> String {
        guard let config = loadDictionaryConfig() else { return text }
        var output = text

        for (source, target) in config.replacements {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            let pattern = "(?i)\\b\(escaped)\\b"
            output = output.replacingOccurrences(of: pattern, with: target, options: .regularExpression)
        }

        return output
    }

    private func loadDictionaryConfig() -> DictionaryConfig? {
        guard let data = try? Data(contentsOf: dictionaryFileURL) else { return nil }
        return try? JSONDecoder().decode(DictionaryConfig.self, from: data)
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "KlausFlowHistory") else { return }
        transcriptionHistory = (try? JSONDecoder().decode([TranscriptionEntry].self, from: data)) ?? []
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(transcriptionHistory) else { return }
        UserDefaults.standard.set(data, forKey: "KlausFlowHistory")
    }

    private func addToHistory(_ text: String) {
        let entry = TranscriptionEntry(text: text, date: Date())
        transcriptionHistory.append(entry)
        if transcriptionHistory.count > historyCapacity {
            transcriptionHistory.removeFirst(transcriptionHistory.count - historyCapacity)
        }
        saveHistory()
        DispatchQueue.main.async { self.rebuildHistoryMenu() }
    }

    private func rebuildHistoryMenu() {
        guard let menu = historyMenu else { return }
        menu.removeAllItems()
        if transcriptionHistory.isEmpty {
            let empty = NSMenuItem(title: "Keine Einträge", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        for (index, entry) in transcriptionHistory.reversed().enumerated() {
            let preview = entry.text.count > 50 ? String(entry.text.prefix(50)) + "…" : entry.text
            let time = formatter.string(from: entry.date)
            let item = NSMenuItem(title: "\(time)  \(preview)", action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = transcriptionHistory.count - 1 - index
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Verlauf löschen", action: #selector(clearHistory(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index >= 0, index < transcriptionHistory.count else { return }
        let text = transcriptionHistory[index].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearHistory(_ sender: Any?) {
        transcriptionHistory.removeAll()
        saveHistory()
        rebuildHistoryMenu()
    }

    private func ensureDictionaryFileExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: flowHomeURL.path) {
            try? fm.createDirectory(at: flowHomeURL, withIntermediateDirectories: true)
        }
        guard !fm.fileExists(atPath: dictionaryFileURL.path) else { return }

        let seed = """
        {
          "replacements": {
            "grog": "Groq",
            "grock": "Groq",
            "open claw": "OpenClaw",
            "claude": "Claude",
            "claude code": "Claude Code",
            "klaus flow": "Klaus Flow"
          }
        }
        """
        try? seed.write(to: dictionaryFileURL, atomically: true, encoding: .utf8)
    }

    private func sendToKlausBotIfRunning(_ text: String) async -> Bool {
        // Try to reach the Klaus bot on localhost:9921
        // If it responds, send the text as a command and return true
        // If not reachable, return false (normal paste flow continues)
        guard let url = URL(string: "http://127.0.0.1:9921/command") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 1.0  // Fast timeout — don't block if bot isn't running
        let body: [String: Any] = ["text": text]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        req.httpBody = bodyData
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            logLine("FLOW klaus_bot_response \(String(data: data, encoding: .utf8) ?? "")")
            return true
        } catch {
            // Bot not running — fall through to normal paste
            return false
        }
    }

    private func isFrontmostAppWoW() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return bundleID.lowercased().contains("blizzard.worldofwarcraft")
    }

    private func autoOpenChatReturnIfPossible() async -> Bool {
        let hasAccessibility = checkAccessibility()
        if hasAccessibility {
            await releaseSyntheticModifiersIfNeeded()
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let postedEvents = hasAccessibility ? await MainActor.run {
            guard let source = syntheticKeyEventSource(),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
                return false
            }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return true
        } : false
        if postedEvents {
            try? await Task.sleep(nanoseconds: 200_000_000)
            logLine("FLOW wow_open_chat postedEvents=true")
            return true
        }
        let scriptSuccess = runSendAppleScriptFallback()
        logLine("FLOW wow_open_chat postedEvents=false scriptFallback=\(scriptSuccess)")
        return scriptSuccess
    }

    private func performLocalPasteActionIfPossible() async -> (pasted: Bool, sent: Bool) {
        let isWoW = isFrontmostAppWoW()
        if isWoW {
            logLine("FLOW wow_detected opening chat before paste")
        }
        switch outputMode {
        case .paste:
            if isWoW {
                let opened = await autoOpenChatReturnIfPossible()
                guard opened else { return (false, false) }
            }
            let pasted = await autoPasteClipboardIfPossible()
            return (pasted, false)
        case .pasteSend:
            if isWoW {
                let opened = await autoOpenChatReturnIfPossible()
                guard opened else { return (false, false) }
            }
            let pasted = await autoPasteClipboardIfPossible()
            guard pasted else { return (false, false) }
            let sent = await autoSendReturnIfPossible()
            return (true, sent)
        }
    }

    private func syntheticKeyEventSource() -> CGEventSource? {
        CGEventSource(stateID: .privateState)
            ?? CGEventSource(stateID: .hidSystemState)
            ?? CGEventSource(stateID: .combinedSessionState)
    }

    private func autoPasteClipboardIfPossible() async -> Bool {
        let hasAccessibility = checkAccessibility()
        try? await Task.sleep(nanoseconds: localPasteDispatchDelayNs)
        let postedEvents = hasAccessibility ? await MainActor.run {
            guard let source = syntheticKeyEventSource(),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                return false
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return true
        } : false
        if postedEvents {
            return true
        }
        let scriptSuccess = runPasteAppleScriptFallback()
        logLine("FLOW paste_attempt accessibility=\(hasAccessibility) postedEvents=\(postedEvents) scriptFallback=\(scriptSuccess)")
        return scriptSuccess
    }

    private func autoSendReturnIfPossible() async -> Bool {
        let hasAccessibility = checkAccessibility()
        try? await Task.sleep(nanoseconds: localPasteSendDelayNs)
        let flagsBeforeRelease = currentModifierFlagsDescription()
        if hasAccessibility {
            await releaseSyntheticModifiersIfNeeded()
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let flagsBeforeSend = currentModifierFlagsDescription()
        let postedEvents = hasAccessibility ? await MainActor.run {
            guard let source = syntheticKeyEventSource(),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
                return false
            }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return true
        } : false
        if postedEvents {
            try? await Task.sleep(nanoseconds: 140_000_000)
            logLine("FLOW send_attempt accessibility=\(hasAccessibility) flagsBeforeRelease=\(flagsBeforeRelease) flagsBeforeSend=\(flagsBeforeSend) postedEvents=\(postedEvents) scriptFallback=false")
            return true
        }
        let scriptSuccess = runSendAppleScriptFallback()
        logLine("FLOW send_attempt accessibility=\(hasAccessibility) flagsBeforeRelease=\(flagsBeforeRelease) flagsBeforeSend=\(flagsBeforeSend) postedEvents=\(postedEvents) scriptFallback=\(scriptSuccess)")
        return scriptSuccess
    }

    private func releaseSyntheticModifiersIfNeeded() async {
        await MainActor.run {
            guard let source = syntheticKeyEventSource() else { return }
            let modifierKeyCodes: [CGKeyCode] = [54, 55, 56, 60, 58, 61, 59, 62]
            for keycode in modifierKeyCodes {
                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false),
                      let sessionUp = keyUp.copy() else {
                    continue
                }
                keyUp.flags = []
                sessionUp.flags = []
                keyUp.post(tap: .cghidEventTap)
                sessionUp.post(tap: .cgSessionEventTap)
            }
        }
    }

    private func currentModifierFlagsDescription() -> String {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if flags.isEmpty {
            return "-"
        }
        var parts: [String] = []
        if flags.contains(.maskCommand) { parts.append("cmd") }
        if flags.contains(.maskControl) { parts.append("ctrl") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskAlternate) { parts.append("alt") }
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        return parts.isEmpty ? "other" : parts.joined(separator: "+")
    }

    private func runPasteAppleScriptFallback() -> Bool {
        let scripts = [
            "tell application \"System Events\" to keystroke \"v\" using command down",
            "tell application \"System Events\" to key code 9 using command down"
        ]
        var ranAny = false
        for source in scripts {
            guard let script = NSAppleScript(source: source) else { continue }
            var errorInfo: NSDictionary?
            _ = script.executeAndReturnError(&errorInfo)
            if errorInfo == nil {
                ranAny = true
            } else if let errorInfo {
                logLine("FLOW paste_applescript_error \(errorInfo)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return ranAny
    }

    private func runSendAppleScriptFallback() -> Bool {
        let scripts = [
            "tell application \"System Events\" to key code 36",
            "tell application \"System Events\" to key code 76"
        ]
        var ranAny = false
        for source in scripts {
            guard let script = NSAppleScript(source: source) else { continue }
            var errorInfo: NSDictionary?
            _ = script.executeAndReturnError(&errorInfo)
            if errorInfo == nil {
                ranAny = true
            } else if let errorInfo {
                logLine("FLOW send_applescript_error \(errorInfo)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return ranAny
    }

    private func checkAccessibility() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        if !accessibilityPrompted {
            accessibilityPrompted = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    private func playSuccessSound() {
        guard successSoundVolume > 0 else { return }
        DispatchQueue.main.async {
            if let sound = NSSound(named: NSSound.Name(self.successSoundName)) {
                sound.stop()
                sound.volume = Float(self.successSoundVolume)
                sound.play()
            }
        }
    }

    private func soundVolumeLabel() -> String {
        "Lautstärke \(Int((successSoundVolume * 100).rounded()))%"
    }

    private func checkAutomationPermission(promptIfNeeded: Bool) -> Bool {
        let source = "tell application \"System Events\" to get name of first process"
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if errorInfo == nil {
            return true
        }
        if let errorInfo {
            logLine("FLOW automation_permission_error \(errorInfo)")
        }
        if promptIfNeeded {
            return false
        }
        return false
    }

    private func logLine(_ line: String) {
        if let data = "\(line)\n".data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private func refreshMenu() {
        for (mode, item) in modeItems {
            item.state = mode == outputMode ? .on : .off
        }
        volumeValueItem?.title = soundVolumeLabel()
        for (name, item) in soundItems {
            item.state = name == successSoundName ? .on : .off
        }
        polishMenuItem?.state = polishEnabled ? .on : .off
        translateMenuItem?.state = translateEnabled ? .on : .off
        roleplayMenuItem?.state = roleplayEnabled ? .on : .off
        emojiMenuItem?.state = emojiEnabled ? .on : .off
        customPromptMenuItem?.state = customPromptEnabled ? .on : .off
        autoDetectMenuItem?.state = autoDetectLanguage ? .on : .off
        pauseMenuItem?.state = paused ? .on : .off
    }

    @objc private func togglePolish(_ sender: NSMenuItem) {
        polishEnabled.toggle()
    }

    @objc private func toggleTranslate(_ sender: NSMenuItem) {
        translateEnabled.toggle()
    }

    @objc private func toggleRoleplay(_ sender: NSMenuItem) {
        roleplayEnabled.toggle()
    }

    @objc private func toggleEmoji(_ sender: NSMenuItem) {
        emojiEnabled.toggle()
    }

    @objc private func toggleAutoDetect(_ sender: NSMenuItem) {
        autoDetectLanguage.toggle()
    }

    @objc private func configureCustomPrompt(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.string = customPromptText
        textView.isRichText = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let toggle = NSButton(checkboxWithTitle: "Aktiv", target: nil, action: nil)
        toggle.state = customPromptEnabled ? .on : .off

        let stack = NSStackView(views: [scrollView, toggle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 110)

        let alert = NSAlert()
        alert.messageText = "Custom Prompt"
        alert.informativeText = "Eigene Anweisung für die Textverarbeitung nach der Transkription."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")
        if alert.runModal() == .alertFirstButtonReturn {
            customPromptText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            customPromptEnabled = toggle.state == .on
        }
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        logLine("FLOW paused=\(paused)")
    }

    private func updateStatusBarIconForPause() {
        if paused {
            statusItem?.button?.appearsDisabled = true
        } else {
            statusItem?.button?.appearsDisabled = false
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = OutputMode(rawValue: sender.tag) else { return }
        outputMode = mode
    }

    @objc private func selectSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        successSoundName = name
    }

    @objc private func soundVolumeChanged(_ sender: NSSlider) {
        successSoundVolume = sender.doubleValue
    }

    @objc private func configureGroqKey(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSSecureTextField(string: groqAPIKey)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        let alert = NSAlert()
        alert.messageText = "Groq API Key"
        alert.informativeText = "Wird lokal gespeichert und nur für Transkription genutzt."
        alert.accessoryView = field
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")
        if alert.runModal() == .alertFirstButtonReturn {
            groqAPIKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func openDictionary(_ sender: Any?) {
        ensureDictionaryFileExists()
        NSWorkspace.shared.open(dictionaryFileURL)
    }

    @objc private func checkPermissions(_ sender: Any?) {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micText: String
        switch micStatus {
        case .authorized: micText = "ok"
        case .denied: micText = "blockiert"
        case .restricted: micText = "eingeschränkt"
        case .notDetermined: micText = "offen"
        @unknown default: micText = "unbekannt"
        }

        let accessibility = checkAccessibility()
        let automation = checkAutomationPermission(promptIfNeeded: true)

        let micSymbol = micText == "ok" ? "✓" : "✕"
        let accSymbol = accessibility ? "✓" : "✕"
        let autoSymbol = automation ? "✓" : "✕"

        let message = """
        \(micSymbol)  Mikrofon: \(micText)
        \(accSymbol)  Bedienungshilfen: \(accessibility ? "ok" : "fehlt")
        \(autoSymbol)  Automation: \(automation ? "ok" : "fehlt")
        """
        logLine("FLOW permissions mic=\(micText) accessibility=\(accessibility) automation=\(automation)")

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Klaus Flow Rechte"

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 72))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.accessoryView = textView

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Kopieren")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        }
    }

    @objc private func openLogs(_ sender: Any?) {
        let logsDir = flowHomeURL.appendingPathComponent("logs", isDirectory: true)
        NSWorkspace.shared.open(logsDir)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }
}

let app = NSApplication.shared
let delegate = KlausFlowApp()
app.setActivationPolicy(.accessory)
app.delegate = delegate
DispatchQueue.main.async {
    delegate.run()
}
app.run()
