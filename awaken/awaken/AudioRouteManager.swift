import AVFoundation
import Combine

@MainActor
final class AudioRouteManager: ObservableObject {
    @Published var currentRouteName: String = "Unknown"
    @Published var isA2DPActive: Bool = false
    @Published var isTestTonePlaying: Bool = false
    @Published var isKeepAliveOn: Bool = true {
        didSet { isKeepAliveOn ? scheduleKeepAlive() : stopKeepAlive() }
    }
    @Published var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private var engine = AVAudioEngine()
    private var toneNode = AVAudioPlayerNode()
    private var keepAliveNode = AVAudioPlayerNode()
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?

    init() {
        configureSession()
        buildAndStartEngine()
        observeNotifications()
        refreshRoute()
        // Keep-alive starts automatically (isKeepAliveOn defaults to true).
        // Audio MUST be flowing before the user switches to A2DP,
        // otherwise iOS drops the Bluetooth connection after ~5 seconds.
        scheduleKeepAlive()
    }

    deinit {
        [routeObserver, interruptionObserver, configObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    // MARK: - Audio Session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .allowBluetoothA2DP is implicit for .playback, but be explicit.
            try session.setCategory(.playback, options: [.allowBluetoothA2DP])
            try session.setActive(true, options: [])
            print("[Audio] Session: .playback + allowBluetoothA2DP active")
        } catch {
            print("[Audio] Session error: \(error)")
        }
    }

    // MARK: - Engine

    private func buildAndStartEngine() {
        engine = AVAudioEngine()
        toneNode = AVAudioPlayerNode()
        keepAliveNode = AVAudioPlayerNode()

        engine.attach(toneNode)
        engine.attach(keepAliveNode)

        let format = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(toneNode, to: engine.mainMixerNode, format: format)
        engine.connect(keepAliveNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume

        do {
            try engine.start()
            print("[Audio] Engine started: \(format.sampleRate)Hz \(format.channelCount)ch")
        } catch {
            print("[Audio] Engine start failed: \(error)")
        }
    }

    /// Tear down and rebuild the engine for a new audio route/format.
    private func rebuildEngine() {
        let wasPlaying = isTestTonePlaying
        let wasKeepAlive = isKeepAliveOn

        engine.stop()
        buildAndStartEngine()

        if wasPlaying { scheduleTone() }
        if wasKeepAlive { scheduleKeepAlive() }
        print("[Audio] Engine rebuilt (tone=\(wasPlaying) keepAlive=\(wasKeepAlive))")
    }

    private func makeSineBuffer(frequency: Double, duration: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer? {
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let channels = format.channelCount
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        for ch in 0..<Int(channels) {
            guard let data = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                data[i] = amplitude * Float(sin(2.0 * .pi * frequency * t))
            }
        }
        return buffer
    }

    // MARK: - Test Tone

    func toggleTestTone() {
        if isTestTonePlaying {
            stopTestTone()
        } else {
            startTestTone()
        }
    }

    private func startTestTone() {
        if !engine.isRunning { try? engine.start() }
        scheduleTone()
        isTestTonePlaying = true
        print("[Audio] Test tone ON")
    }

    private func scheduleTone() {
        guard let buffer = makeSineBuffer(frequency: 440, duration: 2.0) else { return }
        toneNode.stop()
        toneNode.scheduleBuffer(buffer, at: nil, options: .loops)
        toneNode.play()
    }

    private func stopTestTone() {
        toneNode.stop()
        isTestTonePlaying = false
        print("[Audio] Test tone OFF")
    }

    // MARK: - Keep Alive

    private func scheduleKeepAlive() {
        if !engine.isRunning { try? engine.start() }
        guard let buffer = makeSineBuffer(frequency: 1, duration: 2.0, amplitude: 0.003) else { return }
        keepAliveNode.stop()
        keepAliveNode.scheduleBuffer(buffer, at: nil, options: .loops)
        keepAliveNode.play()
        print("[Audio] Keep-alive ON")
    }

    private func stopKeepAlive() {
        keepAliveNode.stop()
        print("[Audio] Keep-alive OFF")
    }

    // MARK: - Notifications

    private func observeNotifications() {
        // Route change — rebuild engine so it picks up new output format
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
                print("[Audio] Route change reason: \(reason?.rawValue ?? 999)")
                self.refreshRoute()

                // CRITICAL: Do NOT rebuild the engine here.
                // AVAudioEngine automatically follows the system audio route.
                // Rebuilding creates a silence gap that causes iOS to drop A2DP.
                // Only restart if the engine somehow stopped on its own.
                if !self.engine.isRunning {
                    print("[Audio] Engine stopped after route change — restarting")
                    try? self.engine.start()
                    if self.isKeepAliveOn { self.scheduleKeepAlive() }
                    if self.isTestTonePlaying { self.scheduleTone() }
                }
            }
        }

        // Engine config change — the hardware format changed under us
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("[Audio] Engine config changed — rebuilding")
                self?.rebuildEngine()
            }
        }

        // Interruption (phone call, etc)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let info = notification.userInfo,
                      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                if type == .ended {
                    print("[Audio] Interruption ended — rebuilding")
                    self?.configureSession()
                    self?.rebuildEngine()
                }
            }
        }
    }

    func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let output = outputs.first
        let name = output?.portName ?? "No Output"
        let portType = output?.portType.rawValue ?? "none"
        let a2dp = outputs.contains { $0.portType == .bluetoothA2DP }
        let awaken = outputs.contains { $0.portName.localizedCaseInsensitiveContains("Awaken") }

        currentRouteName = name
        isA2DPActive = a2dp || awaken
        print("[Audio] Route: \(name) (type=\(portType)), A2DP: \(isA2DPActive), engine running: \(engine.isRunning)")

        // Log all outputs for debugging
        for (i, out) in outputs.enumerated() {
            print("[Audio]   output[\(i)]: \(out.portName) type=\(out.portType.rawValue) uid=\(out.uid)")
        }
    }
}
