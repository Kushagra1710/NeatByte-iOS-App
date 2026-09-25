import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit

struct BlurryPhotoResult: Identifiable, Equatable {
    let photo: PhotoCandidate
    let sharpnessScore: Double

    var id: String { photo.id }
}

actor BlurAnalyzer {
    func sharpnessScore(imageData: Data) throws -> Double {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let maxDimension = 180
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

        var total = 0.0
        var totalSquared = 0.0
        var count = 0

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
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
                    let score = try await analyzer.sharpnessScore(imageData: data)
                    // A deliberately conservative threshold to reduce false positives.
                    if score < 95 {
                        matches.append(
                            BlurryPhotoResult(
                                photo: candidate,
                                sharpnessScore: score
                            )
                        )
                    }
                } catch {
                    // iCloud-only items are skipped instead of downloading private media.
                }
                completed += 1
            }

            if !Task.isCancelled {
                results = matches.sorted { $0.sharpnessScore < $1.sharpnessScore }
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
                    Text("Neatbyte uses a conservative sharpness score. Always review results before deleting.")
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
            "Likely blur—not guaranteed. Low edge detail can also occur in intentionally soft or dark photos.",
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
                PhotoAssetImage(
                    identifier: result.id,
                    photoLibrary: photoLibrary,
                    targetSize: CGSize(width: 420, height: 420)
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Button(action: toggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? .red : .white)
                        .padding(7)
                }
                .accessibilityLabel(isSelected ? "Deselect blurry photo" : "Select blurry photo")
            }

            Text("Sharpness: \(result.sharpnessScore, format: .number.precision(.fractionLength(0)))")
                .font(.caption.bold())
            Text("Review before deleting")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
