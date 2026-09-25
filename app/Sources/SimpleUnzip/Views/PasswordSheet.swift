import SwiftUI

/// Asks for the password of an archive whose *file names* are encrypted.
///
/// `7zz -mhe=on` archives produce no listing at all without the password, so
/// there is nothing to browse and nothing to extract until it is supplied. The
/// catch-all alert used to announce "需要密码" and then leave the user with no
/// field to type it in.
struct PasswordSheet: View {
    @EnvironmentObject private var model: AppModel
    let prompt: PasswordPrompt

    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear { isPasswordFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("需要密码")
                    .font(.headline)
                Text(prompt.archive.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledField(title: "密码") {
                SecureField("密码", text: $model.passwordInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($isPasswordFocused)
                    .onSubmit { model.submitPassword() }
            }

            Text("密码仅用于本次打开，不会被保存。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("取消") { model.cancelPasswordEntry() }
                .keyboardShortcut(.cancelAction)
            Button("打开") { model.submitPassword() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.passwordInput.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
