import UIKit

/// 设备功能主页：5 个 Tab 扁平承载全部功能。
/// 工具箱/自启/批量/日志放在「设备」Tab 的功能宫格里一击直达，不再出现 UIKit
/// 自动生成的「更多」收纳页（超过 5 个 tab 就会被折叠进去）。
final class DeviceHomeViewController: UITabBarController {

    private let host: AdbHost
    private let deviceModel: String

    init(host: AdbHost, deviceModel: String) {
        self.host = host
        self.deviceModel = deviceModel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = deviceModel.isEmpty ? host.serial : deviceModel
        view.backgroundColor = .systemBackground

        let info = InfoViewController(host: host, deviceModel: deviceModel)
        let apps = AppsViewController(host: host)
        let install = InstallViewController(host: host, deviceModel: deviceModel)
        let files = FilesViewController(host: host)
        let remote = RemoteViewController(host: host, deviceModel: deviceModel)

        func wrap(_ vc: UIViewController, _ title: String, _ icon: String) -> UINavigationController {
            vc.title = title
            let nav = UINavigationController(rootViewController: vc)
            nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), tag: 0)
            return nav
        }

        viewControllers = [
            wrap(info, "设备", "tv.circle"),
            wrap(apps, "应用", "square.grid.2x2"),
            wrap(install, "安装", "arrow.down.app"),
            wrap(files, "文件", "folder"),
            wrap(remote, "遥控", "gamecontroller"),
        ]
        selectedIndex = 0
        AdbLog.log("进入设备页 \(host.serial)（5 Tab 扁平结构）")
    }
}
