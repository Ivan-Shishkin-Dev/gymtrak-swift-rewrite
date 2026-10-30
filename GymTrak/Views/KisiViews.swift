import SwiftUI
import WebKit

/// "Unlock Door" under Start Workout. Before Kisi is set up, it opens the sign-in instead.
struct DoorButton: View {
    @State private var kisi = Kisi.shared
    @Environment(AppNav.self) private var nav
    @State private var opened = 0

    var body: some View {
        let ready = kisi.signedIn && kisi.door != nil
        Button {
            if ready { Task { if await kisi.unlock() { opened += 1 } } } else { nav.showKisi = true }
        } label: {
            HStack(spacing: 8) {
                if kisi.phase == .working {
                    ProgressView().tint(Page.text)
                } else {
                    Image(systemName: kisi.phase == .open ? "lock.open.fill" : "lock.fill")
                }
                Text(kisi.phase == .open ? "Door Open" : "Unlock Door")
            }
            .font(.headline)
            .frame(maxWidth: .infinity).frame(height: 44)
            .foregroundStyle(kisi.phase == .open ? Theme.lift : Page.text)
            .background(Page.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: opened)
        .alert("Door didn't open", isPresented: Binding(get: { ready && kisi.error != nil && !nav.showKisi },
                                                        set: { if !$0 { kisi.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(kisi.error ?? "")
        }
    }
}

/// Kisi sign-in and which door to open. In Settings → Connections, and from the door button.
struct KisiSetupView: View {
    @State private var kisi = Kisi.shared
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var method = Method.domain
    @State private var domain = Kisi.shared.lastDomain
    @State private var webLogin: URL?
    @State private var failed = 0
    @State private var succeeded = 0

    var body: some View {
        Form {
            // The result, at the top so it's visible above the keyboard.
            if let error = kisi.error {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kisi.signedIn ? "Something went wrong" : "Couldn't sign in").font(.headline)
                            Text(error).font(.subheadline)
                        }
                    } icon: {
                        Image(systemName: "xmark.octagon.fill").font(.title2)
                    }
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.red.opacity(0.15))
            }
            if kisi.signedIn {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed in").font(.headline)
                            Text([kisi.account, kisi.door?.name].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(Page.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.green.opacity(0.15))
                Section {
                    if kisi.doors.isEmpty {
                        Text(kisi.door?.name ?? "No doors yet").foregroundStyle(.secondary)
                    }
                    ForEach(kisi.doors) { door in
                        Button { kisi.choose(door) } label: {
                            HStack {
                                Text(door.name).foregroundStyle(Page.text)
                                Spacer()
                                if kisi.door?.id == door.id { Image(systemName: "checkmark").foregroundStyle(Theme.lift) }
                            }
                        }
                    }
                } header: { Text("Door") }
                Section {
                    Button("Sign Out of Kisi", role: .destructive) { kisi.signOut() }
                }
            } else {
                Section {
                    Picker("Sign in with", selection: $method) {
                        ForEach(Method.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if method == .domain {
                    Section {
                        TextField("Organization domain", text: $domain)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.go).onSubmit(openDomain)
                    } footer: {
                        Text("The domain you type in the Kisi app after your email. You'll sign in on your organization's page.")
                    }
                    Section {
                        Button(action: openDomain) {
                            HStack { Text("Continue"); Spacer(); if busy { ProgressView() } }
                        }
                        .disabled(busy || domain.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                        .submitLabel(.go).onSubmit(signIn)
                    if kisi.needsCode {
                        TextField("Code", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                    }
                } footer: {
                    Text("The email and password you use in the Kisi app. If you sign in to Kisi with a link or Google, set a password there first (Forgot password). Only Kisi's sign-in token is kept, in the Keychain.")
                }
                Section {
                    Button(action: signIn) {
                        HStack { Text("Sign In"); Spacer(); if busy { ProgressView() } }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
                }
            }
        }
        .animation(.snappy, value: kisi.signedIn)
        .animation(.snappy, value: kisi.error)
        .sheet(item: $webLogin) { url in
            NavigationStack {
                KisiWebLogin(url: url) { result in
                    webLogin = nil
                    Task { await finishDomain(result) }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(domain)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { webLogin = nil } } }
            }
        }
        .sensoryFeedback(.error, trigger: failed)
        .sensoryFeedback(.success, trigger: succeeded)
        .pageBackground()
        .navigationTitle("Kisi")
        .navigationBarTitleDisplayMode(.inline)
        .task { if kisi.signedIn { await kisi.loadDoors() } }
    }

    enum Method: String, CaseIterable { case domain = "Domain", password = "Password" }

    private func openDomain() {
        let d = domain.trimmingCharacters(in: .whitespaces)
        guard !busy, let url = Kisi.ssoURL(domain: d) else { return }
        kisi.error = nil
        kisi.lastDomain = d
        webLogin = url
    }

    private func finishDomain(_ result: KisiWebLogin.Result) async {
        switch result {
        case .code(let code):
            busy = true
            await kisi.resolve(code: code, domain: domain.trimmingCharacters(in: .whitespaces))
            busy = false
            if kisi.signedIn { succeeded += 1 } else { failed += 1 }
        case .failed(let message):
            kisi.error = message
            failed += 1
        }
    }

    private func signIn() {
        guard !busy, !email.isEmpty, !password.isEmpty else { return }
        busy = true
        Task {
            await kisi.signIn(email: email, password: password, code: code)
            busy = false
            if kisi.signedIn {
                password = ""
                succeeded += 1
            } else {
                failed += 1                  // keep the password so you can fix a typo
            }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// Your organization's Kisi sign-in page. When Kisi sends the browser back to its web app with
/// `auth_code`, that code is handed over instead of loading the page.
struct KisiWebLogin: UIViewRepresentable {
    enum Result { case code(String), failed(String) }

    let url: URL
    let done: (Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        // Some sign-in pages (Google) refuse in-app browsers; present as Safari.
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let done: (Result) -> Void
        private var finished = false

        init(done: @escaping (Result) -> Void) { self.done = done }

        /// True when this URL is Kisi's hand-back: a code, or an error message.
        private func check(_ url: URL?) -> Bool {
            guard !finished, let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
            if let code = items.first(where: { $0.name == "auth_code" })?.value, !code.isEmpty {
                finished = true
                done(.code(code))
                return true
            }
            if url.host == "web.kisi.io", items.contains(where: { $0.name == "error" && $0.value == "true" }) {
                finished = true
                let message = items.first { $0.name == "message" }?.value ?? "Kisi didn't accept that domain."
                done(.failed(message == "Invalid SAML settings" ? "That domain isn't set up for sign-in. Check the spelling." : message))
                return true
            }
            return false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(check(navigationAction.request.url) ? .cancel : .allow)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if check(webView.url) { webView.stopLoading() }
        }
    }
}
