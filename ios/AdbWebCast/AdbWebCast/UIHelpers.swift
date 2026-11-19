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
