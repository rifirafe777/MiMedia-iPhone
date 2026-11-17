import SwiftUI
import WebKit
import UIKit

@main
@MainActor
struct MiMediaApp: App {
    @State private var library = NativeLibrary()
    var body: some Scene {
        WindowGroup { NativeWebView(library: library).preferredColorScheme(.dark).ignoresSafeArea(edges: .bottom) }
    }
}

@MainActor
struct NativeWebView: UIViewRepresentable {
    let library: NativeLibrary
    func makeCoordinator() -> Coordinator { Coordinator(library: library) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mimedia")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false; web.backgroundColor = UIColor(red: 12/255, green: 13/255, blue: 11/255, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.navigationDelegate = context.coordinator; web.uiDelegate = context.coordinator
        context.coordinator.attach(web)
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop(); uiView.configuration.userContentController.removeScriptMessageHandler(forName: "mimedia")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private let library: NativeLibrary
        private weak var web: WKWebView?
        private var timer: Timer?
        private var observers: [NSObjectProtocol] = []
        init(library: NativeLibrary) { self.library = library; super.init() }
        func attach(_ web: WKWebView) {
            self.web = web
            library.changed = { [weak self] in self?.push() }
            startTimer()
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.startTimer(); self?.push() } })
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.timer?.invalidate(); self?.timer = nil } })
        }
        private func startTimer() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, UIApplication.shared.applicationState == .active else { return }
                    self.send(["event": "playback", "value": ["currentID": self.library.player.currentID.map { $0 as Any } ?? NSNull(), "playing": self.library.player.playing, "position": self.library.player.position, "duration": self.library.player.duration]])
                }
            }
        }
        func stop() { timer?.invalidate(); observers.forEach { NotificationCenter.default.removeObserver($0) }; library.changed = nil }
        private func send(_ value: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return }
            web?.evaluateJavaScript("window.MiMediaNative && window.MiMediaNative.receive(\(json));", completionHandler: nil)
        }
        func push() {
            guard UIApplication.shared.applicationState == .active else { return }
            send(["event": "state", "value": library.snapshot()])
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { push() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, url.isFileURL,
                  let root = Bundle.main.resourceURL?.appendingPathComponent("Web").standardizedFileURL.path,
                  url.standardizedFileURL.path.hasPrefix(root + "/") else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
                  let root = Bundle.main.resourceURL?.appendingPathComponent("Web").standardizedFileURL.path,
                  message.frameInfo.request.url?.standardizedFileURL.path.hasPrefix(root + "/") == true,
                  let body = message.body as? [String: Any], let id = body["id"] as? String, let method = body["method"] as? String else { return }
            do {
                let args = body["args"] as? [String: Any] ?? [:]
                if method == "share" {
                    guard let songID = args["id"] as? String, let song = library.catalog.songs.first(where: { $0.id == songID }) else { throw NativeError("No existe esa canción.") }
                    let controller = UIActivityViewController(activityItems: [library.file(song)], applicationActivities: nil)
                    controller.popoverPresentationController?.sourceView = web
                    presentingController()?.present(controller, animated: true)
                } else if method != "state" { try library.perform(method, args: args) }
                send(["id": id, "value": library.snapshot()])
            } catch { send(["id": id, "error": error.localizedDescription]) }
        }
        private func presentingController() -> UIViewController? {
            var controller = web?.window?.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            return controller
        }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: "MiMedia", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler() })
            guard let controller = presentingController() else { completionHandler(); return }; controller.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: "MiMedia", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "Confirmar", style: .default) { _ in completionHandler(true) })
            guard let controller = presentingController() else { completionHandler(false); return }; controller.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: "MiMedia", message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "Guardar", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            guard let controller = presentingController() else { completionHandler(nil); return }; controller.present(alert, animated: true)
        }
    }
}
