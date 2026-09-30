import SwiftUI
import AppKit
import Combine

enum RepeatMode {
    case off
    case context // Repeat playlist/album
    case track   // Repeat single track (repeat.1)
}

// MARK: - Live Media Controller
class MediaManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var isShuffling: Bool = false
    @Published var repeatMode: RepeatMode = .off
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
    private var isUpdatingRepeat = false

    init() {
        timer = Timer.publish(every: 0.8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
        refresh()
    }

    func refresh() {
            let spotifyRunning = isRunning("com.spotify.client")
            let musicRunning = isRunning("com.apple.Music")

            // If Apple Music is actively playing or Spotify is closed, prioritize Music
            if musicRunning && (!spotifyRunning || activeApp == .music) {
                fetchMusic()
            } else if spotifyRunning {
                fetchSpotify()
            } else if musicRunning {
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

    // MARK: - Spotify Polling (Respecting 3-state loop)
    func fetchSpotify() {
        let script = """
        tell application "Spotify"
            if player state is playing or player state is paused then
                set pState to (player state as string)
                set tName to name of current track
                set tArtist to artist of current track
                set tPos to player position
                set tDur to (duration of current track) / 1000
                set tArt to artwork url of current track
                set isShuf to shuffling as string
                set isRep to repeating as string
                return pState & "|||" & tName & "|||" & tArtist & "|||" & tPos & "|||" & tDur & "|||" & tArt & "|||" & isShuf & "|||" & isRep
            else
                return "stopped"
            end if
        end tell
        """
        runScriptAsync(script) { [weak self] result in
            guard let self = self, let result = result, result != "stopped" else {
                DispatchQueue.main.async {
                    self?.activeApp = .none
                    self?.isPlaying = false
                }
                return
            }
            let parts = result.components(separatedBy: "|||")
            if parts.count >= 8 {
                let playing = parts[0] == "playing"
                let name = parts[1]
                let artist = parts[2]
                let pos = Double(parts[3]) ?? 0.0
                let dur = Double(parts[4]) ?? 1.0
                let artUrl = parts[5]
                let shuf = parts[6] == "true"
                let rep = parts[7] == "true"

                DispatchQueue.main.async {
                    self.activeApp = .spotify
                    self.isPlaying = playing
                    self.isShuffling = shuf

                    if !self.isUpdatingRepeat {
                        if !rep {
                            self.repeatMode = .off
                        } else if self.repeatMode == .off {
                            self.repeatMode = .context
                        }
                    }

                    self.title = name
                    self.artist = artist
                    self.position = pos
                    self.duration = max(dur, 1.0)
                    self.loadRemoteArtwork(artUrl)
                }
            }
        }
    }

    // MARK: - 3-Stage Repeat Toggle (Spotify Native Keystroke)
        func cycleRepeatMode() {
            guard activeApp == .spotify else { return }
            isUpdatingRepeat = true

            // Advance local state immediately for instant UI feedback
            switch repeatMode {
            case .off:
                repeatMode = .context
            case .context:
                repeatMode = .track
            case .track:
                repeatMode = .off
            }

            // Send Spotify's native Repeat shortcut (Cmd + R)
            // Key code 15 is 'r'
            let script = """
            tell application "System Events"
                tell process "Spotify"
                    key code 15 using {command down}
                end tell
            end tell
            """
            runCommand(script)

            // Hold lock for 1.2s so the polling loop doesn't overwrite the state before Spotify updates
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.isUpdatingRepeat = false
            }
        }

    private func loadRemoteArtwork(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let data = data, let img = NSImage(data: data) {
                DispatchQueue.main.async {
                    self?.artwork = img
                }
            }
        }.resume()
    }

    // MARK: - Apple Music (Robust)
        func fetchMusic() {
            let script = """
            tell application "Music"
                try
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
                on error errStr
                    return "error|||" & errStr
                end try
            end tell
            """
            runScriptAsync(script) { [weak self] result in
                guard let self = self, let result = result else {
                    return
                }

                if result.starts(with: "error|||") {
                    print("🚨 Apple Music Script Error: \(result)")
                    return
                }

                guard result != "stopped" else {
                    DispatchQueue.main.async {
                        if self.activeApp == .music {
                            self.activeApp = .none
                            self.isPlaying = false
                        }
                    }
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
                        self.activeApp = .music
                        self.isPlaying = playing
                        self.title = name
                        self.artist = artist
                        self.position = pos
                        self.duration = max(dur, 1.0)
                        self.fetchMusicArtwork()
                    }
                }
            }
        }

        private func fetchMusicArtwork() {
            let script = """
            tell application "Music"
                try
                    tell current track
                        if (count of artworks) > 0 then
                            return raw data of artwork 1
                        end if
                    end tell
                end try
                return ""
            end tell
            """
            DispatchQueue.global(qos: .utility).async { [weak self] in
                if let descriptor = self?.executeAppleScriptDescriptor(script) {
                    // If the AppleEvent descriptor returned valid raw image bytes (PICT, JPEG, or PNG)
                    let data = descriptor.data
                    if data.count > 100 {
                        if let img = NSImage(data: data) {
                            DispatchQueue.main.async {
                                self?.artwork = img
                            }
                            return
                        }
                    }
                }
                // Fallback for cloud/streamed tracks without embedded raw bytes
                DispatchQueue.main.async {
                    if self?.activeApp == .music && self?.artwork == nil {
                        self?.artwork = nil
                    }
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

    func toggleShuffle() {
        guard activeApp == .spotify else { return }
        runCommand("tell application \"Spotify\" to set shuffling to not shuffling")
        isShuffling.toggle()
    }

    // MARK: - Seek Track Position
    func seek(to seconds: Double) {
        let clampedSeconds = max(0, min(seconds, duration))
        position = clampedSeconds
        if activeApp == .spotify {
            runCommand("tell application \"Spotify\" to set player position to \(clampedSeconds)")
        } else if activeApp == .music {
            runCommand("tell application \"Music\" to set player position to \(clampedSeconds)")
        }
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
    var barColor: Color = Color(red: 0.11, green: 0.84, blue: 0.38)

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
    @State private var isScrubbing: Bool = false
    @State private var scrubPosition: Double = 0.0

    private let trueBlack = Color(nsColor: NSColor(displayP3Red: 0, green: 0, blue: 0, alpha: 1.0))
    private let compactIslandWidth: CGFloat = 238
    private let compactIslandHeight: CGFloat = 33

    private var hasActiveMedia: Bool {
        media.activeApp != .none && !media.title.isEmpty
    }

    var body: some View {
        let islandWidth: CGFloat = isHovered ? 410 : compactIslandWidth
        let islandHeight: CGFloat = isHovered ? 138 : compactIslandHeight

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if hasActiveMedia || isHovered {
                    DynamicIslandShape(topCornerRadius: isHovered ? 12 : 7, bottomCornerRadius: isHovered ? 24 : 13)
                        .fill(trueBlack)

                    DynamicIslandBorder(topCornerRadius: isHovered ? 12 : 7, bottomCornerRadius: isHovered ? 24 : 13)
                        .stroke(Color.white.opacity(isHovered ? 0.15 : 0.08), lineWidth: 0.75)
                }

                Group {
                    if isHovered {
                        expandedMediaView
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                    } else if hasActiveMedia {
                        compactMediaView
                            .transition(.opacity)
                    }
                }
                .frame(width: islandWidth, height: islandHeight)
            }
            .frame(width: islandWidth, height: islandHeight)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.interpolatingSpring(mass: 0.8, stiffness: 260, damping: 19)) {
                    isHovered = hovering
                }
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

            iOSAudioVisualizer(
                isPlaying: media.isPlaying,
                barColor: media.activeApp == .spotify ? Color(red: 0.11, green: 0.84, blue: 0.38) : Color(red: 0.95, green: 0.35, blue: 0.45)
            )
            .padding(.trailing, 8)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Expanded Live Media Card
    private var expandedMediaView: some View {
        VStack(spacing: 8) {
            // Artwork & Song Metadata
            HStack(spacing: 10) {
                Group {
                    if let art = media.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [.red, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.9))
                            )
                    }
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: Color.black.opacity(0.4), radius: 5, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title.isEmpty ? "Not Playing" : media.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(media.artist.isEmpty ? "No Media App Active" : media.artist)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer()

                iOSAudioVisualizer(
                    isPlaying: media.isPlaying,
                    barColor: media.activeApp == .spotify ? Color(red: 0.11, green: 0.84, blue: 0.38) : Color(red: 0.95, green: 0.35, blue: 0.45)
                )
                .padding(.trailing, 4)
            }

            // Interactive Scrubber & Timestamps
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

            // MARK: - Spotify 1:1 Transport Controls
            HStack(spacing: 26) {
                // Shuffle Button with Dot
                Button(action: { media.toggleShuffle() }) {
                    VStack(spacing: 2.5) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(media.isShuffling ? Color(red: 0.11, green: 0.84, blue: 0.38) : Color(white: 0.65))
                            .frame(height: 16)

                        Circle()
                            .fill(Color(red: 0.11, green: 0.84, blue: 0.38))
                            .frame(width: 3.5, height: 3.5)
                            .opacity(media.isShuffling ? 1 : 0)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                // Spotify Previous: Triangle pointing into a solid bar
                Button(action: { media.previousTrack() }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(white: 0.80))
                }
                .buttonStyle(.plain)

                // Spotify White Circle Play/Pause Button
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

                // Spotify Next: Triangle pointing into a solid bar
                Button(action: { media.nextTrack() }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(white: 0.80))
                }
                .buttonStyle(.plain)

                // 3-State Spotify Repeat Button (Off -> Repeat All -> Repeat 1)
                Button(action: { media.cycleRepeatMode() }) {
                    VStack(spacing: 2.5) {
                        ZStack {
                            if media.repeatMode == .track {
                                Image(systemName: "repeat.1")
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundColor(Color(red: 0.11, green: 0.84, blue: 0.38))
                            } else {
                                Image(systemName: "repeat")
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundColor(media.repeatMode == .context ? Color(red: 0.11, green: 0.84, blue: 0.38) : Color(white: 0.65))
                            }
                        }
                        .frame(height: 16)

                        Circle()
                            .fill(Color(red: 0.11, green: 0.84, blue: 0.38))
                            .frame(width: 3.5, height: 3.5)
                            .opacity(media.repeatMode != .off ? 1 : 0)
                    }
                    .frame(width: 28, height: 28)
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
