import SwiftUI

// Custom shape where the top corners flare OUTWARD to meet the screen bezel
struct NotchNookShape: Shape {
    var topCornerRadius: CGFloat = 12 // Outward flare width
    var bottomCornerRadius: CGFloat = 18 // Curved bottom corners

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 1. Start at top-left edge flared OUTWARD
        path.move(to: CGPoint(x: rect.minX - topCornerRadius, y: rect.minY))

        // 2. Curve INWARD to the vertical left wall (Outward flare)
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )

        // 3. Line down to bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius))

        // 4. Bottom-left inward curve
        path.addArc(
            center: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY - bottomCornerRadius),
            radius: bottomCornerRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // 5. Bottom edge line
        path.addLine(to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY))

        // 6. Bottom-right inward curve
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY - bottomCornerRadius),
            radius: bottomCornerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )

        // 7. Line up to top-right flare start
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topCornerRadius))

        // 8. Curve OUTWARD to top-right edge
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + topCornerRadius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

struct ContentView: View {
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dynamic Island")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text("Active Session")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
                
                Spacer()
                
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 16)
            .frame(width: isHovered ? 340 : 180, height: isHovered ? 72 : 32)
            // Explicit pure black color
            .background(Color(nsColor: .black))
            .clipShape(NotchNookShape(topCornerRadius: 10, bottomCornerRadius: 18))
            .overlay(
                NotchNookShape(topCornerRadius: 10, bottomCornerRadius: 18)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            // Soft drop shadow to blend screen backlight bleed into the physical bezel
            .shadow(color: Color.black.opacity(0.8), radius: 4, x: 0, y: 2)
            .opacity(isHovered ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    isHovered = hovering
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview {
    ContentView()
}
