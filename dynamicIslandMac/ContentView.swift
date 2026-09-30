import SwiftUI
import AppKit
import Combine

// MARK: - Bezel-Seamless Dynamic Island Shape
struct DynamicIslandShape: Shape {
    var topCornerRadius: CGFloat = 12
    var bottomCornerRadius: CGFloat = 20
    var bleedOffset: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topY = rect.minY - bleedOffset
        let startLeft = rect.minX - topCornerRadius
        let startRight = rect.maxX + topCornerRadius

        path.move(to: CGPoint(x: startLeft, y: topY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: startRight, y: topY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: startLeft, y: topY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Hanging Border
struct DynamicIslandBorder: Shape {
    var topCornerRadius: CGFloat = 12
    var bottomCornerRadius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - topCornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + topCornerRadius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        return path
    }
}

// MARK: - Animated Equalizer Visualizer
struct iOSAudioVisualizer: View {
    var isPlaying: Bool
    var barColor: Color = Color(red: 0.95, green: 0.35, blue: 0.45)

    @State private var barHeights: [CGFloat] = [0.4, 0.8, 0.5, 0.9]
    let timer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2.0) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor)
                    .frame(width: 2.5, height: isPlaying ? (13 * barHeights[index]) : 3)
            }
        }
        .frame(height: 13)
        .onReceive(timer) { _ in
            guard isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.17)) {
                barHeights = (0..<4).map { _ in CGFloat.random(in: 0.25...1.0) }
            }
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @State private var isHovered = false
    @State private var isPlaying = true
    @State private var progress: Double = 0.42

    let trackTitle = "Starboy"
    let artistName = "The Weeknd, Daft Punk"
    let durationTotal = 230.0

    private let trueBlack = Color(nsColor: NSColor(displayP3Red: 0, green: 0, blue: 0, alpha: 1.0))

    // Tweak this value if needed:
    // 238 pt gives just enough width for the camera cutout (~180-200pt)
    // while bringing the wave and art snug against the notch sides.
    private let compactIslandWidth: CGFloat = 238
    private let compactIslandHeight: CGFloat = 34

    var body: some View {
        let islandWidth: CGFloat = isHovered ? 410 : compactIslandWidth
        let islandHeight: CGFloat = isHovered ? 175 : compactIslandHeight

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Background Pure Black Bezel Shape
                DynamicIslandShape(topCornerRadius: isHovered ? 12 : 7, bottomCornerRadius: isHovered ? 24 : 14)
                    .fill(trueBlack)

                // Edge stroke for contrast
                DynamicIslandBorder(topCornerRadius: isHovered ? 12 : 7, bottomCornerRadius: isHovered ? 24 : 14)
                    .stroke(Color.white.opacity(isHovered ? 0.15 : 0.08), lineWidth: 0.75)

                // Content Layer
                Group {
                    if isHovered {
                        expandedMediaView
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                    } else {
                        compactMediaView
                            .transition(.opacity)
                    }
                }
                .frame(width: islandWidth, height: islandHeight)
            }
            .frame(width: islandWidth, height: islandHeight)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.36, dampingFraction: 0.72, blendDuration: 0)) {
                    isHovered = hovering
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Compact Pill (Tucked Snug to Notch Edges)
    private var compactMediaView: some View {
        HStack(spacing: 0) {
            // Album art on the left ear
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [.red, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                )
                .frame(width: 18, height: 18)
                .padding(.leading, 7)

            Spacer()

            // Waveform visualizer tucked tight to the right ear
            iOSAudioVisualizer(isPlaying: isPlaying)
                .padding(.trailing, 8)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Expanded Card
    private var expandedMediaView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [.red, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(trackTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(artistName)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer()

                iOSAudioVisualizer(isPlaying: isPlaying)
                    .padding(.trailing, 4)
            }

            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 5)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * CGFloat(progress), height: 5)
                    }
                }
                .frame(height: 5)

                HStack {
                    Text(formatTime(durationTotal * progress))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("-" + formatTime(durationTotal * (1.0 - progress)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            HStack(spacing: 36) {
                Button(action: {
                    withAnimation(.spring(response: 0.2)) { progress = max(0, progress - 0.1) }
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isPlaying.toggle()
                    }
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.spring(response: 0.2)) { progress = min(1.0, progress + 0.1) }
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
