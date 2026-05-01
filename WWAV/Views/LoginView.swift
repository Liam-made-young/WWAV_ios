import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            theme.centerRadial.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 6) {
                    Text("wwav").wwavTitle(size: 56)
                    Text("sign in").wwavLabel(size: 11, tracking: 3)
                }

                VStack(spacing: 14) {
                    field("email") {
                        TextField("", text: $email,
                                  prompt: Text("you@domain").foregroundStyle(theme.muted))
                            .font(.wwav(18, weight: .light, italic: true))
                            .foregroundStyle(theme.ink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                    }
                    field("password") {
                        SecureField("", text: $password,
                                    prompt: Text("••••••••").foregroundStyle(theme.muted))
                            .font(.wwav(18, weight: .light, italic: true))
                            .foregroundStyle(theme.ink)
                            .textContentType(.password)
                    }

                    if let error = auth.error {
                        Text(error)
                            .font(.wwav(12, weight: .light, italic: true))
                            .foregroundStyle(Color.red.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        Task { await auth.login(email: email, password: password) }
                    } label: {
                        Group {
                            if auth.isLoading {
                                ProgressView().tint(theme.glow)
                            } else {
                                Text("sign in")
                                    .font(.wwav(15, weight: .regular, italic: true))
                                    .tracking(2)
                                    .foregroundStyle(theme.glow)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top, endPoint: .bottom
                            ))
                        )
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
                    .opacity((email.isEmpty || password.isEmpty || auth.isLoading) ? 0.6 : 1)

                    Link("create an account at mi-wwav.com",
                         destination: URL(string: "https://www.mi-wwav.com")!)
                        .font(.wwav(11, weight: .light, italic: true))
                        .tracking(1)
                        .foregroundStyle(theme.muted)
                }
                .frame(maxWidth: 320)

                Spacer()
            }
            .padding(.horizontal, 28)
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).wwavLabel(size: 10, tracking: 2)
            content()
                .padding(.vertical, 10)
                .overlay(
                    Rectangle()
                        .fill(theme.muted.opacity(0.3))
                        .frame(height: 1),
                    alignment: .bottom
                )
        }
    }
}
