import SwiftUI

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

    var body: some View {
        Form {
            if kisi.signedIn {
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
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    if kisi.needsCode {
                        TextField("Code", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                    }
                } footer: {
                    Text("The email and password you use in the Kisi app. If you sign in to Kisi with a link or Google, set a password there first (Forgot password). Only Kisi's sign-in token is kept, in the Keychain.")
                }
                Section {
                    Button {
                        busy = true
                        Task {
                            await kisi.signIn(email: email, password: password, code: code)
                            busy = false
                            if kisi.signedIn { password = "" }   // keep it after a failed try, so you can fix a typo
                        }
                    } label: {
                        HStack { Text("Sign In"); Spacer(); if busy { ProgressView() } }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
            }
            if let error = kisi.error {
                Text(error).font(.footnote).foregroundStyle(Theme.warning)
            }
        }
        .pageBackground()
        .navigationTitle("Kisi")
        .navigationBarTitleDisplayMode(.inline)
        .task { if kisi.signedIn { await kisi.loadDoors() } }
    }
}
