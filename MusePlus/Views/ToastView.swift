import SwiftUI

// MARK: - ToastView
//
// Reusable bottom-anchored overlay. Auto-dismisses after 3 seconds.
// Usage: .overlay(alignment: .bottom) { ToastView(...) }
// Show via @State var toastMessage: String? — set to nil to hide.

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.80))
            .foregroundColor(.white)
            .font(.subheadline.weight(.medium))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4)
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - ToastModifier
//
// Attach to any View: .toast(message: $msg)
// Automatically dismisses after 3 s when message is set.

struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let msg = message {
                    ToastView(message: msg)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    message = nil
                                }
                            }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: message)
    }
}

extension View {
    func toast(message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
