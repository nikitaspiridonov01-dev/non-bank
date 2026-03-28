import UIKit
import WebKit

final class ViewController: UIViewController {
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        view.addSubview(webView)

        // 👇 ИЗМЕНЕНИЕ ЗДЕСЬ: ищем внутри ios-www.bundle
        guard let indexPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "ios-www.bundle") else {
            print("Ошибка: Файл index.html не найден!")
            return
        }

        let fileURL = URL(fileURLWithPath: indexPath)
        let readAccessURL = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
    }
}
