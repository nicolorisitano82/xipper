import SwiftUI

/// Custom Liquid Glass that follows the accessibility settings (UI_SPEC 0.3, 10.1):
/// with Reduce Transparency or Increase Contrast the glass becomes a solid surface with a border
/// (1 pt separator, or 1.5 pt primary with increased contrast). A tint only carries meaning (errors, warnings).
struct AccessibleGlass<S: InsettableShape>: ViewModifier {
    let tint: Color?
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var increased: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XIPPER_DEMO_CONTRAST"] != nil { return true }
        #endif
        return contrast == .increased
    }
    private var solid: Bool { reduceTransparency || increased }

    func body(content: Content) -> some View {
        if solid {
            content
                .background {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                        .overlay { if let tint { shape.fill(tint.opacity(0.16)) } }
                        .overlay {
                            shape.strokeBorder(increased ? Color.primary : Color(nsColor: .separatorColor),
                                               lineWidth: increased ? 1.5 : 1)
                        }
                }
                .glassEffect(.identity, in: shape)
        } else {
            content.glassEffect(tint.map { .regular.tint($0.opacity(0.35)) } ?? .regular, in: shape)
        }
    }
}

extension View {
    func accessibleGlass(tint: Color? = nil, in shape: some InsettableShape) -> some View {
        modifier(AccessibleGlass(tint: tint, shape: shape))
    }
}

extension AnyTransition {
    /// Glass morphs and replacements become a short fade with Reduce Motion (10.2).
    static func morph(reduceMotion: Bool, _ normal: AnyTransition) -> AnyTransition {
        reduceMotion ? .opacity.animation(.easeInOut(duration: 0.15)) : normal
    }
}

/// A symbol bounce that is skipped with Reduce Motion.
private struct Bounce<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion { content } else { content.symbolEffect(.bounce, value: value) }
    }
}

extension View {
    func bounce(on value: some Equatable) -> some View { modifier(Bounce(value: value)) }
}
