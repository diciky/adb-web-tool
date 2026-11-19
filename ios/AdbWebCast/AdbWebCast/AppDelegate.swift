import UIKit
#if canImport(Darwin)
import Darwin
#endif

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // ADB socket 写入时若电视中途断开，避免 SIGPIPE 直接杀掉进程
        signal(SIGPIPE, SIG_IGN)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: DeviceListViewController())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
