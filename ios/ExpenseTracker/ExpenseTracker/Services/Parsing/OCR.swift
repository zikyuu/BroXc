import Foundation
import Vision
import CoreGraphics
import UIKit

/// One recognised piece of text, with its box in image pixels (origin top-left).
struct OCRLine {
    var text: String
    var confidence: Double
    var box: CGRect
}

struct OCRResult {
    var lines: [OCRLine]
    var rawText: String { lines.map(\.text).joined(separator: "\n") }
    var averageConfidence: Double { lines.isEmpty ? 0 : lines.reduce(0) { $0 + $1.confidence } / Double(lines.count) }
}

/// On-device text recognition via Apple's Vision framework: free, offline, no model to ship.
enum VisionOCR {
    static func recognize(_ image: CGImage, languages: [String] = ["en-US"]) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                if let supported = try? request.supportedRecognitionLanguages() {
                    let wanted = languages.filter { want in supported.contains { $0.lowercased().hasPrefix(want.lowercased().prefix(2)) } }
                    let resolved = wanted.compactMap { want in supported.first { $0.lowercased() == want.lowercased() } ?? supported.first { $0.lowercased().hasPrefix(want.lowercased().prefix(2)) } }
                    if !resolved.isEmpty { request.recognitionLanguages = resolved }
                }
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let width = Double(image.width), height = Double(image.height)
                    let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        let b = observation.boundingBox   // normalised, origin bottom-left
                        return OCRLine(text: candidate.string, confidence: Double(candidate.confidence),
                                       box: CGRect(x: b.minX * width, y: (1 - b.maxY) * height, width: b.width * width, height: b.height * height))
                    }
                    continuation.resume(returning: OCRResult(lines: lines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum RowGrouping {
    /// Fraction of the median text-box height two boxes may differ by and still share a row.
    static let toleranceFactor = 0.3

    /// Clusters text boxes into visual lines by vertical position, each read left-to-right. The row's
    /// confidence is the minimum of its boxes' - a clear name next to a smudged price is a low-confidence row.
    static func rows(_ lines: [OCRLine], tolerance: Double? = nil) -> [(text: String, confidence: Double)] {
        let heights = lines.map { Double($0.box.height) }.sorted()
        let tol = tolerance ?? (heights.isEmpty ? 0 : toleranceFactor * heights[heights.count / 2])
        var rows: [[OCRLine]] = []
        for line in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let index = rows.firstIndex(where: { abs(Double($0[0].box.midY - line.box.midY)) <= tol }) { rows[index].append(line) }
            else { rows.append([line]) }
        }
        return rows.map { row in
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            return (sorted.map(\.text).joined(separator: " "), sorted.map(\.confidence).min() ?? 0)
        }
    }
}

enum ImageLoader {
    /// Decodes picked image data into an upright CGImage (camera photos carry an orientation flag that
    /// OCR would otherwise ignore).
    static func cgImage(from data: Data) -> CGImage? {
        guard let image = UIImage(data: data) else { return nil }
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(at: .zero) }.cgImage
    }

    /// Keeps the uploaded image on disk so a receipt's source path stays valid.
    static func store(_ data: Data) -> String? {
        let directory = URL.documentsDirectory.appending(path: "uploads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: UUID().uuidString + ".png")
        guard let png = UIImage(data: data)?.pngData() else { return nil }
        return (try? png.write(to: url)) != nil ? "uploads/" + url.lastPathComponent : nil
    }
}
