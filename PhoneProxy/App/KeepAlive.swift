import AVFoundation

/// 循环播放静音音频，配合 UIBackgroundModes=audio 让 App 切到后台后继续运行。
final class KeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var wanted = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        wanted = true
        if observers.isEmpty { observe() }
        run()
    }

    func stop() {
        wanted = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func run() {
        guard wanted else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            if !attached {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: fmt)
                attached = true
            }
            let frames: AVAudioFrameCount = 44100
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            buf.floatChannelData![0].initialize(repeating: 0, count: Int(frames))

            if !engine.isRunning { try engine.start() }
            player.stop()
            player.scheduleBuffer(buf, at: nil, options: .loops)
            player.play()
        } catch {
            // 稍后重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.run() }
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .ended { self?.run() }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            self?.run()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.run()
        })
    }
}
