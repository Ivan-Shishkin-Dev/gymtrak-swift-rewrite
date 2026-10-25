import SwiftUI

/// Signed-out screen: type your email, tap the link it sends.
struct SignInView: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var email = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.lift.mix(with: .white, by: 0.15), Theme.lift.mix(with: .black, by: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                Image("Logo").resizable().frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                Text("GymTrak").font(.largeTitle.bold()).foregroundStyle(.white)
                Spacer()

                VStack(spacing: 14) {
                    if case .linkSent(let sentTo) = store.signIn {
                        sent(sentTo)
                    } else {
                        form
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .animation(.snappy, value: store.signIn)
    }

    private var form: some View {
        VStack(spacing: 14) {
            Text("Sign in").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16).frame(height: 52)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button(action: send) {
                Group {
                    if sending { ProgressView().tint(.white) } else { Text("Email Me a Link") }
                }
                .font(.headline).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.lift)
            .opacity(email.contains("@") ? 1 : 0.45)
            .allowsHitTesting(email.contains("@") && !sending)
            if case .error(let message) = store.syncStatus {
                Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private func sent(_ address: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge.fill").font(.system(size: 44)).foregroundStyle(Theme.lift)
                .symbolEffect(.bounce, options: .repeat(2))
            Text("Check your email").font(.title2.bold())
            Text("Tap the link sent to **\(address)** on this phone.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button {
                openURL(URL(string: "message://")!)
            } label: {
                Text("Open Mail").font(.headline).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.lift)
            Button("Use a Different Email") { store.cancelLink() }.font(.subheadline)
        }
    }

    private func send() {
        guard email.contains("@") else { return }
        sending = true
        Task {
            await store.sendLink(to: email)
            sending = false
        }
    }
}

#Preview { SignInView().environment(Store(seedIfEmpty: true)) }
