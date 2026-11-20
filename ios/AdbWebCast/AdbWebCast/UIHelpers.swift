import UIKit
import UniformTypeIdentifiers

/// 通用 UI 辅助
enum UIKitHelper {
    static func alert(_ title: String, _ msg: String, in vc: UIViewController, ok: (() -> Void)? = nil) {
        let c = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        c.addAction(UIAlertAction(title: "好", style: .default) { _ in ok?() })
        vc.present(c, animated: true)
    }

    static func confirm(_ title: String, _ msg: String, in vc: UIViewController, destructive: Bool = true, onYes: @escaping () -> Void) {
        let c = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        c.addAction(UIAlertAction(title: "取消", style: .cancel))
        c.addAction(UIAlertAction(title: "确定", style: destructive ? .destructive : .default) { _ in onYes() })
        vc.present(c, animated: true)
    }

    static func input(_ title: String, placeholder: String = "", current: String = "", in vc: UIViewController, onOK: @escaping (String) -> Void) {
        let c = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        c.addTextField { tf in tf.placeholder = placeholder; tf.text = current }
        c.addAction(UIAlertAction(title: "取消", style: .cancel))
        c.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            onOK(c.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? "")
        })
        vc.present(c, animated: true)
    }

    /// 文档选择器：放行通用 UTI，解决 iOS 不认识 apk 导致灰色不可选
    static func pickFiles(in vc: UIViewController, multiple: Bool, delegate: UIDocumentPickerDelegate) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data, .archive, .package], asCopy: true)
        picker.delegate = delegate
        picker.allowsMultipleSelection = multiple
        vc.present(picker, animated: true)
    }
}

/// 简单的文档选择代理，回调 URL 列表
final class DocumentPickerHelper: NSObject, UIDocumentPickerDelegate {
    var onPick: (([URL]) -> Void)?
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick?(urls)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick?([]) }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 在系统临时目录创建副本（DocumentPicker 返回的是安全作用域 URL，需先取权限并复制）
func copyToTemp(_ url: URL) -> URL? {
    guard url.startAccessingSecurityScopedResource() else { return nil }
    defer { url.stopAccessingSecurityScopedResource() }
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
    do {
        try FileManager.default.copyItem(at: url, to: tmp)
        return tmp
    } catch { return nil }
}

// MARK: - 运行日志（环形缓冲，用于调试 ADB 协议问题；可在 App 内查看/复制/分享）

enum AdbLog {
    static let maxLines = 1500
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static var seq = 0
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ msg: String, level: String = "I") {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        let line = "\(fmt.string(from: Date())) [\(level)] #\(seq) \(msg)"
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    static func dump() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
        log("日志已清空")
    }
}

/// 日志查看页：实时显示 + 复制 / 分享 / 清空，方便把日志发回来定位问题
final class LogViewerViewController: UIViewController, UITextViewDelegate {
    private let output = UITextView()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "运行日志"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share))
        let copy = UIBarButtonItem(title: "复制全部", style: .plain, target: self, action: #selector(copyAll))
        let clear = UIBarButtonItem(title: "清空", style: .plain, target: self, action: #selector(wipe))
        navigationItem.leftBarButtonItems = [copy, clear]
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.isEditable = false
        output.backgroundColor = .secondarySystemBackground
        output.layer.cornerRadius = 8
        output.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(output)
        NSLayoutConstraint.activate([
            output.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            output.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            output.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            output.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.reload() }
        reload()
    }
    deinit { timer?.invalidate() }

    private func reload() {
        let text = AdbLog.dump()
        let wasAtBottom = output.contentSize.height - output.contentOffset.y - output.bounds.height < 40
        output.text = text.isEmpty ? "（暂无日志）" : text
        if wasAtBottom { output.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0)) }
    }

    @objc private func copyAll() {
        UIPasteboard.general.string = AdbLog.dump()
        UIKitHelper.alert("已复制", "全部日志已复制到剪贴板", in: self)
    }
    @objc private func share() {
        let text = AdbLog.dump()
        guard !text.isEmpty else { return }
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(vc, animated: true)
    }
    @objc private func wipe() { AdbLog.clear(); reload() }
}
