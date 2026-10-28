import SwiftUI
import PhotosUI
import UIKit

// Photos in the room's composer (`images-v1`): the photo button, the thumbnails waiting to go, and the chip
// on a message that carried photos. Plain views over the pure values in `Models/PhotoMessages.swift`; the
// container loads, re-encodes and sends, and routes every closure.

// MARK: - The photo button

/// Shown only when the Mac says it takes photos and the row has a way for them to reach the session. While the
/// session works or waits it stays tappable but dim: tapping says why, so the reason is never hidden.
struct NWPhotoButton: View {
    var offer: PhotoOffer
    /// How many more photos may be added.
    var slots: Int
    var onPick: ([PhotosPickerItem]) -> Void
    var onBlocked: (String) -> Void
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        if offer.isAvailable && slots > 0 {
            PhotosPicker(selection: $picked, maxSelectionCount: slots, matching: .images, photoLibrary: .shared()) { glyph(dim: false) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add photo"))
                .onChange(of: picked) { _, items in
                    guard !items.isEmpty else { return }
                    onPick(items)
                    picked = []
                }
        } else if offer.showsButton {
            let why = offer.isAvailable ? "You can add up to \(PhotoLimits.maxPhotos) photos." : (offer.reason ?? "")
            Button { onBlocked(why) } label: { glyph(dim: true) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add photo"))
                .accessibilityValue(Text("Unavailable"))
                .accessibilityHint(Text(why))
        }
    }

    private func glyph(dim: Bool) -> some View {
        Image(systemName: "photo.badge.plus").font(.system(.body, weight: .medium))
            .foregroundColor((dim ? NightWatch.Palette.textQuiet : NightWatch.Palette.textSecondary).color)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.white.opacity(dim ? 0.05 : 0.10)))
            .contentShape(Circle())
    }
}

// MARK: - The thumbnails

/// The photos waiting in the composer, each with its ×. A photo still being re-encoded shows a spinner; Send
/// waits for it.
struct NWPhotoStrip: View {
    var items: [PhotoDraftItem]
    var onRemove: (String) -> Void

    static let side: CGFloat = 64

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in thumb(item, index: i) }
            }
            // Room for each × to hang over its corner without being clipped.
            .padding(.top, 10).padding(.trailing, 10).padding(.leading, 2)
        }
        .accessibilityElement(children: .contain)
    }

    private func thumb(_ item: PhotoDraftItem, index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08))
            if let data = item.photo?.thumb, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: Self.side, height: Self.side).clipped()
                    .accessibilityLabel(Text(PhotoDraft.photoLabel(index: index, count: items.count)))
            } else if item.isEncoding {
                ProgressView().controlSize(.small).tint(NightWatch.Palette.textSecondary.color)
                    .accessibilityLabel(Text("Preparing photo \(index + 1)"))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            // A 44 pt target with a small visible mark, hung over the corner.
            Button { onRemove(item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .heavy))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.72)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 16, y: -16)
            .accessibilityLabel(Text(PhotoDraft.removeLabel(index: index, count: items.count)))
        }
    }
}

// MARK: - The chip on a message

/// "2 photos", on a bubble whose message carried photos.
struct NWPhotoChip: View {
    var count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo").font(.system(.caption2, weight: .semibold))
            Text(PhotoDraft.countLabel(count)).font(NightWatch.Typo.captionStrong)
        }
        .foregroundColor(NightWatch.Palette.textSecondary.color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .accessibilityHidden(true)
    }
}
