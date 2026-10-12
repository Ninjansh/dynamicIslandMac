import SwiftUI
import AppKit
import Combine
import MediaRemoteAdapter

// MARK: - 1. File-Scope Repeat Mode
enum IslandRepeatMode {
    case off
    case context
    case track
}

// MARK: - Seamless Infinite Single-Direction Marquee
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var speed: Double = 30.0 // Points per second
    var spacing: CGFloat = 40.0 // Gap between the looping text instances

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let shouldScroll = textWidth > geo.size.width

            HStack(spacing: spacing) {
                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { textGeo in
                            Color.clear
                                .preference(key: TextWidthPreferenceKey.self, value: textGeo.size.width)
                        }
                    )

                if shouldScroll {
                    // Duplicate for seamless infinite loop
                    Text(text)
                        .font(font)
                        .foregroundColor(color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .offset(x: offset)
            .onPreferenceChange(TextWidthPreferenceKey.self) { newWidth in
                textWidth = newWidth
                offset = 0
                if shouldScroll {
                    startScrolling()
                }
            }
            .onAppear {
                if shouldScroll {
                    startScrolling()
                }
            }
        }
        .frame(height: 18)
        .clipped()
    }

    private func startScrolling() {
        let totalDistance = textWidth + spacing
        let duration = Double(totalDistance) / speed

        offset = 0
        withAnimation(
            Animation.linear(duration: duration)
                .repeatForever(autoreverses: false)
                .delay(1.0)
        ) {
            offset = -totalDistance
        }
    }
}

private struct TextWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 3. Artwork Dominant Color Extractor (File Scope)
extension NSImage {
    var dominantColor: Color? {
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let ciImage = CIImage(bitmapImageRep: bitmap) else { return nil }

        let extentVector = CIVector(x: ciImage.extent.origin.x,
                                    y: ciImage.extent.origin.y,
                                    z: ciImage.extent.size.width,
                                    w: ciImage.extent.size.height)

        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: extentVector
        ]), let outputImage = filter.outputImage else { return nil }

        var bitmapData = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(outputImage,
                       toBitmap: &bitmapData,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)

        let r = Double(bitmapData[0]) / 255.0
        let g = Double(bitmapData[1]) / 255.0
        let b = Double(bitmapData[2]) / 255.0

        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance < 0.18 {
            return Color(red: min(r + 0.35, 1.0), green: min(g + 0.35, 1.0), blue: min(b + 0.35, 1.0))
        }

        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - 4. Live Media Controller (File Scope)
class MediaManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var isShuffling: Bool = false
    @Published var repeatMode: IslandRepeatMode = .off
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var position: Double = 0.0
    @Published var duration: Double = 1.0
    @Published var artwork: NSImage? = nil
    @Published var activeApp: ActiveApp = .idle
    @Published var isVideo: Bool = false

    private var lastArtworkId: String = ""
    private let controller = MediaController()
    private var progressTimer: AnyCancellable?
    private var currentTrackInfo: TrackInfo?

    enum ActiveApp {
        case idle
        case spotify
        case music
        case youtubeMusic
        case soundCloud
    }

    init() {
        setupAdapter()
        setupTimelineTimer()
    }
    
    // MARK: - Automated Browser & Media Origin Helper
        private func isApplicationWebBrowser(bundleIdentifier: String) -> Bool {
            guard !bundleIdentifier.isEmpty else { return false }
            
            if let httpsHandler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://apple.com")!),
               let defaultBundle = Bundle(url: httpsHandler)?.bundleIdentifier?.lowercased(),
               defaultBundle == bundleIdentifier {
                return true
            }
            
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            for app in runningApps {
                if let bundleURL = app.bundleURL,
                   let infoPlist = Bundle(url: bundleURL)?.infoDictionary {
                    if let urlTypes = infoPlist["CFBundleURLTypes"] as? [[String: Any]] {
                        for type in urlTypes {
                            if let schemes = type["CFBundleURLSchemes"] as? [String],
                               schemes.contains(where: { $0.caseInsensitiveCompare("http") == .orderedSame || $0.caseInsensitiveCompare("https") == .orderedSame }) {
                                return true
                            }
                        }
                    }
                }
            }
            return false
        }

    func classifyMediaOrigin(bundleId: String, title: String, artist: String) -> (app: ActiveApp, isVideo: Bool) {
            let titleLower = title.lowercased()
            let artistLower = artist.lowercased()
            let bundleLower = bundleId.lowercased()
            
            if bundleLower.contains("spotify") {
                return (.spotify, false)
            }
            if bundleLower == "com.apple.music" {
                return (.music, false)
            }
            if bundleLower.contains("soundcloud") || titleLower.contains("soundcloud") || artistLower.contains("soundcloud") {
                return (.soundCloud, false)
            }
            
            let isBrowserSession = isApplicationWebBrowser(bundleIdentifier: bundleLower) ||
                                   bundleLower.contains("helper") ||
                                   bundleLower.contains("browser")
            
            if isBrowserSession || titleLower.contains("youtube") {
                let isYouTubeMusic = titleLower.contains("youtube music") || artistLower.contains("youtube music")
                return (.youtubeMusic, !isYouTubeMusic)
            }
            
            return (.idle, false)
        }

    private func setupAdapter() {
        controller.onTrackInfoReceived = { [weak self] trackInfo in
            DispatchQueue.main.async {
                self?.handleTrackUpdate(trackInfo)
            }
        }
        controller.startListening()
    }

    private func setupTimelineTimer() {
        progressTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isPlaying, let info = self.currentTrackInfo else { return }
                if let liveSeconds = info.payload.currentElapsedTime {
                    self.position = min(liveSeconds, self.duration)
                }
            }
    }

    private func handleTrackUpdate(_ trackInfo: TrackInfo?) {
            guard let trackInfo = trackInfo else {
                DispatchQueue.main.async {
                    withAnimation(.smooth(duration: 0.3)) {
                        self.activeApp = .idle
                        self.isPlaying = false
                        self.title = ""
                        self.artist = ""
                        self.artwork = nil
                        self.lastArtworkId = ""
                        self.isVideo = false
                    }
                }
                self.currentTrackInfo = nil
                return
            }

            self.currentTrackInfo = trackInfo
            let payload = trackInfo.payload
            let rawTitle = payload.title ?? ""
            let rawArtist = payload.artist ?? ""
            let bundleId = (payload.bundleIdentifier ?? "").lowercased()

            guard !rawTitle.isEmpty else { return }

            // Clean redundant browser window titles
            let cleanTitle = rawTitle
                .replacingOccurrences(of: " - YouTube Music", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: " - YouTube", with: "", options: .caseInsensitive)

            // 1. Automatic classification via helper
            let classification = classifyMediaOrigin(bundleId: bundleId, title: rawTitle, artist: rawArtist)

            // 2. Playback state and timing
            let trackKey = "\(rawTitle)-\(rawArtist)"
            let incomingArt = payload.artwork
            let playing = payload.isPlaying ?? ((payload.playbackRate ?? 0) > 0.01)

            let durSeconds: Double = {
                if let durMicros = payload.durationMicros, durMicros > 0 {
                    return durMicros / 1_000_000.0
                }
                return 180.0
            }()

            let elapsedSeconds: Double = {
                if let livePos = payload.currentElapsedTime {
                    return livePos
                } else if let elapsedMicros = payload.elapsedTimeMicros {
                    return elapsedMicros / 1_000_000.0
                }
                return 0.0
            }()

            DispatchQueue.main.async {
                self.activeApp = classification.app
                self.isVideo = classification.isVideo
                self.isPlaying = playing
                self.duration = durSeconds
                self.position = elapsedSeconds

                // Update title with smooth spring
                if self.title != cleanTitle {
                    withAnimation(.smooth(duration: 0.35)) {
                        self.title = cleanTitle
                        self.artist = rawArtist
                    }
                } else {
                    self.artist = rawArtist
                }

                // Update artwork if track changed or late payload arrived
                if self.lastArtworkId != trackKey || (self.artwork == nil && incomingArt != nil) {
                    if incomingArt != nil {
                        self.lastArtworkId = trackKey
                    }
                    withAnimation(.easeInOut(duration: 0.28)) {
                        self.artwork = incomingArt
                    }
                }
            }
        }

    func togglePlayPause() {
        controller.togglePlayPause()
        isPlaying.toggle()
    }

    func nextTrack() {
        controller.nextTrack()
    }

    func previousTrack() {
        controller.previousTrack()
    }

    func seek(to seconds: Double) {
        let clampedSeconds = max(0, min(seconds, duration))
        position = clampedSeconds
        controller.setTime(seconds: clampedSeconds)
    }

    func toggleShuffle() {
        controller.toggleShuffle()
        isShuffling.toggle()
    }

    func toggleRepeat() {
        controller.toggleRepeat()
        switch repeatMode {
        case .off: repeatMode = .context
        case .context: repeatMode = .track
        case .track: repeatMode = .off
        }
    }
}

// MARK: - 5. Shapes & Visualizer (File Scope)
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
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + topCornerRadius), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCornerRadius), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topCornerRadius))
        path.addQuadCurve(to: CGPoint(x: startRight, y: topY), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: startLeft, y: topY))
        path.closeSubpath()
        return path
    }
}

struct DynamicIslandBorder: Shape {
    var topCornerRadius: CGFloat = 12
    var bottomCornerRadius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - topCornerRadius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + topCornerRadius), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCornerRadius), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + topCornerRadius, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

struct iOSAudioVisualizer: View {
    var isPlaying: Bool
    var barColor: Color

    @State private var barHeights: [CGFloat] = [0.25, 0.25, 0.25, 0.25]
    let timer = Timer.publish(every: 0.16, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2.0) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor)
                    .frame(width: 2.5, height: isPlaying ? (13 * barHeights[index]) : 3)
                    .animation(isPlaying ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.75), value: isPlaying)
            }
        }
        .frame(height: 13)
        .onReceive(timer) { _ in
            if isPlaying {
                withAnimation(.easeInOut(duration: 0.15)) {
                    barHeights = (0..<4).map { _ in CGFloat.random(in: 0.28...1.0) }
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    barHeights = [0.25, 0.25, 0.25, 0.25]
                }
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    barHeights = [0.25, 0.25, 0.25, 0.25]
                }
            }
        }
    }
}

// MARK: - 6. Main Dynamic Island View
struct ContentView: View {
    @StateObject private var media = MediaManager()
    @State private var isHovered = false
    @State private var isScrubbing: Bool = false
    @State private var scrubPosition: Double = 0.0

    private let trueBlack = Color(nsColor: NSColor(displayP3Red: 0, green: 0, blue: 0, alpha: 1.0))
    private let compactIslandWidth: CGFloat = 238
    private let compactIslandHeight: CGFloat = 33

    private var appThemeColor: Color {
        switch media.activeApp {
        case .spotify:
            return Color(red: 0.11, green: 0.84, blue: 0.38)
        case .music:
            return Color(red: 0.98, green: 0.14, blue: 0.31)
        case .youtubeMusic:
            return Color(red: 1.00, green: 0.00, blue: 0.00)
        case .soundCloud:
            return Color(red: 1.00, green: 0.33, blue: 0.00)
        case .idle:
            return Color.white
        }
    }

    private var visualizerWaveColor: Color {
        media.artwork?.dominantColor ?? appThemeColor
    }

    private var hasActiveMedia: Bool {
        media.activeApp != .idle && !media.title.isEmpty
    }

    var body: some View {
        let isExpanded = isHovered && (hasActiveMedia || isHovered)
        let isVisible = hasActiveMedia || isHovered

        let restingNotchWidth: CGFloat = 125
        let restingNotchHeight: CGFloat = 0

        let islandWidth: CGFloat = isExpanded ? 410 : (hasActiveMedia ? compactIslandWidth : restingNotchWidth)
        let islandHeight: CGFloat = isExpanded ? 138 : (hasActiveMedia ? compactIslandHeight : restingNotchHeight)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                DynamicIslandShape(
                    topCornerRadius: isExpanded ? 12 : 6,
                    bottomCornerRadius: isExpanded ? 24 : 12
                )
                .fill(trueBlack)
                .opacity(isVisible ? 1.0 : 0.0)

                DynamicIslandBorder(
                    topCornerRadius: isExpanded ? 12 : 6,
                    bottomCornerRadius: isExpanded ? 24 : 12
                )
                .stroke(Color.white.opacity(isExpanded ? 0.15 : (hasActiveMedia ? 0.08 : 0)), lineWidth: 0.75)

                ZStack {
                    if isExpanded {
                        expandedMediaView
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                removal: .opacity.animation(.easeOut(duration: 0.15))
                            ))
                    } else if hasActiveMedia {
                        compactMediaView
                            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    }
                }
                .frame(width: islandWidth, height: islandHeight)
                .clipped()
            }
            .frame(width: islandWidth, height: max(islandHeight, 0.1))
            .animation(.spring(response: 0.36, dampingFraction: 0.88, blendDuration: 0.08), value: isExpanded)
            .animation(.spring(response: 0.36, dampingFraction: 0.88, blendDuration: 0.08), value: isVisible)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Compact Pill
    private var compactMediaView: some View {
        HStack(spacing: 0) {
            Group {
                if let art = media.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(appThemeColor)
                        .overlay(
                            Image(systemName: media.isVideo ? "play.rectangle.fill" : "music.note")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        )
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(.leading, 7)

            Spacer()

            iOSAudioVisualizer(isPlaying: media.isPlaying, barColor: visualizerWaveColor)
                .padding(.trailing, 8)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Expanded Media Card
    private var expandedMediaView: some View {
        VStack(spacing: 8) {
            // 1. Artwork & Metadata
            HStack(spacing: 12) {
                Group {
                    if let art = media.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appThemeColor)
                            .overlay(
                                Image(systemName: media.isVideo ? "play.rectangle.fill" : "music.note")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.9))
                            )
                    }
                }
                .frame(width: media.isVideo ? 60 : 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 5, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(
                        text: media.title.isEmpty ? "Not Playing" : media.title,
                        font: .system(size: 13, weight: .semibold),
                        color: .white,
                        speed: 24.0
                    )

                    Text(media.artist.isEmpty ? (media.isVideo ? "YouTube Video" : "Unknown") : media.artist)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer()

                iOSAudioVisualizer(isPlaying: media.isPlaying, barColor: visualizerWaveColor)
                    .padding(.trailing, 4)
            }

            // 2. Interactive Scrubber
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let currentPos = isScrubbing ? scrubPosition : media.position
                    let progress = min(max(currentPos / max(media.duration, 1.0), 0.0), 1.0)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: isScrubbing ? 6 : 4)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * CGFloat(progress), height: isScrubbing ? 6 : 4)

                        Circle()
                            .fill(Color.white)
                            .frame(width: isScrubbing ? 12 : 0, height: isScrubbing ? 12 : 0)
                            .offset(x: max(0, (geo.size.width * CGFloat(progress)) - 6))
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isScrubbing = true
                                let clampedX = max(0, min(value.location.x, geo.size.width))
                                let ratio = clampedX / geo.size.width
                                scrubPosition = ratio * media.duration
                            }
                            .onEnded { value in
                                let clampedX = max(0, min(value.location.x, geo.size.width))
                                let ratio = clampedX / geo.size.width
                                let targetTime = ratio * media.duration
                                media.seek(to: targetTime)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isScrubbing = false
                                }
                            }
                    )
                }
                .frame(height: 12)

                HStack {
                    let displayPos = isScrubbing ? scrubPosition : media.position
                    Text(formatTime(displayPos))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("-" + formatTime(max(media.duration - displayPos, 0)))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            // 3. Transport Controls
            HStack(spacing: 26) {
                Button(action: { media.toggleShuffle() }) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(media.isShuffling ? appThemeColor : Color(white: 0.65))
                }
                .buttonStyle(.plain)

                Button(action: { media.previousTrack() }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(white: 0.80))
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.65)) {
                        media.togglePlayPause()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 34, height: 34)
                            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)

                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14.5, weight: .black))
                            .foregroundColor(.black)
                            .offset(x: media.isPlaying ? 0 : 1)
                    }
                }
                .buttonStyle(.plain)

                Button(action: { media.nextTrack() }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(white: 0.80))
                }
                .buttonStyle(.plain)

                Button(action: { media.toggleRepeat() }) {
                    Image(systemName: media.repeatMode == .track ? "repeat.1" : "repeat")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(media.repeatMode != .off ? appThemeColor : Color(white: 0.65))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
