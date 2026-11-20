import UIKit
import StoreKit
import Combine

// MARK: - 商品 ID（价格/试用在 App Store Connect 配置：¥6/月、¥9/年、¥30 永久解锁）
enum ProProductID {
    static let monthly = "cool.cnb.adbweb.console.pro.monthly"
    static let yearly = "cool.cnb.adbweb.console.pro.yearly"
    static let lifetime = "cool.cnb.adbweb.console.pro.lifetime"
    static let all = [monthly, yearly, lifetime]
}

// MARK: - StoreKit 2 权益管理
@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPro = false
    @Published private(set) var message = ""

    private init() {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
        Task { await self.loadProducts(); await self.refreshEntitlements() }
    }

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: ProProductID.all)
            products = fetched.sorted { $0.price < $1.price }
        } catch {
            message = "商品加载失败：\(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard ProProductID.all.contains(transaction.productID) else { continue }
            if transaction.revocationDate == nil { unlocked = true }
        }
        isPro = unlocked
    }

    func purchase(_ product: Product) async {
        message = "正在购买…"
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlements()
                    message = isPro ? "Pro 权益已解锁" : "购买完成，但未识别到权益"
                } else {
                    message = "购买凭证验证失败，请联系支持"
                }
            case .userCancelled:
                message = "已取消购买"
            case .pending:
                message = "购买待批准（家庭共享或未成年人账户）"
            @unknown default:
                message = "未知购买结果"
            }
        } catch {
            message = "购买失败：\(error.localizedDescription)"
        }
    }

    func restore() async {
        message = "正在恢复购买…"
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = isPro ? "已恢复 Pro 权益" : "当前账户没有可恢复的购买"
        } catch {
            message = "恢复失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Pro 门禁
@MainActor
enum ProGate {
    static func run(from viewController: UIViewController, action: () -> Void) {
        if PurchaseManager.shared.isPro {
            action()
        } else {
            viewController.presentPaywall()
        }
    }
}

// MARK: - 付费墙
final class PaywallViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let table: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Pro 权益"
        l.font = .systemFont(ofSize: 26, weight: .bold)
        l.accessibilityLabel = "Pro 权益"
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.text = "解锁截屏与设备管理的全部高级能力。订阅与永久解锁权益完全相同。"
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }()

    private let features = [
        "截屏：历史记录、标注裁剪、OCR 取字、录制导出",
        "设备管理：历史曲线、阈值告警、CSV 报告导出",
        "多设备看板、性能评分、异常联动定时任务",
        "续订说明：年订阅 ¥9/年，7 天试用后生效；可随时在 iOS 设置中取消",
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Pro"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close)
        )

        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        header.axis = .vertical
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.layoutMargins = UIEdgeInsets(top: 16, left: 20, bottom: 12, right: 20)
        header.isLayoutMarginsRelativeArrangement = true

        table.dataSource = self
        table.delegate = self
        table.tableHeaderView = header
        table.tableFooterView = footer()
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        Task {
            await PurchaseManager.shared.loadProducts()
            await MainActor.run { self.table.reloadData() }
        }
    }

    private func footer() -> UIView {
        let restore = UIButton(type: .system)
        restore.setTitle("恢复购买", for: .normal)
        restore.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        restore.accessibilityLabel = "恢复已购买的项目"
        restore.addTarget(self, action: #selector(restore), for: .touchUpInside)

        let status = UILabel()
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        status.text = "永久解锁为一次性购买，不会自动续费。"
        status.accessibilityLabel = status.text

        let box = UIStackView(arrangedSubviews: [restore, status])
        box.axis = .vertical
        box.spacing = 8
        box.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 24, right: 20)
        box.isLayoutMarginsRelativeArrangement = true
        box.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 120)
        return box
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func restore() {
        Task {
            await PurchaseManager.shared.restore()
            await MainActor.run {
                let ac = UIAlertController(
                    title: nil,
                    message: PurchaseManager.shared.message,
                    preferredStyle: .alert
                )
                ac.addAction(UIAlertAction(title: "知道了", style: .default))
                self.present(ac, animated: true)
            }
        }
    }

    // MARK: Table
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Pro 包含" : "选择付费方式"
    }

    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? features.count : max(PurchaseManager.shared.products.count, 1)
    }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            cfg.text = features[indexPath.row]
            cfg.image = UIImage(systemName: "checkmark.circle.fill")
            cfg.imageProperties.tintColor = .systemGreen
            cell.accessoryType = .none
            cell.selectionStyle = .none
        } else {
            let products = PurchaseManager.shared.products
            if products.isEmpty {
                cfg.text = PurchaseManager.shared.message.isEmpty ? "商品加载中…" : PurchaseManager.shared.message
                cfg.secondaryText = nil
                cell.selectionStyle = .none
            } else {
                let p = products[indexPath.row]
                cfg.text = proTitle(for: p)
                cfg.secondaryText = p.displayPrice
                cfg.image = UIImage(systemName: p.productIdentifier == ProProductID.lifetime ? "infinity.circle" : "calendar")
                cell.selectionStyle = .default
            }
        }
        cfg.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = cfg
        return cell
    }

    private func proTitle(for product: Product) -> String {
        switch product.productIdentifier {
        case ProProductID.monthly: return "月度订阅"
        case ProProductID.yearly: return "年度订阅 · 7 天免费试用"
        case ProProductID.lifetime: return "永久解锁（推荐）"
        default: return product.displayName
        }
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1,
              let product = PurchaseManager.shared.products[safe: indexPath.row] else { return }
        Task {
            await PurchaseManager.shared.purchase(product)
            await MainActor.run {
                let ac = UIAlertController(
                    title: nil,
                    message: PurchaseManager.shared.message,
                    preferredStyle: .alert
                )
                ac.addAction(UIAlertAction(title: "知道了", style: .default) { [weak self] _ in
                    if PurchaseManager.shared.isPro { self?.dismiss(animated: true) }
                })
                self.present(ac, animated: true)
            }
        }
    }
}

extension UIViewController {
    func presentPaywall() {
        let nav = UINavigationController(rootViewController: PaywallViewController())
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }
}
