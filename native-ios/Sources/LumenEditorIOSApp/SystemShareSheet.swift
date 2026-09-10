import SwiftUI
import UIKit

struct SystemShareSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let completion: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL], applicationActivities: nil
        )
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { [weak coordinator] _, _, _, _ in
            DispatchQueue.main.async { coordinator?.completeOnce() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    final class Coordinator {
        private let completion: () -> Void
        private var completed = false

        init(completion: @escaping () -> Void) { self.completion = completion }

        func completeOnce() {
            guard !completed else { return }
            completed = true
            completion()
        }
    }
}
