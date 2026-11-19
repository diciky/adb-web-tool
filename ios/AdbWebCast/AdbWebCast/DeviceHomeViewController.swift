import UIKit

/// 设备功能主页：顶部设备信息 + TabBar 承载 7 项功能
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
        let autostart = AutostartViewController(host: host)
        let batch = BatchViewController(host: host)
        let tools = ToolsViewController(host: host)

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
            wrap(autostart, "自启", "bolt"),
            wrap(batch, "批量", "square.stack.3d.up"),
            wrap(tools, "工具", "wrench.and.screwdriver"),
        ]
        selectedIndex = 0
    }
}
