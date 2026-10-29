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
        try? AVAudioSession.sharedInstance().setCategory(.playback)
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

enum SceneConfigurations {
    static func externalDisplay() -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "External Display", sessionRole: .windowExternalDisplayNonInteractive)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        return configuration
    }
}
