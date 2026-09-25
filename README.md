# Neatbyte

Neatbyte is an on-device iPhone storage cleaner built with SwiftUI. It helps users review duplicate and similar photos, screenshots, large videos, and duplicate contacts before safely removing anything.

## Features

- Storage dashboard showing used and available device storage
- Exact duplicate and visually similar photo grouping
- Suggested keeper for each photo group
- Screenshot browser with multi-selection
- Large videos sorted by size with preview support
- Large-video compression with 1080p and 720p presets, progress, cancellation, and safe copy creation
- Swipe-to-keep-or-delete review with undo
- Conservative on-device blurry-photo detection with manual review
- AES-GCM encrypted private vault protected by Face ID/device authentication or a 6-digit PIN
- Post-cleanup summary showing item count and measured space selected for cleanup
- Duplicate-contact detection with merge and delete actions
- Final review screen showing selected items and estimated space savings
- Clear handling for denied, restricted, and limited Photos access
- On-device processing with no login, cloud sync, subscription, or paywall

## Safety and Privacy

- Photos and contacts remain on the device.
- Vault media is encrypted locally, stored with complete file protection, and excluded from backups.
- Importing into the vault never automatically deletes the Photos original.
- Video compression always creates a new copy before offering to select the original for deletion.
- Nothing is deleted without explicit confirmation.
- Similar-photo matches are presented for manual review.
- Contact changes require a separate review and confirmation.
- The app requests only the Photos and Contacts permissions needed for its features.

## Requirements

- Xcode 16 or later
- iPhone running iOS 17 or later
- A physical iPhone is recommended because the simulator typically has a limited photo library.

## Running the Project

1. Clone the repository.
2. Open `assignment.xcodeproj` in Xcode.
3. Select the `assignment` scheme and an iPhone run destination.
4. Choose your development team under **Signing & Capabilities** if required.
5. Build and run the app.
6. Grant Photos and Contacts access when prompted.

## Testing

The project includes Swift Testing targets covering storage calculations, photo identity and grouping behavior, duplicate-contact matching, and normalization logic.

Run the tests with **Product > Test** in Xcode.

## Technology

- Swift and SwiftUI
- Photos and PhotoKit
- Contacts
- Vision
- CryptoKit
- LocalAuthentication and Keychain Services
- AVFoundation and AVKit
- Swift Testing

## Known Limitations

- Calendar cleanup and a Home Screen widget are not included.
- Blur detection is intentionally conservative and can flag intentionally soft or dark images, so every result requires review.
- Scan performance and results depend on the size of the local library and availability of iCloud-hosted media.

## Demo

Screen recording: https://drive.google.com/drive/folders/1z0koozR9enO83oejPnVF7X3yKlHJfYcU?usp=share_link

## Author

Kushagra Sharma
