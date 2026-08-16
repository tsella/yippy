import SwiftUI

/// A centered, full-width confirmation prompt.
///
/// SwiftUI's `.confirmationDialog` renders as a bottom action sheet on iPhone,
/// and `.alert` is centered but locked to a ~270pt card that cannot be widened.
/// This overlay provides both behaviours: vertically centered and spanning the
/// screen width.
struct ConfirmationOverlay: View {
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive: Bool = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Scrim. Tapping outside cancels, matching system dialog behaviour.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)
                .accessibilityLabel("Dismiss")
                .accessibilityAction(.default, onCancel)

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button(action: onConfirm) {
                        Text(confirmTitle)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(isDestructive ? Color.red : Color.accentColor,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }

                    Button(action: onCancel) {
                        Text("Cancel")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(.tertiarySystemFill),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            // Inset from the screen edges so the card still reads as a dialog.
            .padding(.horizontal, 16)
        }
        .transition(.opacity)
        // Announce as a modal so VoiceOver ignores the content behind the scrim.
        .accessibilityAddTraits(.isModal)
    }
}

extension View {
    /// Presents a centered, full-width confirmation prompt.
    func confirmation(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = true,
        onConfirm: @escaping () -> Void
    ) -> some View {
        overlay {
            if isPresented.wrappedValue {
                ConfirmationOverlay(
                    title: title,
                    message: message,
                    confirmTitle: confirmTitle,
                    isDestructive: isDestructive,
                    onConfirm: {
                        // Run the action before dismissing. Callers may drive
                        // `isPresented` from optional state (e.g. the file being
                        // deleted); dismissing first would clear that state out
                        // from under the action.
                        onConfirm()
                        isPresented.wrappedValue = false
                    },
                    onCancel: { isPresented.wrappedValue = false }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented.wrappedValue)
    }
}
