import SwiftUI

/// Reports completion from the same SwiftUI animation transaction that renders
/// a workspace transition. The model rejects stale revisions, so an older
/// completion can never settle a newer presentation.
struct WorkspaceAnimationCompletionObserver: AnimatableModifier {
    let targetRevision: UInt64
    let completion: @MainActor (UInt64) -> Void

    var animatableData: Double {
        didSet {
            guard abs(animatableData - Double(targetRevision)) < 0.000_001 else { return }
            let revision = targetRevision
            let completion = completion
            DispatchQueue.main.async {
                completion(revision)
            }
        }
    }

    init(
        revision: UInt64,
        completion: @escaping @MainActor (UInt64) -> Void
    ) {
        targetRevision = revision
        animatableData = Double(revision)
        self.completion = completion
    }

    func body(content: Content) -> some View {
        content
    }
}
