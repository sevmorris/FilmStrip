import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ContentViewModel.self) private var vm
    @State private var isTargeted = false
    @State private var consoleHeight: CGFloat = 160
    @State private var dragBaseHeight: CGFloat = 160

    var body: some View {
        @Bindable var vm = vm

        HSplitView {
            mainPane
                .frame(minWidth: 500)

            if vm.showSettings {
                SettingsView()
                    .frame(width: 220)
                    .frame(minWidth: 200, maxWidth: 260)
            }
        }
        .toolbar {
            toolbarContent
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(isPresented: $vm.showHelp) {
            HelpView()
        }
    }

    // MARK: - Main pane

    @ViewBuilder
    private var mainPane: some View {
        VStack(spacing: 0) {
            if vm.items.isEmpty {
                dropZoneView
            } else {
                queueListView
            }

            if !vm.log.isEmpty {
                Divider()
                statusPaneView

                dragHandle

                logView
                    .frame(height: consoleHeight)
            }
        }
    }

    // MARK: - Queue list

    private var queueListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(vm.items) { item in
                    QueueRowView(item: item)
                        .background(item.status == .processing
                            ? Color.accentColor.opacity(0.04)
                            : Color.clear)
                    Divider()
                }

                Button {
                    vm.openFilePicker()
                } label: {
                    Label("Add more files…", systemImage: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            vm.handleDrop(providers: providers)
        }
    }

    // MARK: - Status pane

    private var statusPaneView: some View {
        // Show only the most recent lines so the pane doesn't grow tall enough
        // to push the queue list off screen. Full history is in the log below.
        let visibleLines = Array(vm.statusLines.suffix(6))
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    if line.hasPrefix("Export complete") {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 11))
                    } else if line.hasPrefix("Error:") {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 11))
                    } else if line.hasPrefix("---") || line.hasPrefix("──") {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    } else {
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "─- ").union(.whitespaces)))
                        .font(.system(size: 12))
                        .foregroundStyle(line.hasPrefix("Export complete") ? .primary : (line.hasPrefix("Error:") ? Color.red : Color.primary))
                        .lineLimit(1)
                }
            }

            if vm.isProcessing && vm.settings.loudnormEnabled {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Loudness normalization of a full film can take several minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var dragHandle: some View {
        ZStack {
            Color(nsColor: .separatorColor).opacity(0.6)
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 3)
        }
        .frame(height: 7)
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    consoleHeight = max(60, min(600, dragBaseHeight - value.translation.height))
                }
                .onEnded { _ in
                    dragBaseHeight = consoleHeight
                }
        )
    }

    // MARK: - Drop Zone (empty state)

    private var dropZoneView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Onboarding header
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)

                    Text("FilmStrip")
                        .font(.title.weight(.semibold))

                    Text("Listen to any movie like a radio drama")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Drop a video file and FilmStrip extracts the audio, downmixes surround to stereo, and applies dialog guard and dynamic leveling — optimized for headphone listening.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .padding(.top, 2)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)

                // Feature highlights
                VStack(spacing: 0) {
                    featureRow(icon: "waveform.and.magnifyingglass",
                               title: "Track detection",
                               detail: "Scans every audio stream. Auto-selects English tracks.")
                    Divider().padding(.leading, 44)
                    featureRow(icon: "speaker.wave.3",
                               title: "Surround downmix",
                               detail: "Folds 5.1 and 7.1 to stereo using standard LoRo matrices.")
                    Divider().padding(.leading, 44)
                    featureRow(icon: "person.wave.2",
                               title: "Dialog guard",
                               detail: "Normalizes the center channel independently before the downmix.")
                    Divider().padding(.leading, 44)
                    featureRow(icon: "slider.horizontal.3",
                               title: "Level riding & loudness normalization",
                               detail: "Closes dynamic range, then targets a streaming-matched LUFS.")
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 32)

                // Drop target
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                        )
                        .animation(.easeInOut(duration: 0.15), value: isTargeted)

                    VStack(spacing: 10) {
                        Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                            .animation(.easeInOut(duration: 0.15), value: isTargeted)

                        Text("Drop video files here")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        Button("Open Files…") {
                            vm.openFilePicker()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(24)
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)

                Text("Supports MKV, MP4, MOV, AVI, M4V, TS, WMV, WebM and more")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            vm.handleDrop(providers: providers)
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
                .padding(.leading, 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
    }

    // MARK: - Log view

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(vm.log.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.log.joined(separator: "\n"), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .padding(5)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Copy log to clipboard")
            }
            .onChange(of: vm.log.count) { _, _ in
                if let last = vm.log.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.isProcessing {
                Button {
                    vm.cancelProcessing()
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
                .foregroundStyle(.red)
                .help("Cancel processing")
            } else {
                Button {
                    vm.startProcessing()
                } label: {
                    Label("Process", systemImage: "arrow.down.circle.fill")
                }
                .disabled(!vm.canProcess)
                .help("Export selected tracks")
            }

            Button {
                vm.clear()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .disabled(vm.items.isEmpty)
            .help("Clear queue")

            Divider()

            Button {
                withAnimation { vm.showSettings.toggle() }
            } label: {
                Label("Settings", systemImage: "sidebar.right")
            }
            .help(vm.showSettings ? "Hide Settings" : "Show Settings")

            Button {
                vm.showHelp = true
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("FilmStrip Help")
        }
    }
}

// MARK: - Queue Row

private struct QueueRowView: View {
    @Environment(ContentViewModel.self) private var vm
    let item: QueueItem

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                subtitleView
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if item.status == .done, !item.outputURLs.isEmpty {
                Button {
                    vm.revealInFinder(item: item)
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
            }

            Button {
                vm.removeItem(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.status == .processing)
            .help("Remove from queue")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .pending, .inspecting:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
        case .ready:
            Image(systemName: "circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 7))
        case .processing:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 15))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 15))
        }
    }

    @ViewBuilder private var subtitleView: some View {
        switch item.status {
        case .pending:
            Text("Pending…")
        case .inspecting:
            Text("Inspecting…")
        case .ready:
            if item.tracks.count > 1 {
                trackChips
            } else {
                HStack(spacing: 4) {
                    Text(item.trackSummary)
                    if item.languageUnknown {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("No language metadata was found. All tracks have been selected as a fallback.")
                    }
                }
            }
        case .processing:
            Text("Processing…")
        case .done:
            if item.outputURLs.isEmpty {
                Text("Done")
            } else {
                Text(item.outputURLs.map { $0.lastPathComponent }.joined(separator: "  ·  "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .failed(let msg):
            Text(msg)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var trackChips: some View {
        FlowLayout(spacing: 4) {
            ForEach(item.tracks) { track in
                let selected = item.selectedIDs.contains(track.id)
                Button {
                    vm.toggleTrack(itemID: item.id, trackID: track.id)
                } label: {
                    HStack(spacing: 4) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        Text(trackLabel(track))
                            .font(.system(size: 10))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        selected
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .controlColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(
                                selected ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor),
                                lineWidth: 0.5
                            )
                    )
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(trackTooltip(track))
            }
        }
    }

    private func trackLabel(_ track: AudioTrack) -> String {
        var parts: [String] = []
        parts.append(track.displayLanguage)
        parts.append(track.displayCodec)
        parts.append(track.displayChannels)
        return parts.joined(separator: " · ")
    }

    private func trackTooltip(_ track: AudioTrack) -> String {
        var parts: [String] = ["Track \(track.audioIndex + 1)"]
        if let title = track.title { parts.append(title) }
        parts.append(track.displayLanguage)
        parts.append(track.displayCodec)
        parts.append(track.displayChannels)
        if !track.displayBitrate.isEmpty { parts.append(track.displayBitrate) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews: subviews, in: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, in: bounds.width)
        for (view, origin) in zip(subviews, result.origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var origins: [CGPoint]
    }

    private func layout(subviews: Subviews, in maxWidth: CGFloat) -> LayoutResult {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }

        return LayoutResult(size: CGSize(width: totalWidth, height: y + rowHeight), origins: origins)
    }
}

#Preview {
    ContentView()
        .environment(ContentViewModel())
        .frame(width: 780, height: 520)
}
