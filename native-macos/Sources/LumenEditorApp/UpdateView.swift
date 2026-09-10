import SwiftUI

struct UpdateReleaseConfirmationPresentation: Equatable {
    let title: String
    let confirmAction: String
    let cancelAction: String
    let message: String

    init(confirmation: UpdateReleaseConfirmation, locale: EditorLocale) {
        title = locale.text("Open Release Page?", zh: "打开发布页面？")
        confirmAction = locale.text("Open Release Page", zh: "打开发布页面")
        cancelAction = locale.text("Cancel", zh: "取消")
        message = locale.text(
            "Open the release page in your default browser to download the signed installer?\n\n"
                + (confirmation.releaseURL?.absoluteString ?? ""),
            zh: "要在默认浏览器中打开发布页面以下载签名安装包吗？\n\n"
                + (confirmation.releaseURL?.absoluteString ?? "")
        )
    }
}

struct UpdateView: View {
    @ObservedObject var controller: UpdateController
    let onDismiss: () -> Void
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(l("Software Update", "软件更新"))
                    .font(.headline)
                Spacer()
                Button(l("Done", "完成"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("panel.update.done")
            }

            if controller.isChecking {
                HStack(spacing: 10) {
                    ProgressView()
                        .accessibilityLabel(l("Checking for updates", "正在检查更新"))
                    Text(l("Checking for updates…", "正在检查更新…"))
                }
            } else if let issue = controller.issue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appLocale.localizedApp(issue.titleContent)).font(.headline)
                    Text(appLocale.localizedPresentation(issue.content))
                        .foregroundStyle(.secondary)
                    Button(l("Try Again", "重试")) { Task { await controller.retry() } }
                        .accessibilityIdentifier("panel.update.retry")
                }
            } else if let result = controller.result {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.isAvailable
                        ? l("A newer version is available.", "有新版本可用。")
                        : l("Lumen Editor is up to date.", "Lumen Editor 已是最新版本。"))
                        .font(.headline)
                    Text(l(
                        "Current version: \(result.currentVersion)",
                        "当前版本：\(result.currentVersion)"
                    ))
                    if let latest = result.latestVersion {
                        Text(l("Latest version: \(latest)", "最新版本：\(latest)"))
                    }
                    if result.isAvailable, result.releaseURL != nil {
                        Button(l("Open Release Page", "打开发布页面")) {
                            controller.requestOpenReleasePage()
                        }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("panel.update.openRelease")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(minWidth: 420, minHeight: 210)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("Software Update", "软件更新"))
        .accessibilityIdentifier("panel.update")
        .onExitCommand(perform: dismiss)
        .confirmationDialog(
            releaseConfirmationPresentation?.title ?? "",
            isPresented: releaseConfirmationBinding,
            presenting: controller.pendingReleaseConfirmation
        ) { confirmation in
            let presentation = UpdateReleaseConfirmationPresentation(
                confirmation: confirmation, locale: appLocale
            )
            Button(presentation.confirmAction) {
                _ = controller.confirmOpenReleasePage()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(Accessibility.confirmOpenRelease)
            Button(presentation.cancelAction, role: .cancel) {
                controller.cancelOpenReleasePage()
            }
            .accessibilityIdentifier(Accessibility.cancelOpenRelease)
        } message: { confirmation in
            Text(UpdateReleaseConfirmationPresentation(
                confirmation: confirmation, locale: appLocale
            ).message)
        }
    }

    private func dismiss() {
        controller.dismiss()
        onDismiss()
    }

    private var releaseConfirmationBinding: Binding<Bool> {
        Binding(
            get: { controller.pendingReleaseConfirmation != nil },
            set: { if !$0 { controller.cancelOpenReleasePage() } }
        )
    }

    private var releaseConfirmationPresentation: UpdateReleaseConfirmationPresentation? {
        controller.pendingReleaseConfirmation.map {
            UpdateReleaseConfirmationPresentation(confirmation: $0, locale: appLocale)
        }
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }

    enum Accessibility {
        static let confirmOpenRelease = "panel.update.confirmOpenRelease"
        static let cancelOpenRelease = "panel.update.cancelOpenRelease"
    }
}
