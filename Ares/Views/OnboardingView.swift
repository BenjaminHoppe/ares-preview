import SwiftUI
import AppKit

struct OnboardingView: View {
    @StateObject private var pipeline = RenderingPipeline()
    @Binding var hasCompletedSetup: Bool
    @AppStorage("useImperialUnits") private var useImperialUnits = false
    @AppStorage("terrainSourceMode") private var terrainSourceMode = TerrainSource.prebaked.rawValue

    private let orange = Color(red: 0xED / 255, green: 0x6A / 255, blue: 0x3A / 255)
    private let grey = Color.white.opacity(0.5)
    private let mono = Font.system(size: 13, weight: .regular, design: .monospaced)
    private let monoBold = Font.system(size: 13, weight: .medium, design: .monospaced)

    private let welcomeArt = """
     _       __     __                             __
    | |     / /__  / /________  ____ ___  ___     / /_____
    | | /| / / _ \\/ / ___/ __ \\/ __ `__ \\/ _ \\   / __/ __ \\
    | |/ |/ /  __/ / /__/ /_/ / / / / / /  __/  / /_/ /_/ /
    |__/|__/\\___/_/\\___/\\____/_/ /_/ /_/\\___/   \\__/\\____/
    """

    private let aresArt = """
        ___    ____  ___________
       /   |  / __ \\/ ____/ ___/
      / /| | / /_/ / __/  \\__ \\
     / ___ |/ _, _/ /___ ___/ /
    /_/  |_/_/ |_/_____//____/
    """

    private let macPrompt = "Macintosh HD ~ $ "
    private let aresPrompt = "~ $ "

    // Sequence
    @State private var step = 0
    @State private var showCursor = true
    @State private var unitConfirmed = false
    @State private var sourceConfirmed = false
    @State private var selectedUnit = 0
    @State private var selectedTerrainSource = TerrainSource.prebaked.rawValue
    @State private var typedChars: [String: Int] = [:]
    @State private var upscaleDescLines = 0
    @State private var postRenderLines = 0

    // Init loading states
    @State private var initStates: [Int] = [0, 0, 0, 0, 0]
    private let initLabels: [String] = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return [
            "applied-curiosity/ares-preview v\(v) (build \(b))...",
            "AresSR v0.5.1 (30 mb)...",
            "ctx tiles (6 m/px)...",
            "hirise tiles (25 cm/px)...",
            "colour engine (metal)...",
        ]
    }()
    private let initResults = ["✓", "✓", "61 found", "270 found", "✓"]

    // UI loading states (post-launch)
    @State private var uiStates: [Int] = [0, 0, 0, 0, 0, 0, 0]
    private let uiLabels = [
        "loading Chryse Planitia...",
        "loading Ares Vallis...",
        "loading Pathfinder Landing Site...",
        "compiling Metal shaders...",
        "initializing viewport...",
        "building SwiftUI scene graph...",
        "registering input handlers...",
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 60)

                    VStack(alignment: .leading, spacing: 0) {

                        // cd into app
                        if step >= 1 {
                            typedPrompt("cd /Applications/Ares\\ Preview.app", prompt: macPrompt)
                            gap()
                        }

                        // Header
                        if step >= 2 {
                            Text(welcomeArt)
                                .font(.system(size: 7, weight: .regular, design: .monospaced))
                                .foregroundStyle(orange)
                                .lineSpacing(0)
                                .padding(.bottom, 6)
                            Text(aresArt)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(orange)
                                .lineSpacing(0)
                                .padding(.bottom, 4)
                            gap()
                        }

                        // Init
                        if step >= 3 {
                            typedPrompt("ares init")
                            gap(6)
                            ForEach(0..<initLabels.count, id: \.self) { i in
                                if initStates[i] > 0 {
                                    loadingRow(initLabels[i], result: initResults[i], done: initStates[i] >= 2)
                                }
                            }
                            if step >= 4 { gap() }
                        }

                        // Help
                        if step >= 5 {
                            typedPrompt("ares help")
                            gap(6)
                        }
                        if step >= 6 {
                            sectionLabel("keyboard shortcuts")
                            gap(4)
                            shortcut("a", "altimeter")
                            shortcut("p", "points of interest")
                            shortcut("t", "telemetry")
                            shortcut("u", "upscaling")
                            shortcut("c", "colour")
                            shortcut("⌘ ,", "settings")
                            gap()
                        }

                        // Unit Preferences
                        if step >= 7 {
                            typedPrompt("ares set unit-preference")
                            gap(6)
                        }
                        if step >= 8 {
                            unitSelector
                            gap(6)
                            // Command line — cursor blinks when awaiting confirm, stops after
                            HStack(spacing: 0) {
                                Text(aresPrompt).font(monoBold).foregroundStyle(grey)
                                Text("ares set unit-preference \(selectedUnit == 0 ? "metric" : "imperial")")
                                    .font(monoBold).foregroundStyle(orange)
                                Text("▌").font(mono).foregroundStyle(orange)
                                    .opacity(!unitConfirmed ? (showCursor ? 1 : 0) : 0)
                            }
                            .padding(.vertical, 2)
                            gap()
                        }

                        // Terrain source
                        if step >= 9 {
                            typedPrompt("ares set upscale-method")
                            gap(6)
                            ForEach(0..<min(upscaleDescLines, upscaleDescriptionItems.count), id: \.self) { index in
                                let item = upscaleDescriptionItems[index]
                                if item.text.isEmpty {
                                    gap()
                                } else {
                                    line(item.text, color: item.color)
                                }
                            }
                            if upscaleDescLines >= upscaleDescriptionItems.count {
                                gap()
                            }
                        }
                        if step >= 10 {
                            terrainSourceSelector
                            gap(6)
                            HStack(spacing: 0) {
                                Text(aresPrompt).font(monoBold).foregroundStyle(grey)
                                Text("ares set upscale-method \(currentTerrainSourceSelection.commandValue)")
                                    .font(monoBold).foregroundStyle(orange)
                                Text("▌").font(mono).foregroundStyle(orange)
                                    .opacity(!sourceConfirmed ? (showCursor ? 1 : 0) : 0)
                            }
                            .padding(.vertical, 2)
                            gap()
                        }

                        // Upscale init
                        if step >= 11 && shouldRunLocalRender {
                            commandLine("ares upscale init", active: pipeline.phase == .idle)
                        }

                        // Rendering progress
                        if pipeline.phase == .rendering || pipeline.phase == .complete {
                            gap(8)
                            renderingLog
                        }

                        // Launch
                        if step >= 13 {
                            gap()
                            commandLine("ares launch", active: step < 14)
                        }

                        // Launch output
                        if step >= 14 {
                            gap(6)
                            ForEach(0..<uiLabels.count, id: \.self) { i in
                                if uiStates[i] > 0 {
                                    loadingRow(uiLabels[i], result: "✓", done: uiStates[i] >= 2)
                                }
                            }
                        }

                        // (idle cursor removed — typing animation shows its own cursor)

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 540, alignment: .leading)

                    Spacer(minLength: 400)
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: step) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("bottom") }
            }
            .onChange(of: initStates) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: uiStates) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: selectedUnit) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: upscaleDescLines) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("bottom") }
            }
            .onChange(of: postRenderLines) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("bottom") }
            }
            .onChange(of: typedChars) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: pipeline.phase) { _, newPhase in
                withAnimation { proxy.scrollTo("bottom") }
                if newPhase == .complete {
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        postRenderLines = 1
                        try? await Task.sleep(for: .milliseconds(300))
                        postRenderLines = 2
                        try? await Task.sleep(for: .milliseconds(300))
                        postRenderLines = 3
                        try? await Task.sleep(for: .milliseconds(600))
                        step = 13
                        await typeCommand("ares launch")
                    }
                }
            }
            .onChange(of: pipeline.tier1Status) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: pipeline.tier2Status) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: pipeline.tier3Status) { _, _ in proxy.scrollTo("bottom") }
        }
        .overlay(alignment: .topLeading) {
            OnboardingTrafficLightView(barHeight: topBarHeight)
                .frame(width: 0, height: 0)
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.iBeam.push()
            case .ended: NSCursor.pop()
            }
        }
        .focusable()
        .onAppear {
            selectedTerrainSource = terrainSourceMode
            runSequence()
        }
        .onKeyPress(.return) {
            if step >= 8 && !unitConfirmed {
                confirmUnits()
                return .handled
            } else if step >= 10 && !sourceConfirmed {
                confirmTerrainSource()
                return .handled
            } else if shouldRunLocalRender && step >= 11 && pipeline.phase == .idle {
                pipeline.startRendering()
                return .handled
            } else if (pipeline.phase == .complete || canLaunchImmediately) && step >= 13 && step < 14 {
                launchUI()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            if step >= 10 && !sourceConfirmed {
                selectedTerrainSource = TerrainSource.prebaked.rawValue
                return .handled
            }
            guard step >= 8 && !unitConfirmed else { return .ignored }
            selectedUnit = 0
            return .handled
        }
        .onKeyPress(.downArrow) {
            if step >= 10 && !sourceConfirmed {
                selectedTerrainSource = TerrainSource.local.rawValue
                return .handled
            }
            guard step >= 8 && !unitConfirmed else { return .ignored }
            selectedUnit = 1
            return .handled
        }
        .onKeyPress(.init("l")) {
            if let url = URL(string: "https://github.com/BenjaminHoppe/ares-preview") {
                NSWorkspace.shared.open(url)
            }
            return .handled
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(530))
                showCursor.toggle()
            }
        }
    }

    // MARK: - Sequence

    private func runSequence() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            step = 1
            await typeCommand("cd /Applications/Ares\\ Preview.app")
            try? await Task.sleep(for: .milliseconds(400))

            step = 2  // header
            try? await Task.sleep(for: .milliseconds(800))

            step = 3
            await typeCommand("ares init")
            try? await Task.sleep(for: .milliseconds(200))
            for i in 0..<initLabels.count {
                initStates[i] = 1
                try? await Task.sleep(for: .milliseconds(Int.random(in: 300...500)))
                initStates[i] = 2
                try? await Task.sleep(for: .milliseconds(60))
            }
            step = 4
            try? await Task.sleep(for: .milliseconds(400))

            step = 5
            await typeCommand("ares help")
            try? await Task.sleep(for: .milliseconds(200))
            step = 6
            try? await Task.sleep(for: .milliseconds(600))

            step = 7
            await typeCommand("ares set unit-preference")
            try? await Task.sleep(for: .milliseconds(200))
            step = 8  // waits for return
        }
    }

    private func confirmUnits() {
        useImperialUnits = selectedUnit == 1
        unitConfirmed = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))

            step = 9
            await typeCommand("ares set upscale-method")
            try? await Task.sleep(for: .milliseconds(300))

            for index in 1...upscaleDescriptionItems.count {
                upscaleDescLines = index
                try? await Task.sleep(for: .milliseconds(120))
            }

            try? await Task.sleep(for: .milliseconds(300))
            step = 10
        }
    }

    private func confirmTerrainSource() {
        terrainSourceMode = currentTerrainSourceSelection.rawValue
        sourceConfirmed = true

        Task {
            try? await Task.sleep(for: .milliseconds(800))

            if shouldRunLocalRender {
                step = 11
                await typeCommand("ares upscale init")
            } else {
                step = 13
                await typeCommand("ares launch")
            }
        }
    }

    private func launchUI() {
        Task {
            step = 14
            try? await Task.sleep(for: .milliseconds(200))

            for i in 0..<uiLabels.count {
                uiStates[i] = 1
                try? await Task.sleep(for: .milliseconds(Int.random(in: 150...300)))
                uiStates[i] = 2
                try? await Task.sleep(for: .milliseconds(40))
            }

            try? await Task.sleep(for: .milliseconds(500))
            hasCompletedSetup = true
        }
    }

    private func typeCommand(_ command: String) async {
        typedChars[command] = 0
        for i in 1...command.count {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 35...70)))
            typedChars[command] = i
        }
    }

    private var currentTerrainSourceSelection: TerrainSource {
        TerrainSource(rawValue: selectedTerrainSource) ?? .prebaked
    }

    private var canLaunchImmediately: Bool {
        currentTerrainSourceSelection == .prebaked || TerrainAssetPaths.localRenderReady
    }

    private var shouldRunLocalRender: Bool {
        currentTerrainSourceSelection == .local && !TerrainAssetPaths.localRenderReady
    }

    private var upscaleDescriptionItems: [(text: String, color: Color?)] {
        [
            ("Ares can run a local neural network called Ares SR that upscales", nil),
            ("Mars imagery using your Mac's Neural Engine. This one time process", nil),
            ("takes ~ 15 minutes.", nil),
            ("", nil), // line break
            ("Pre-upscaled imagery generated on an M4 MacBook Pro ships with Ares", nil),
            ("so you can explore immediately with no first-time render. You can", nil),
            ("switch anytime later in Settings.", nil),
            ("", nil), // line break
            ("Press L to learn more (Ares Preview GitHub)", .white),
        ]
    }

    // MARK: - Rendering

    private var renderingLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            tierLog(tier: "tier 1", source: "ctx", res: "6 m/px", status: pipeline.tier1Status)
            tierLog(tier: "tier 2", source: "hirise", res: "1 m/px", status: pipeline.tier2Status)
            tierLog(tier: "tier 3", source: "hirise", res: "25 cm/px", status: pipeline.tier3Status)
            gap(8)
            stat("time elapsed", formatElapsed(pipeline.elapsedSeconds))
            stat("generated", ByteCountFormatter.string(fromByteCount: pipeline.totalGeneratedBytes, countStyle: .file))
            if pipeline.averageInferenceMs > 0 {
                stat("average inference", String(format: "%.0f ms", pipeline.averageInferenceMs))
            }
            if pipeline.phase == .rendering {
                gap(8)
                HStack(spacing: 6) {
                    Text("▸").foregroundStyle(orange)
                    Text(pipeline.currentTileID).foregroundStyle(grey)
                }
                .font(mono)
            }
            if pipeline.phase == .complete {
                gap()
                line("upscaling complete.", color: orange)
                if postRenderLines >= 1 {
                    gap()
                    line("This is an early research preview. Ares and Applied")
                }
                if postRenderLines >= 2 {
                    line("Curiosity have not been publicly announced.")
                }
                if postRenderLines >= 3 {
                    line("Please keep this between us for now.")
                }
            }
        }
    }

    // MARK: - Components

    private func typedPrompt(_ command: String, prompt: String? = nil) -> some View {
        let p = prompt ?? aresPrompt
        let chars = typedChars[command] ?? command.count
        let visible = String(command.prefix(chars))
        return HStack(spacing: 0) {
            Text(p).font(monoBold).foregroundStyle(grey)
            Text(visible).font(monoBold).foregroundStyle(orange)
            if chars < command.count {
                Text("▌").font(mono).foregroundStyle(orange).opacity(showCursor ? 1 : 0)
            }
        }
        .padding(.vertical, 2)
    }

    /// Single stable view for interactive commands — cursor toggles without re-rendering
    private func commandLine(_ command: String, active: Bool) -> some View {
        let chars = typedChars[command] ?? command.count
        let visible = String(command.prefix(chars))
        return HStack(spacing: 0) {
            Text(aresPrompt).font(monoBold).foregroundStyle(grey)
            Text(visible).font(monoBold).foregroundStyle(orange)
            Text("▌").font(mono).foregroundStyle(orange)
                .opacity(active ? (showCursor ? 1 : 0) : 0)
        }
        .padding(.vertical, 2)
    }

    private var cursorLine: some View {
        HStack(spacing: 0) {
            Text(aresPrompt).font(monoBold).foregroundStyle(grey)
            Text("▌").font(mono).foregroundStyle(orange).opacity(showCursor ? 1 : 0)
        }
        .padding(.top, 4)
    }

    private func loadingRow(_ label: String, result: String, done: Bool) -> some View {
        HStack(spacing: 0) {
            Text(label).font(mono).foregroundStyle(grey)
            Spacer()
            if done {
                Text(result).font(monoBold).foregroundStyle(orange)
            }
        }
        .padding(.vertical, 1)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(monoBold).foregroundStyle(orange)
    }

    private func line(_ text: String, color: Color? = nil) -> some View {
        Text(text).font(mono).foregroundStyle(color ?? grey).padding(.vertical, 1)
    }

    private func gap(_ height: CGFloat = 16) -> some View {
        Color.clear.frame(height: height)
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        HStack(spacing: 0) {
            Text(key).font(monoBold).foregroundStyle(orange)
                .frame(width: 50, alignment: .leading)
            Text(action).font(mono).foregroundStyle(grey)
        }
        .padding(.vertical, 1)
    }

    private var unitSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            unitRow("metric (km, m)", isSelected: selectedUnit == 0)
            unitRow("imperial (mi, ft)", isSelected: selectedUnit == 1)
            gap(4)
            Text("use ▲ ▼ to select, press return to confirm")
                .font(mono).foregroundStyle(grey)
        }
    }

    private var terrainSourceSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            terrainSourceRow(TerrainSource.prebaked, isSelected: currentTerrainSourceSelection == .prebaked)
            terrainSourceRow(TerrainSource.local, isSelected: currentTerrainSourceSelection == .local)
            gap(4)
            Text("use ▲ ▼ to select, press return to confirm")
                .font(mono).foregroundStyle(grey)
        }
    }

    private func unitRow(_ label: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(isSelected ? "▸" : " ")
                .font(mono).foregroundStyle(orange)
            Text(label).font(mono)
                .foregroundStyle(isSelected ? (unitConfirmed ? orange : .white) : grey)
        }
    }

    private func terrainSourceRow(_ source: TerrainSource, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(isSelected ? "▸" : " ")
                .font(mono).foregroundStyle(orange)
            Text(source.onboardingLabel)
                .font(mono)
                .foregroundStyle(isSelected ? (sourceConfirmed ? orange : .white) : grey)
        }
    }

    private func tierLog(tier: String, source: String, res: String, status: RenderingPipeline.TierStatus) -> some View {
        let color = tierActive(status) ? Color.white.opacity(0.7) : grey
        return HStack(spacing: 0) {
            Text(tier).font(mono).foregroundStyle(color)
                .frame(width: 52, alignment: .leading)
            Text(source).font(mono).foregroundStyle(color)
                .frame(width: 60, alignment: .leading)
            Text(res).font(mono).foregroundStyle(color)
                .frame(width: 76, alignment: .trailing)
            Spacer()
            switch status {
            case .pending:
                Text("·").font(mono).foregroundStyle(grey)
            case .active(let completed, let total):
                let pct = total > 0 ? Int(Double(completed) / Double(total) * 100) : 0
                let filled = pct / 5
                let empty = 20 - filled
                HStack(spacing: 0) {
                    Spacer()
                    Text("\(String(repeating: "█", count: filled))\(String(repeating: "░", count: empty))  \(String(format: "%3d", completed))/\(total)")
                        .font(mono).foregroundStyle(orange)
                }
            case .done(let tiles):
                HStack(spacing: 0) {
                    Spacer()
                    Text("\(String(repeating: "█", count: 20))  ✓ \(tiles) tiles")
                        .font(mono).foregroundStyle(orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func tierActive(_ status: RenderingPipeline.TierStatus) -> Bool {
        if case .active = status { return true }; return false
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label).font(mono).foregroundStyle(grey)
            Spacer()
            Text(value).font(mono).foregroundStyle(grey)
        }
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let m = Int(seconds) / 60; let s = Int(seconds) % 60
        return String(format: "%dm %02ds", m, s)
    }
}

// Traffic light positioner that keeps window background black
private struct OnboardingTrafficLightView: NSViewRepresentable {
    let barHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = OnboardingTrafficLightNSView(barHeight: barHeight)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class OnboardingTrafficLightNSView: NSView {
    let barHeight: CGFloat
    private var observer: NSObjectProtocol?

    init(barHeight: CGFloat) {
        self.barHeight = barHeight
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.isOpaque = true
        window.backgroundColor = .black
        DispatchQueue.main.async { self.reposition() }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in self?.reposition() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let obs = observer { NotificationCenter.default.removeObserver(obs) }
    }

    func reposition() {
        guard let window = window, !window.styleMask.contains(.fullScreen) else { return }

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = 16
            frameView.layer?.masksToBounds = true
        }

        let targetCenterFromTop = barHeight / 2
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { type in
            guard let button = window.standardWindowButton(type),
                  let superview = button.superview else { return }
            var f = button.frame
            f.origin.y = superview.bounds.height - targetCenterFromTop - f.height / 2
            f.origin.x += 4
            button.setFrameOrigin(f.origin)
        }
    }
}
