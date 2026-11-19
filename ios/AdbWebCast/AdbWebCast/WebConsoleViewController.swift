import AVFoundation
import UIKit
import WebKit

/// 记录需要放行自签名证书的 host。
final class SelfSessionDelegate {
    static let shared = SelfSessionDelegate()
    var trustHosts = Set<String>()
    private init() {}
}

/// 一个把网页控制台装进原生壳的容器。
///
/// 这里的关键不是 WebView 本身，而是**上传应用文件必须走得通**：
/// iOS 16 上 `<input type="file">` 只会回调 `WKUIDelegate` 的
/// `webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`，
/// 如果不实现、或者实现了却不调用 completionHandler，页面上那个按钮点了永远没反应。
final class WebConsoleViewController: UIViewController {

    // 默认地址，可在顶部输入框里改；改完会写进 UserDefaults
    private static let defaultURL = "http://192.168.1.100:8877"
    private static let urlKey = "console.url"

    private var webView: WKWebView!
    private lazy var addressField: UITextField = {
        let field = UITextField()
        field.placeholder = "服务器地址，如 http://192.168.1.10:8877"
        field.borderStyle = .roundedRect
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()
    private lazy var progressBar: UIProgressView = {
        let bar = UIProgressView(progressViewStyle: .bar)
        bar.progressTintColor = .systemBlue
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    private var progressObservation: NSKeyValueObservation?
    private var refreshControl: UIRefreshControl!
    // 文件选择器是异步的，completionHandler 必须挂在这里等用户选完
    private var pendingOpenPanel: (([URL]?) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ADB 控制台"
        view.backgroundColor = .systemBackground
        setupWebView()
        setupChrome()
        loadSavedURL()
        registerForKeyboardNotifications()
    }

    // MARK: - 视图搭建

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 局域网服务常是 http，允许混合内容，避免页面被整块拦掉
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 上传的大文件会被 WebKit 落到临时目录
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.keyboardDismissMode = .interactive
        // iOS 16 仍然沿用 16 起的「键盘弹出自动调整」，显式打开更稳
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        view.addSubview(webView)

        refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupChrome() {
        let bar = UIStackView(arrangedSubviews: [addressField])
        bar.axis = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let container = UIStackView(arrangedSubviews: [bar, progressBar])
        container.axis = .vertical
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        navigationItem.titleView = container
        progressBar.heightAnchor.constraint(equalToConstant: 2).isActive = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(goBack)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(handleRefresh)),
            UIBarButtonItem(image: UIImage(systemName: "list.bullet"), style: .plain, target: self, action: #selector(showMenu)),
        ]

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            let p = Float(webView.estimatedProgress)
            self?.progressBar.progress = p
            self?.progressBar.isHidden = p >= 1
            if p >= 1 { self?.refreshControl.endRefreshing() }
        }
    }

    // MARK: - 地址

    private func loadSavedURL() {
        let saved = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL
        addressField.text = saved
        load(urlString: saved)
    }

    private func load(urlString: String) {
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard let url = URL(string: text) else {
            alert("地址无效", "请检查网关地址，例如 http://192.168.1.10:8877")
            return
        }
        UserDefaults.standard.set(text, forKey: Self.urlKey)
        addressField.text = text
        let request = URLRequest(url: url)
        webView.load(request)
    }

    @objc private func goBack() {
        if webView.canGoBack { webView.goBack() } else { addressField.becomeFirstResponder() }
    }

    @objc private func handleRefresh() {
        if webView.url != nil {
            webView.reload()
        } else {
            loadSavedURL()
        }
    }

    @objc private func showMenu() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "重新加载", style: .default) { [weak self] _ in self?.handleRefresh() })
        sheet.addAction(UIAlertAction(title: "回到首页", style: .default) { [weak self] _ in self?.loadSavedURL() })
        sheet.addAction(UIAlertAction(
            title: SelfSessionDelegate.shared.trustHosts.isEmpty ? "信任自签名证书…" : "已信任当前 https 域名",
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            if let host = self.webView.url?.host {
                SelfSessionDelegate.shared.trustHosts.insert(host)
                self.loadSavedURL()
            } else {
                self.alert("还没有打开过 https 地址", "先用 https:// 打开一次，再回来登记。")
            }
        })
        sheet.addAction(UIAlertAction(title: "清除网页缓存", style: .destructive) { [weak self] _ in
            let store = WKWebsiteDataStore.default()
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                self?.handleRefresh()
            }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        // iPad 上 actionSheet 必须有锚点，否则崩
        if let pop = sheet.popoverPresentationController {
            pop.barButtonItem = navigationItem.rightBarButtonItems?.last
        }
        present(sheet, animated: true)
    }

    private func alert(_ title: String, _ message: String) {
        let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "好", style: .default))
        present(controller, animated: true)
    }

    // MARK: - 键盘

    private func registerForKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillHide() {
        addressField.resignFirstResponder()
    }
}

// MARK: - UITextFieldDelegate

extension WebConsoleViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        load(urlString: textField.text ?? "")
        return true
    }
}

// MARK: - WKNavigationDelegate

extension WebConsoleViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        progressBar.isHidden = true
        if let host = webView.url?.host, let port = webView.url?.port {
            addressField.text = "http://\(host):\(port)"
        } else if let url = webView.url?.absoluteString {
            addressField.text = url
        }
        navigationItem.leftBarButtonItem?.isEnabled = webView.canGoBack
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        // 只提示网络类错误，-999（用户取消）不打扰
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        alert("打不开这个地址", error.localizedDescription)
    }

    // 自签名证书：局域网自建服务很常见。只对已登记的 host 放行，不全局关闭校验。
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              SelfSessionDelegate.shared.trustHosts.contains(challenge.protectionSpace.host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // 外部协议交给系统（如 tel:/mailto:），http/https 留在壳里
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "file", "blob", "data", "ws", "wss"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate（上传文件就靠这一段）

extension WebConsoleViewController: WKUIDelegate {

    /// 网页里的 `<input type="file">`（上传应用安装包、上传文件）都走这里。
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let picker = UIDocumentPickerViewController(
            documentTypes: Self.documentTypes(),
            in: .import // .import 会把文件复制到 App 沙箱，权限问题最少
        )
        picker.allowsMultipleSelection = parameters.allowsMultipleSelection
        picker.delegate = self
        // 必须挂住 completionHandler：取消时也要回调一次 null，
        // 否则同一个 input 第二次点不会再触发（iOS 16 上表现尤其明显）
        pendingOpenPanel = completionHandler
        present(picker, animated: true)
    }

    /// 让 completionHandler 在取消时也能被释放
    private func finishOpenPanel(_ urls: [URL]?) {
        guard let handler = pendingOpenPanel else { return }
        pendingOpenPanel = nil
        handler(urls)
    }

    /// iOS 不认识 apk 这个 UTI，直接给 com.pkware.zip-archive / public.data
    /// 会把安装包挡在选择器外面（显示为灰色不可选）。
    /// WKOpenPanelParameters 没有公开 accept 类型（acceptMimeTypes 并不存在），
    /// 因此统一放行通用 UTI，让 apk / zip / 各类媒体文件都能被选中。
    private static func documentTypes() -> [String] {
        return ["public.data", "public.item", "com.pkware.zip-archive",
                "public.image", "public.movie", "public.audio", "public.text"]
    }

    // JS alert / confirm / prompt，不实现的话网页上的确认弹窗直接不显示
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let controller = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(controller, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let controller = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        controller.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        present(controller, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let controller = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        controller.addTextField { $0.text = defaultText }
        controller.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(controller.textFields?.first?.text)
        })
        controller.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        present(controller, animated: true)
    }

    // 摄像头 / 麦克风授权（投屏发送端用）
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        switch type {
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { decisionHandler(granted ? .grant : .deny) }
            }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { decisionHandler(granted ? .grant : .deny) }
            }
        default:
            decisionHandler(.prompt)
        }
    }
}

// MARK: - UIDocumentPickerDelegate

extension WebConsoleViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishOpenPanel(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishOpenPanel(nil)
    }
}
