import SwiftUI
import AppKit
import Combine

// MARK: - Live Media Controller
class MediaManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var position: Double = 0.0
    @Published var duration: Double = 1.0
    @Published var artwork: NSImage? = nil
    @Published var activeApp: ActiveApp = .none

    enum ActiveApp {
        case none, spotify, music
    }

    private var timer: AnyCancellable?

    init() {
        // Poll playback state every 0.8 seconds
        timer = Timer.publish(every: 0.8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
        refresh()
    }

    func refresh() {
        if isRunning("com.spotify.client") {
            fetchSpotify()
        } else if isRunning("com.apple.Music") {
            fetchMusic()
        } else {
            if activeApp != .none {
                DispatchQueue.main.async {
                    self.activeApp = .none
                    self.isPlaying = false
                }
            }
        }
    }

    private func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    // MARK: - Spotify
    private func fetchSpotify() {
        let script = """
        tell application "Spotify"
            if player state is playing or player state is paused then
                set pState to (player state as string)
                set tName to name of current track
                set tArtist to artist of current track
                set tPos to player position
                set tDur to (duration of current track) / 1000
                set tArt to artwork url of current track
                return pState & "|||" & tName & "|||" & tArtist & "|||" & tPos & "|||" & tDur & "|||" & tArt
            else
                return "stopped"
            end if
        end tell
        """
        runScriptAsync(script) { [weak self] result in
            guard let result = result, result != "stopped" else {
                DispatchQueue.main.async { self?.activeApp = .none }
                return
            }
            let parts = result.components(separatedBy: "|||")
            if parts.count >= 5 {
                let playing = parts[0] == "playing"
                let name = parts[1]
                let artist = parts[2]
                let pos = Double(parts[3]) ?? 0.0
                let dur = Double(parts[4]) ?? 1.0
                let artUrl = parts.count > 5 ? parts[5] : ""

                DispatchQueue.main.async {
                    self?.activeApp = .spotify
                    self?.isPlaying = playing
                    self?.title = name
                    self?.artist = artist
                    self?.position = pos
                    self?.duration = max(dur, 1.0)
                    self?.loadRemoteArtwork(artUrl)
                }
            }
        }
    }

    private func loadRemoteArtwork(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let data = data, let img = NSImage(data: data) {
                DispatchQueue.main.async { self?.artwork = img }
            }
        }.resume()
    }

    // MARK: - Apple Music
    private func fetchMusic() {
        let script = """
        tell application "Music"
            if player state is playing or player state is paused then
                set pState to (player state as string)
                set tName to name of current track
                set tArtist to artist of current track
                set tPos to player position
                set tDur to duration of current track
                return pState & "|||" & tName & "|||" & tArtist & "|||" & tPos & "|||" & tDur
            else
                return "stopped"
            end if
        end tell
        """
        runScriptAsync(script) { [weak self] result in
            guard let result = result, result != "stopped" else {
                DispatchQueue.main.async { self?.activeApp = .none }
                return
            }
            let parts = result.components(separatedBy: "|||")
            if parts.count >= 5 {
                let playing = parts[0] == "playing"
                let name = parts[1]
                let artist = parts[2]
                let pos = Double(parts[3]) ?? 0.0
                let dur = Double(parts[4]) ?? 1.0

                DispatchQueue.main.async {
                    self?.activeApp = .music
                    self?.isPlaying = playing
                    self?.title = name
                    self?.artist = artist
                    self?.position = pos
                    self?.duration = max(dur, 1.0)
                    self?.fetchMusicArtwork()
                }
            }
        }
    }

    private func fetchMusicArtwork() {
        let script = """
        tell application "Music"
            try
                if (count of artworks of current track) > 0 then
                    return raw data of artwork 1 of current track
                end if
            end try
            return ""
        end tell
        """
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if let descriptor = self?.executeAppleScriptDescriptor(script), descriptor.data.count > 0 {
                let img = NSImage(data: descriptor.data)
                DispatchQueue.main.async { self?.artwork = img }
            }
        }
    }

    // MARK: - Playback Controls
    func togglePlayPause() {
        let app = activeApp == .spotify ? "Spotify" : "Music"
        runCommand("tell application \"\(app)\" to playpause")
        isPlaying.toggle()
    }

    func nextTrack() {
        let app = activeApp == .spotify ? "Spotify" : "Music"
        runCommand("tell application \"\(app)\" to next track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }

    func previousTrack() {
        let app = activeApp == .spotify ? "Spotify" : "Music"
        runCommand("tell application \"\(app)\" to previous track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }

    private func runCommand(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    private func runScriptAsync(_ script: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
            completion(error == nil ? output : nil)
        }
    }

    private func executeAppleScriptDescriptor(_ script: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}

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
    @StateObject private var media = MediaManager()
    @State private var isHovered = false

    private let trueBlack = Color(nsColor: NSColor(displayP3Red: 0, green: 0, blue: 0, alpha: 1.0))
    private let compactIslandWidth: CGFloat = 238
    private let compactIslandHeight: CGFloat = 33

    private var hasActiveMedia: Bool {
        media.activeApp != .none && !media.title.isEmpty
    }

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
            // Album art or placeholder icon
            Group {
                if let art = media.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(colors: [.red, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        )
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(.leading, 7)

            Spacer()

            // Waveform visualizer tucked tight to the right ear
            iOSAudioVisualizer(
                isPlaying: media.isPlaying,
                barColor: media.activeApp == .spotify ? Color.green : Color(red: 0.95, green: 0.35, blue: 0.45)
            )
            .padding(.trailing, 8)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Expanded Card
    private var expandedMediaView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Album artwork
                Group {
                    if let art = media.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: [.red, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.9))
                            )
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)

                // Track & Artist
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title.isEmpty ? "Not Playing" : media.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(media.artist.isEmpty ? "No Media App Active" : media.artist)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer()

                iOSAudioVisualizer(
                    isPlaying: media.isPlaying,
                    barColor: media.activeApp == .spotify ? Color.green : Color(red: 0.95, green: 0.35, blue: 0.45)
                )
                .padding(.trailing, 4)
            }

            // Timeline bar
            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 5)

                        Capsule()
                            .fill(Color.white)
                            .frame(
                                width: geo.size.width * CGFloat(min(max(media.position / media.duration, 0.0), 1.0)),
                                height: 5
                            )
                    }
                }
                .frame(height: 5)

                HStack {
                    Text(formatTime(media.position))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("-" + formatTime(max(media.duration - media.position, 0)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            // Playback controls
            HStack(spacing: 36) {
                Button(action: { media.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button(action: { media.togglePlayPause() }) {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button(action: { media.nextTrack() }) {
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
