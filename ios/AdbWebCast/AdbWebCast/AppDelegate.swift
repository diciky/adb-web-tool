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

        // 首次 ADB 授权：电视弹出 USB 调试授权框时，在 App 内同步给出明确指引。
        // 关键：勾选电视弹框里的「Always allow from this computer / 一律允许」后点 OK，
        // 公钥会永久存入电视，此后任何连接都不再弹框。
        NotificationCenter.default.addObserver(
            forName: .adbAuthorizationRequired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showAuthorizationTip()
        }
        return true
    }

    private var didShowAuthTip = false
    private func showAuthorizationTip() {
        guard !didShowAuthTip, let root = window?.rootViewController else { return }
        didShowAuthTip = true
        let ac = UIAlertController(
            title: "请在电视上授权",
            message: "电视刚弹出「Allow USB debugging」对话框。\n\n请点按遥控器：\n1️⃣ 勾选「Always allow from this computer（一律允许此电脑）」\n2️⃣ 选择 OK\n\n勾选「一律允许」后，以后所有功能都不会再弹授权框。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "知道了", style: .default))
        // 若当前正呈现其他页面，从最顶层弹出
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(ac, animated: true)
    }
}
