import SwiftUI

struct SwipePhotoReviewView: View {
    let groupID: String
    let model: NeatbyteModel

    @State private var currentIndex = 0
    @State private var dragOffset: CGSize = .zero
    @State private var history: [(id: String, wasSelected: Bool)] = []

    private var group: PhotoGroup? {
        model.photoGroups.first { $0.id == groupID }
    }

    var body: some View {
        VStack(spacing: 18) {
            if let group, currentIndex < group.members.count {
                let photo = group.members[currentIndex]

                Text("\(currentIndex + 1) of \(group.members.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.secondary.opacity(0.12))

                    PhotoAssetImage(
                        identifier: photo.id,
                        photoLibrary: model.photoLibrary,
                        targetSize: CGSize(width: 1200, height: 1200),
                        contentMode: .fit
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24))

                    SwipeDecisionOverlay(offset: dragOffset)
                }
                .offset(dragOffset)
                .rotationEffect(.degrees(Double(dragOffset.width / 24)))
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { finishDrag($0.translation, photoID: photo.id) }
                )
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: dragOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 34) {
                    SwipeActionButton(
                        title: "Delete",
                        systemImage: "trash.fill",
                        color: .red
                    ) {
                        decide(delete: true, photoID: photo.id)
                    }

                    SwipeActionButton(
                        title: "Keep",
                        systemImage: "heart.fill",
                        color: .green
                    ) {
                        decide(delete: false, photoID: photo.id)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Group reviewed", systemImage: "checkmark.circle.fill")
                } description: {
                    Text("\(model.selectedIDs.count) items are currently selected for final review.")
                } actions: {
                    if !model.selectedIDs.isEmpty {
                        NavigationLink("Review selected items") {
                            CleanupReviewView(model: model)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Swipe Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    undo()
                }
                .disabled(history.isEmpty)
            }
        }
    }

    private func finishDrag(_ translation: CGSize, photoID: String) {
        if translation.width < -90 {
            decide(delete: true, photoID: photoID)
        } else if translation.width > 90 {
            decide(delete: false, photoID: photoID)
        } else {
            dragOffset = .zero
        }
    }

    private func decide(delete: Bool, photoID: String) {
        history.append((photoID, model.selectedIDs.contains(photoID)))
        dragOffset = CGSize(width: delete ? -500 : 500, height: 0)

        Task {
            try? await Task.sleep(for: .milliseconds(180))
            model.setDeletionSelection(delete, for: photoID)
            currentIndex += 1
            dragOffset = .zero
        }
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        model.setDeletionSelection(previous.wasSelected, for: previous.id)
        currentIndex = max(0, currentIndex - 1)
        dragOffset = .zero
    }
}

struct SwipeDecisionOverlay: View {
    let offset: CGSize

    var body: some View {
        if abs(offset.width) > 25 {
            Label(
                offset.width > 0 ? "KEEP" : "DELETE",
                systemImage: offset.width > 0 ? "heart.fill" : "trash.fill"
            )
            .font(.title.bold())
            .foregroundStyle(offset.width > 0 ? .green : .red)
            .padding(14)
            .background(.ultraThinMaterial, in: Capsule())
            .opacity(min(1, abs(offset.width) / 100))
        }
    }
}

struct SwipeActionButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.caption.bold())
            }
            .frame(width: 74, height: 60)
        }
        .buttonStyle(.bordered)
        .tint(color)
        .accessibilityLabel(title)
    }
}
