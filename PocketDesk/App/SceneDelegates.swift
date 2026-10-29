import UIKit

/// The phone's own screen: hosts the trackpad / keyboard controller.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PhoneViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        DeskSession.shared.phoneDidBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        DeskSession.shared.phoneWillResignActive()
    }
}

/// The monitor/TV: iOS creates this scene (role `windowExternalDisplayNonInteractive`) when a
/// display is attached by cable or AirPlay, instead of mirroring the phone.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = DeskSession.shared.makeOrReuseDesktop()
        // Don't call makeKeyAndVisible(): the phone's window must keep key status for keyboard input.
        window.isHidden = false
        self.window = window
        DeskSession.shared.displayDidConnect(windowScene: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Detach the desktop so it can be shown again (with its windows) on the next connection.
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        DeskSession.shared.displayDidDisconnect()
    }
}

/// From iOS 27, apps built with the iOS 27 SDK no longer get external-display scenes
/// automatically: a view controller has to register an "external non-interactive" scene
/// accessory. The calls go through the Objective-C runtime so the project also builds with
/// older SDKs (Xcode 26) where `UISceneAccessory` doesn't exist; on iOS 16–26 the Info.plist
/// scene configuration is enough and this is a no-op.
final class ExternalDisplayAccessory {
    private var registration: NSObject?

    var isAvailable: Bool {
        (registration?.value(forKey: "available") as? Bool) ?? false
    }

    func register(from viewController: UIViewController) {
        guard registration == nil else { return }
        guard #available(iOS 27.0, *) else { return }
        guard let accessoryClass = NSClassFromString("UISceneAccessory") else { return }
        let configuration = SceneConfigurations.externalDisplay()

        var accessory: AnyObject?
        let factory = NSSelectorFromString("externalNonInteractiveSceneAccessoryWithConfiguration:")
        let factoryWithInfo = NSSelectorFromString("externalNonInteractiveSceneAccessoryWithConfiguration:userInfo:")
        if let method = class_getClassMethod(accessoryClass, factory) {
            typealias Factory = @convention(c) (AnyClass, Selector, UISceneConfiguration) -> Unmanaged<AnyObject>?
            let function = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            accessory = function(accessoryClass, factory, configuration)?.takeUnretainedValue()
        } else if let method = class_getClassMethod(accessoryClass, factoryWithInfo) {
            typealias Factory = @convention(c) (AnyClass, Selector, UISceneConfiguration, AnyObject?) -> Unmanaged<AnyObject>?
            let function = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            accessory = function(accessoryClass, factoryWithInfo, configuration, nil)?.takeUnretainedValue()
        }
        guard let accessory else { return }

        let register = NSSelectorFromString("registerSceneAccessory:")
        guard viewController.responds(to: register),
              let result = viewController.perform(register, with: accessory)?.takeUnretainedValue() as? NSObject else { return }
        if result.responds(to: NSSelectorFromString("setEnabled:")) {
            result.setValue(true, forKey: "enabled")
        }
        registration = result
    }
}
