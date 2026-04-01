//
//  Tone3000AuthView.swift
//  ConjureDSPExtension
//
//  WKWebView-based OAuth login for tone3000. Loads the external tone3000 login
//  page and intercepts the redirect to extract the per-user API key.
//
//  The AU extension has com.apple.security.network.client entitlement, so loading
//  external HTTPS URLs works (unlike Monaco/Terminal which only load local files).
//

import SwiftUI
import WebKit
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "Tone3000Auth")

struct Tone3000AuthView: View {
    let client: Tone3000Client
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to tone3000")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 12)
            }

            Tone3000WebView(
                url: Tone3000Client.authURL,
                isLoading: $isLoading,
                onApiKey: { apiKey in
                    Task {
                        do {
                            try await client.exchangeUserApiKey(apiKey)
                            onSuccess()
                        } catch {
                            self.error = error.localizedDescription
                            log.error("Auth exchange failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            )
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
        }
        .frame(width: 420, height: 520)
    }
}

// MARK: - WKWebView wrapper

private struct Tone3000WebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    let onApiKey: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, onApiKey: onApiKey)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        let onApiKey: (String) -> Void

        init(isLoading: Binding<Bool>, onApiKey: @escaping (String) -> Void) {
            _isLoading = isLoading
            self.onApiKey = onApiKey
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Intercept the redirect to conjuredsp://tone3000-auth?api_key=...
            if url.scheme == "conjuredsp" && url.host == "tone3000-auth" {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let apiKey = components.queryItems?.first(where: { $0.name == "api_key" })?.value {
                    log.info("Received tone3000 API key from redirect")
                    onApiKey(apiKey)
                } else {
                    log.error("tone3000 redirect missing api_key parameter")
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }
    }
}
