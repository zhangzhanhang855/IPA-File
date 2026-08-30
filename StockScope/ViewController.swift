import UIKit
import WebKit

class ViewController: UIViewController {
    var webView: WKWebView!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let u = URL(string: "https://jr-staff-center.onrender.com/admin.html") {
            webView.load(URLRequest(url: u))
        }
    }
}

extension ViewController: WKNavigationDelegate, WKUIDelegate {}
