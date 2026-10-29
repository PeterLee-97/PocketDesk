import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        FileStore.prepareDirectories()
        HardwareInput.shared.start()
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Let videos and web audio play even when the ring switch is set to silent.
        PlaybackAudio.shared.activate()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            return SceneConfigurations.externalDisplay()
        }
        let configuration = UISceneConfiguration(name: "Phone", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PhoneSceneDelegate.self
        return configuration
    }
}

/// WebKit uses the application's audio session, including on a non-interactive display.
final class PlaybackAudio: NSObject {
    static let shared = PlaybackAudio()
    private let queue = DispatchQueue(label: "PocketDesk.Audio")
    private var active = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reset),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    func activate() {
        queue.async { [weak self] in self?.activateNow() }
    }

    private func activateNow() {
        guard !active else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            if audio.category != .playback || audio.mode != .moviePlayback {
                try audio.setCategory(.playback, mode: .moviePlayback)
            }
            try audio.setActive(true)
            active = true
        } catch {
            NSLog("PocketDesk audio activation: %@", error.localizedDescription)
        }
    }

    @objc private func reset() {
        queue.async { [weak self] in self?.active = false; self?.activateNow() }
    }

    @objc private func interrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if type == AVAudioSession.InterruptionType.began.rawValue {
            queue.async { [weak self] in self?.active = false }
            return
        }
        guard type == AVAudioSession.InterruptionType.ended.rawValue,
              let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else { return }
        activate()
    }
}

enum SceneConfigurations {
    static func externalDisplay() -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "External Display", sessionRole: .windowExternalDisplayNonInteractive)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        return configuration
    }
}
