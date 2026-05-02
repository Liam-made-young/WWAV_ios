import SwiftUI

/// Thin wrapper kept for backward-compatibility. The full radio composer
/// now lives inside `UploadView` as `RadioUploadForm` (accessed by
/// selecting the "radio" kind in the upload tab bar).
struct RadioView: View {
    var body: some View {
        RadioUploadForm()
    }
}
