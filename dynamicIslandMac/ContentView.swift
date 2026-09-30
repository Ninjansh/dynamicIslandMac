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
    
    private var lastArtworkId: String = ""

    // In MediaManager:
    enum ActiveApp {
        case none
        case spotify
        case music
        case youtubeMusic
        case soundCloud
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

    // MARK: - Smart App Arbitration
    func refresh() {
        let spotifyRunning = isRunning("com.spotify.client")
        let musicRunning = isRunning("com.apple.Music")

        // Only reset if NEITHER application is currently running
        guard spotifyRunning || musicRunning else {
            if activeApp != .none {
                DispatchQueue.main.async {
                    withAnimation(.smooth(duration: 0.3)) {
                        self.activeApp = .none
                        self.isPlaying = false
                        self.artwork = nil
                        self.lastArtworkId = ""
                    }
                }
            }
            return
        }

        if spotifyRunning && musicRunning {
            checkActivePlayback()
        } else if spotifyRunning {
            fetchSpotify()
        } else if musicRunning {
            fetchMusic()
        }
    }

    private func checkActivePlayback() {
        let script = """
        set spState to "stopped"
        set muState to "stopped"

        tell application "System Events"
            set isSp to (exists (processes where bundle identifier is "com.spotify.client"))
            set isMu to (exists (processes where bundle identifier is "com.apple.Music"))
        end tell

        if isSp then
            try
                tell application "Spotify" to set spState to (player state as string)
            end try
        end if

        if isMu then
            try
                tell application "Music" to set muState to (player state as string)
            end try
        end if

        return spState & "|||" & muState
        """

        runScriptAsync(script) { [weak self] result in
            guard let self = self, let result = result else { return }
            let states = result.components(separatedBy: "|||")
            guard states.count == 2 else { return }

            let spotifyState = states[0]
            let musicState = states[1]

            if musicState == "playing" && spotifyState != "playing" {
                self.fetchMusic()
            } else if spotifyState == "playing" && musicState != "playing" {
                self.fetchSpotify()
            } else {
                if self.activeApp == .music {
                    self.fetchMusic()
                } else {
                    self.fetchSpotify()
                }
            }
        }
    }

    private func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    // MARK: - Spotify Polling
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
                    if self?.activeApp == .spotify {
                        withAnimation(.smooth(duration: 0.3)) {
                            self?.activeApp = .none
                            self?.isPlaying = false
                            self?.lastArtworkId = ""
                        }
                    }
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

                    if self.title != name {
                        withAnimation(.smooth(duration: 0.35)) {
                            self.title = name
                            self.artist = artist
                        }
                    } else {
                        self.artist = artist
                    }

                    self.position = pos
                    self.duration = max(dur, 1.0)
                    
                    if self.lastArtworkId != artUrl {
                        self.lastArtworkId = artUrl
                        self.loadRemoteArtwork(artUrl)
                    }
                }
            }
        }
    }

    private func loadRemoteArtwork(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let data = data, let img = NSImage(data: data) {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        self?.artwork = img
                    }
                }
            }
        }.resume()
    }

    // MARK: - Apple Music Polling
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
                    set isShuf to (shuffle enabled as string)
                    set repMode to (song repeat as string)
                    return pState & "|||" & tName & "|||" & tArtist & "|||" & tPos & "|||" & tDur & "|||" & isShuf & "|||" & repMode
                else
                    return "stopped"
                end if
            on error errStr
                return "error|||" & errStr
            end try
        end tell
        """
        runScriptAsync(script) { [weak self] result in
            guard let self = self, let result = result else { return }
            if result.starts(with: "error|||") || result == "stopped" {
                DispatchQueue.main.async {
                    if self.activeApp == .music {
                        withAnimation(.smooth(duration: 0.3)) {
                            self.activeApp = .none
                            self.isPlaying = false
                            self.lastArtworkId = ""
                        }
                    }
                }
                return
            }

            let parts = result.components(separatedBy: "|||")
            if parts.count >= 7 {
                let playing = parts[0] == "playing"
                let name = parts[1]
                let artist = parts[2]
                let pos = Double(parts[3]) ?? 0.0
                let dur = Double(parts[4]) ?? 1.0
                let shuf = parts[5] == "true"
                let rep = parts[6]

                DispatchQueue.main.async {
                    self.activeApp = .music
                    self.isPlaying = playing
                    self.isShuffling = shuf

                    if !self.isUpdatingRepeat {
                        switch rep {
                        case "all": self.repeatMode = .context
                        case "one": self.repeatMode = .track
                        default:    self.repeatMode = .off
                        }
                    }

                    if self.title != name {
                        withAnimation(.smooth(duration: 0.35)) {
                            self.title = name
                            self.artist = artist
                        }
                    } else {
                        self.artist = artist
                    }

                    self.position = pos
                    self.duration = max(dur, 1.0)
                    
                    let trackId = "\(name)-\(artist)"
                    if self.lastArtworkId != trackId {
                        self.lastArtworkId = trackId
                        self.fetchMusicArtwork()
                    }
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
                let data = descriptor.data
                if data.count > 100 {
                    if let img = NSImage(data: data) {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                self?.artwork = img
                            }
                        }
                        return
                    }
                }
            }
            DispatchQueue.main.async {
                if self?.activeApp == .music && self?.artwork != nil {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        self?.artwork = nil
                    }
                }
            }
        }
    }

    // MARK: - Controls
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
        if activeApp == .spotify {
            runCommand("tell application \"Spotify\" to set shuffling to not shuffling")
            isShuffling.toggle()
        } else if activeApp == .music {
            runCommand("tell application \"Music\" to set shuffle enabled to not shuffle enabled")
            isShuffling.toggle()
        }
    }

    func cycleRepeatMode() {
        isUpdatingRepeat = true

        switch repeatMode {
        case .off:
            repeatMode = .context
            if activeApp == .spotify {
                let script = """
                tell application "System Events"
                    tell process "Spotify" to key code 15 using {command down}
                end tell
                """
                runCommand(script)
            } else if activeApp == .music {
                runCommand("tell application \"Music\" to set song repeat to all")
            }

        case .context:
            repeatMode = .track
            if activeApp == .spotify {
                let script = """
                tell application "System Events"
                    tell process "Spotify" to key code 15 using {command down}
                end tell
                """
                runCommand(script)
            } else if activeApp == .music {
                runCommand("tell application \"Music\" to set song repeat to one")
            }

        case .track:
            repeatMode = .off
            if activeApp == .spotify {
                let script = """
                tell application "System Events"
                    tell process "Spotify" to key code 15 using {command down}
                end tell
                """
                runCommand(script)
            } else if activeApp == .music {
                runCommand("tell application \"Music\" to set song repeat to off")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.isUpdatingRepeat = false
        }
    }

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

// MARK: - Artwork Dominant Color Extractor
extension NSImage {
    var dominantColor: Color? {
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let ciImage = CIImage(bitmapImageRep: bitmap) else { return nil }

        // Downsample using an extent filter to get average color
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

        // Prevent pure dark/black colors from becoming invisible against the black notch
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance < 0.18 {
            return Color(red: min(r + 0.35, 1.0), green: min(g + 0.35, 1.0), blue: min(b + 0.35, 1.0))
        }

        return Color(red: r, green: g, blue: b)
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

// MARK: - Animated Equalizer Visualizer (Smooth Decay & Dynamic Tint)
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
                    .frame(
                        width: 2.5,
                        height: isPlaying ? (13 * barHeights[index]) : 3
                    )
                    // Smooth spring decay when pausing, fast bouncy changes while playing
                    .animation(
                        isPlaying
                            ? .easeInOut(duration: 0.15)
                            : .spring(response: 0.38, dampingFraction: 0.75),
                        value: isPlaying
                    )
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
        .onChange(of: isPlaying) {
            if !isPlaying {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    barHeights = [0.25, 0.25, 0.25, 0.25]
                }
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
    
    // Used for Shuffle, Repeat, and native indicator dots
    private var appThemeColor: Color {
        switch media.activeApp {
        case .spotify:
            return Color(red: 0.11, green: 0.84, blue: 0.38) // #1DB954
        case .music:
            return Color(red: 0.98, green: 0.14, blue: 0.31) // #FA2450
        case .youtubeMusic:
            return Color(red: 1.00, green: 0.00, blue: 0.00) // #FF0000
        case .soundCloud:
            return Color(red: 1.00, green: 0.33, blue: 0.00) // #FF5500
        case .none:
            return Color.white
        }
    }
    
    // Used exclusively for the visualizer wave
    private var visualizerWaveColor: Color {
        media.artwork?.dominantColor ?? appThemeColor
    }
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
                barColor: visualizerWaveColor
            )
            .padding(.trailing, 8)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
    
    // MARK: - Expanded Live Media Card
    private var expandedMediaView: some View {
        VStack(spacing: 8) {
            // 1. Artwork & Song Metadata
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
                    
                    Text(media.artist)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                
                Spacer()
                
                iOSAudioVisualizer(
                    isPlaying: media.isPlaying,
                    barColor: visualizerWaveColor
                )
                .padding(.trailing, 4)
            }
            
            // 2. Interactive Scrubber & Timestamps
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
                // Shuffle Button with Active Dot
                Button(action: { media.toggleShuffle() }) {
                    VStack(spacing: 2.5) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(media.isShuffling ? appThemeColor : Color(white: 0.65))
                            .frame(height: 16)
                        
                        Circle()
                            .fill(appThemeColor)
                            .frame(width: 3.5, height: 3.5)
                            .opacity(media.isShuffling ? 1 : 0)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                
                // Previous Track
                Button(action: { media.previousTrack() }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(white: 0.80))
                }
                .buttonStyle(.plain)
                
                // White Play/Pause Circle
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
                
                // Next Track
                Button(action: { media.nextTrack() }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(white: 0.80))
                }
                .buttonStyle(.plain)
                
                // 3-State Repeat Button with Active Dot
                Button(action: { media.cycleRepeatMode() }) {
                    VStack(spacing: 2.5) {
                        ZStack {
                            if media.repeatMode == .track {
                                Image(systemName: "repeat.1")
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundColor(appThemeColor)
                            } else {
                                Image(systemName: "repeat")
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundColor(media.repeatMode == .context ? appThemeColor : Color(white: 0.65))
                            }
                        }
                        .frame(height: 16)
                        
                        Circle()
                            .fill(appThemeColor)
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
