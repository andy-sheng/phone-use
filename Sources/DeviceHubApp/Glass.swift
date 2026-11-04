import SwiftUI

/// Liquid Glass on macOS 26 and later, a material on older systems.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    func glassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        glassSurface(in: Capsule(), interactive: interactive, tint: tint)
    }

    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        glassSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Lets a background show through under the sidebar and inspector.
    @ViewBuilder
    func extendedUnderSidebar() -> some View {
        if #available(macOS 26, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Groups glass elements so they blend and morph together on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
