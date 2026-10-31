import SwiftUI

/// Icon-only button with a tap area of at least 36×36 points, Apple's minimum for controls used
/// by touch on a Mac (MacBook Pro with a touch screen, macOS 27). The icon keeps its size; only
/// the area that responds grows, so it also helps with the trackpad.
struct TouchIconButtonStyle: ButtonStyle {
    static let minimum: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        TouchIcon(configuration: configuration)
    }

    private struct TouchIcon: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .frame(minWidth: TouchIconButtonStyle.minimum, minHeight: TouchIconButtonStyle.minimum)
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.45 : 1) : 0.35)
        }
    }
}

extension ButtonStyle where Self == TouchIconButtonStyle {
    static var touchIcon: TouchIconButtonStyle { TouchIconButtonStyle() }
}

/// Text explaining why a control is not available, shown in a popover on click or tap: a help
/// tag needs a pointer hovering over the control, which a finger never does.
struct ReasonPopover: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading).padding(14)
        }
    }
}

extension View {
    func reasonPopover(isPresented: Binding<Bool>, _ text: String) -> some View {
        modifier(ReasonPopover(isPresented: isPresented, text: text))
    }
}
