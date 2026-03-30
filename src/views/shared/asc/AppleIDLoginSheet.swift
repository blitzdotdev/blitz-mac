import SwiftUI
import WebKit

struct AppleIDLoginSheet: View {
    var subtitle: String = "Sign in to App Store Connect to authenticate your Apple ID session."
    var onSessionCaptured: (IrisSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in with Apple ID")
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            ZStack {
                ASCWebView(
                    isLoading: $isLoading,
                    onSessionCaptured: { session in
                        irisLog("AppleIDLoginSheet: onSessionCaptured called, \(session.cookies.count) cookies")
                        onSessionCaptured(session)
                        dismiss()
                    }
                )

                if isLoading {
                    ProgressView("Loading App Store Connect…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background.opacity(0.8))
                }
            }
        }
        .frame(width: 520, height: 620)
        .onAppear { irisLog("AppleIDLoginSheet: sheet appeared") }
    }
}

// MARK: - WKWebView Wrapper

struct ASCWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    var onSessionCaptured: (IrisSession) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.startPolling()

        if let url = URL(string: "https://appstoreconnect.apple.com") {
            irisLog("ASCWebView: loading initial URL \(url)")
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: ASCWebView
        weak var webView: WKWebView?
        private var hasCapture = false
        private var pollTimer: Timer?

        init(parent: ASCWebView) {
            self.parent = parent
        }

        deinit {
            pollTimer?.invalidate()
        }

        // MARK: - Cookie Polling

        func startPolling() {
            irisLog("startPolling: starting 2s cookie poll timer")
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.pollCookies()
            }
        }

        private func pollCookies() {
            guard !hasCapture, let webView else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.hasCapture else { return }

                let hasMyacinfo = cookies.contains { $0.name == "myacinfo" }
                let url = webView.url?.absoluteString ?? "(nil)"
                irisLog("pollCookies: \(cookies.count) cookies, hasMyacinfo=\(hasMyacinfo), url=\(url)")

                guard hasMyacinfo else { return }

                irisLog("pollCookies: myacinfo detected! extracting cookies now")
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.extractCookies(from: webView)
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? "(nil)"
            irisLog("WKWebView: didStartProvisionalNavigation url=\(url)")
            DispatchQueue.main.async { self.parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? "(nil)"
            irisLog("WKWebView: didFinish url=\(url)")
            DispatchQueue.main.async { self.parent.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            irisLog("WKWebView: didFail error=\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            irisLog("WKWebView: didFailProvisionalNavigation error=\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString ?? "(nil)"
            irisLog("WKWebView: decidePolicyFor url=\(url)")
            decisionHandler(.allow)
        }

        // MARK: - Cookie Extraction

        private func extractCookies(from webView: WKWebView) {
            guard !hasCapture else {
                irisLog("extractCookies: already captured, skipping")
                return
            }
            hasCapture = true
            irisLog("extractCookies: starting extraction")

            // Fetch Apple ID email via synchronous XHR inside the WebView FIRST.
            // This call to /olympus/v1/session also establishes the full ASC session
            // and may set additional cookies (e.g. itctx, CSRF tokens) that are
            // required for iris API calls. We capture cookies AFTER this completes.
            let js = """
            (function() {
                try {
                    var xhr = new XMLHttpRequest();
                    xhr.open('GET', 'https://appstoreconnect.apple.com/olympus/v1/session', false);
                    xhr.setRequestHeader('Accept', 'application/json');
                    xhr.send();
                    if (xhr.status === 200) {
                        var j = JSON.parse(xhr.responseText);
                        return (j.user && j.user.emailAddress) || null;
                    }
                    return null;
                } catch(e) { return null; }
            })()
            """

            DispatchQueue.main.async {
                webView.evaluateJavaScript(js) { [weak self] result, error in
                    let email = result as? String
                    irisLog("extractCookies: fetched email=\(email ?? "nil") error=\(error?.localizedDescription ?? "none")")

                    // Now capture cookies AFTER the olympus session call,
                    // so we include any cookies set by that response.
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        let appleCookies = cookies.filter { $0.domain.contains("apple.com") }
                        irisLog("extractCookies: total cookies=\(cookies.count), apple.com cookies=\(appleCookies.count)")

                        for c in appleCookies {
                            irisLog("  cookie: \(c.name) domain=\(c.domain) path=\(c.path) value=\(String(c.value.prefix(20)))…")
                        }

                        let irisCookies = appleCookies.map { cookie in
                            IrisSession.IrisCookie(
                                name: cookie.name,
                                value: cookie.value,
                                domain: cookie.domain,
                                path: cookie.path
                            )
                        }

                        let session = IrisSession(
                            cookies: irisCookies,
                            email: email,
                            capturedAt: Date()
                        )

                        irisLog("extractCookies: created IrisSession with \(irisCookies.count) cookies, email=\(email ?? "nil"), calling onSessionCaptured")

                        self?.parent.onSessionCaptured(session)
                    }
                }
            }
        }
    }
}
