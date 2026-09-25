import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit

enum BlurConfidence: Int, Comparable, Sendable {
    case possible
    case veryLikely

    static func < (lhs: BlurConfidence, rhs: BlurConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .possible: "Possibly blurry"
        case .veryLikely: "Very likely blurry"
        }
    }

    var systemImage: String {
        switch self {
        case .possible: "questionmark.circle.fill"
        case .veryLikely: "exclamationmark.triangle.fill"
        }
    }
}

struct BlurAnalysis: Sendable {
    let sharpnessScore: Double
    let confidence: BlurConfidence?
}

struct BlurryPhotoResult: Identifiable, Equatable {
    let photo: PhotoCandidate
    let sharpnessScore: Double
    let confidence: BlurConfidence

    var id: String { photo.id }
}

actor BlurAnalyzer {
    func analyze(imageData: Data) throws -> BlurAnalysis {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let maxDimension = 256
        let scale = min(
            Double(maxDimension) / Double(cgImage.width),
            Double(maxDimension) / Double(cgImage.height),
            1
        )
        let width = max(3, Int(Double(cgImage.width) * scale))
        let height = max(3, Int(Double(cgImage.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw CocoaError(.coderInvalidValue)
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let luminance = luminanceStatistics(pixels)

        // Very dark or nearly featureless images cannot be classified reliably.
        guard luminance.mean >= 30,
              luminance.mean <= 235,
              luminance.standardDeviation >= 14 else {
            return BlurAnalysis(sharpnessScore: 0, confidence: nil)
        }

        let centerRect = PixelRect(
            minX: width / 4,
            maxX: width * 3 / 4,
            minY: height / 4,
            maxY: height * 3 / 4
        )
        let centerSharpness = laplacianVariance(
            pixels: pixels,
            width: width,
            rect: centerRect
        )

        var regionalScores: [Double] = []
        for row in 0..<3 {
            for column in 0..<3 {
                let rect = PixelRect(
                    minX: column * width / 3,
                    maxX: (column + 1) * width / 3,
                    minY: row * height / 3,
                    maxY: (row + 1) * height / 3
                )
                regionalScores.append(
                    laplacianVariance(pixels: pixels, width: width, rect: rect)
                )
            }
        }

        regionalScores.sort()
        let upperRegionalScore = regionalScores[regionalScores.count * 3 / 4]
        let focusScore = centerSharpness * 0.65 + upperRegionalScore * 0.35

        let confidence: BlurConfidence?
        if focusScore < 55, centerSharpness < 65, upperRegionalScore < 90 {
            confidence = .veryLikely
        } else if focusScore < 90, centerSharpness < 105, upperRegionalScore < 140 {
            confidence = .possible
        } else {
            confidence = nil
        }

        return BlurAnalysis(sharpnessScore: focusScore, confidence: confidence)
    }

    private func luminanceStatistics(_ pixels: [UInt8]) -> (mean: Double, standardDeviation: Double) {
        guard !pixels.isEmpty else { return (0, 0) }
        let count = Double(pixels.count)
        let total = pixels.reduce(0.0) { $0 + Double($1) }
        let mean = total / count
        let squaredDifference = pixels.reduce(0.0) { partialResult, pixel in
            let difference = Double(pixel) - mean
            return partialResult + difference * difference
        }
        return (mean, sqrt(squaredDifference / count))
    }

    private func laplacianVariance(
        pixels: [UInt8],
        width: Int,
        rect: PixelRect
    ) -> Double {
        let minX = max(1, rect.minX)
        let maxX = min(width - 1, rect.maxX)
        let height = pixels.count / width
        let minY = max(1, rect.minY)
        let maxY = min(height - 1, rect.maxY)
        guard minX < maxX, minY < maxY else { return 0 }

        var total = 0.0
        var totalSquared = 0.0
        var count = 0

        for y in minY..<maxY {
            for x in minX..<maxX {
                let center = Int(pixels[y * width + x])
                let laplacian = Double(
                    4 * center
                    - Int(pixels[y * width + x - 1])
                    - Int(pixels[y * width + x + 1])
                    - Int(pixels[(y - 1) * width + x])
                    - Int(pixels[(y + 1) * width + x])
                )
                total += laplacian
                totalSquared += laplacian * laplacian
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = total / Double(count)
        return max(0, totalSquared / Double(count) - mean * mean)
    }
}

private struct PixelRect: Sendable {
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int
}

@MainActor
@Observable
final class BlurryPhotosModel {
    private(set) var results: [BlurryPhotoResult] = []
    private(set) var isScanning = false
    private(set) var completed = 0
    private(set) var total = 0
    var errorMessage: String?

    private let analyzer = BlurAnalyzer()
    private var scanTask: Task<Void, Never>?

    func scan(photoLibrary: PhotoLibraryService) {
        guard !isScanning else { return }
        scanTask?.cancel()
        results = []
        completed = 0
        let candidates = photoLibrary.fetchPhotoCandidates()
        total = candidates.count
        isScanning = true

        scanTask = Task {
            var matches: [BlurryPhotoResult] = []

            for candidate in candidates {
                guard !Task.isCancelled else { break }
                do {
                    let data = try await photoLibrary.requestAnalysisData(identifier: candidate.id)
                    let analysis = try await analyzer.analyze(imageData: data)
                    if let confidence = analysis.confidence {
                        matches.append(
                            BlurryPhotoResult(
                                photo: candidate,
                                sharpnessScore: analysis.sharpnessScore,
                                confidence: confidence
                            )
                        )
                    }
                } catch {
                    // iCloud-only items are skipped instead of downloading private media.
                }
                completed += 1
            }

            if !Task.isCancelled {
                results = matches.sorted {
                    if $0.confidence != $1.confidence {
                        return $0.confidence > $1.confidence
                    }
                    return $0.sharpnessScore < $1.sharpnessScore
                }
            }
            isScanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}

struct BlurryPhotosCategoryCard: View {
    let model: NeatbyteModel

    var body: some View {
        NavigationLink {
            BlurryPhotosView(appModel: model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera.filters")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.pink.gradient, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Blurry Photos")
                        .font(.headline)
                    Text("Detect likely blur on device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

struct BlurryPhotosView: View {
    let appModel: NeatbyteModel
    @State private var model = BlurryPhotosModel()

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            BlurryPhotosExplanation()

            if model.isScanning {
                VStack(spacing: 8) {
                    ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                    HStack {
                        Text("Analyzing \(model.completed) of \(model.total)")
                            .font(.caption)
                        Spacer()
                        Button("Cancel", action: model.cancel)
                    }
                }
                .padding()
            }

            if model.results.isEmpty, !model.isScanning {
                ContentUnavailableView {
                    Label("Scan for blurry photos", systemImage: "camera.filters")
                } description: {
                    Text("Neatbyte checks the subject area, surrounding regions, brightness, and contrast. Results are never selected automatically.")
                } actions: {
                    Button("Start Scan") {
                        model.scan(photoLibrary: appModel.photoLibrary)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.results) { result in
                            BlurryPhotoTile(
                                result: result,
                                isSelected: appModel.selectedIDs.contains(result.id),
                                photoLibrary: appModel.photoLibrary
                            ) {
                                appModel.toggleSelection(for: result.id)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Blurry Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.isScanning, !model.results.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rescan") {
                        model.scan(photoLibrary: appModel.photoLibrary)
                    }
                }
            }
        }
        .onChange(of: model.results) { _, results in
            appModel.registerBlurryPhotos(results.map(\.photo))
        }
        .safeAreaInset(edge: .bottom) {
            if !appModel.selectedIDs.isEmpty {
                ReviewBar(model: appModel)
            }
        }
        .onDisappear {
            if model.isScanning { model.cancel() }
        }
    }
}

struct BlurryPhotosExplanation: View {
    var body: some View {
        Label(
            "On-device analysis shows only likely blur and skips photos that are too dark to judge reliably. Review every result before deleting.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding()
        .background(.pink.opacity(0.08))
    }
}

struct BlurryPhotoTile: View {
    let result: BlurryPhotoResult
    let isSelected: Bool
    let photoLibrary: PhotoLibraryService
    let toggleSelection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { proxy in
                    PhotoAssetImage(
                        identifier: result.id,
                        photoLibrary: photoLibrary,
                        targetSize: CGSize(width: 420, height: 420)
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .aspectRatio(1, contentMode: .fit)

                Button(action: toggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? .red : .white)
                        .padding(7)
                }
                .accessibilityLabel(isSelected ? "Deselect blurry photo" : "Select blurry photo")
            }

            Label(result.confidence.title, systemImage: result.confidence.systemImage)
                .font(.caption.bold())
                .foregroundStyle(result.confidence == .veryLikely ? .red : .orange)
            Text("Confidence is an estimate—review before deleting")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
