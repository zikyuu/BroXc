import SwiftUI
import Translation
import VisionKit

// MARK: - On-device translation

/// A batch of text waiting for the translator. Apple's Translation framework can only be driven from inside a view
/// (`.translationTask`), so a screen hands the text over as one of these and awaits the answer.
/// What came back from the translator: the translations, or the reason there are none.
struct TranslationOutcome: Sendable {
    var texts: [String]?
    var problem: String?
    static func failed(_ problem: String) -> TranslationOutcome { TranslationOutcome(texts: nil, problem: problem) }
}

final class PendingTranslation: Identifiable, @unchecked Sendable {
    let id = UUID()
    let texts: [String]
    private var continuation: CheckedContinuation<TranslationOutcome, Never>?
    init(texts: [String], continuation: CheckedContinuation<TranslationOutcome, Never>) {
        self.texts = texts
        self.continuation = continuation
    }
    /// Answers the waiting screen exactly once; later calls (a timeout after success, say) do nothing.
    func finish(_ outcome: TranslationOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

extension View {
    /// Lets this screen translate Swedish to English on the phone. Before iOS 18 there's no translator, and the
    /// screen's `translate` call simply gets nil, so names stay as printed.
    @ViewBuilder
    func translationHost(_ pending: Binding<PendingTranslation?>) -> some View {
        if #available(iOS 18.0, *) { modifier(TranslationHost(pending: pending)) } else { self }
    }
}

@available(iOS 18.0, *)
private struct TranslationHost: ViewModifier {
    @Binding var pending: PendingTranslation?
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: pending?.id) { _, id in
                configuration = id == nil ? nil : TranslationSession.Configuration(source: Locale.Language(identifier: "sv"),
                                                                                    target: Locale.Language(identifier: "en"))
            }
            .translationTask(configuration) { session in
                guard let job = pending else { return }
                do {
                    let requests = job.texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                    let responses = try await session.translations(from: requests)
                    var ordered = job.texts   // anything the translator skips stays as it was
                    for response in responses {
                        if let id = response.clientIdentifier, let index = Int(id), ordered.indices.contains(index) { ordered[index] = response.targetText }
                    }
                    job.finish(TranslationOutcome(texts: ordered, problem: nil))
                } catch {
                    job.finish(.failed("The translator reported: \(error.localizedDescription) [\(String(describing: type(of: error)))]"))
                }
                pending = nil
            }
    }
}

/// Awaits a translation through `pending`, which the screen's `translationHost` is watching. Always answers - with the
/// translations, or with the specific reason there are none - rather than hanging or failing silently.
@MainActor
func translateOnDevice(_ texts: [String], via pending: Binding<PendingTranslation?>) async -> TranslationOutcome {
    guard !texts.isEmpty else { return .failed("There was nothing to translate.") }
    guard #available(iOS 18.0, *) else {
        return .failed("Translation needs iOS 18 or later (this phone has iOS \(UIDevice.current.systemVersion)).")
    }
    // ask first: where the pair can't be translated at all (the simulator, an unsupported device) there's nothing to
    // wait for. "supported" just means the language still has to be downloaded, which the system will offer.
    let status = await LanguageAvailability().status(from: Locale.Language(identifier: "sv"), to: Locale.Language(identifier: "en"))
    if status == .unsupported { return .failed("Apple’s translator doesn’t offer Swedish to English on this device (iOS \(UIDevice.current.systemVersion)).") }
    return await withCheckedContinuation { continuation in
        let job = PendingTranslation(texts: texts, continuation: continuation)
        pending.wrappedValue = job
        Task { try? await Task.sleep(for: .seconds(180)); job.finish(.failed("Timed out after 3 minutes. If a language download prompt appeared, it needs to be accepted.")) }
    }
}

// MARK: - Camera scanning

/// Apple's document camera: finds the paper, flattens the perspective and evens out the light - exactly what a
/// crumpled, skewed receipt photo needs before reading. Several pages (a long receipt) are stacked into one image.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: (UIImage) -> Void
    let onCancel: () -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            if let image = Coordinator.stacked(pages) { parent.onScan(image) } else { parent.onCancel() }
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.onCancel() }

        /// Pages top to bottom, scaled to one width.
        static func stacked(_ pages: [UIImage]) -> UIImage? {
            guard let first = pages.first else { return nil }
            if pages.count == 1 { return first }
            let width = pages.map(\.size.width).max() ?? first.size.width
            let heights = pages.map { $0.size.height * width / $0.size.width }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: heights.reduce(0, +)))
            return renderer.image { _ in
                var y: CGFloat = 0
                for (page, height) in zip(pages, heights) { page.draw(in: CGRect(x: 0, y: y, width: width, height: height)); y += height }
            }
        }
    }
}
