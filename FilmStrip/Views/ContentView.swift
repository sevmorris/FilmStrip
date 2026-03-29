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
            // Left pane: drop zone or file content
            mainPane
                .frame(minWidth: 500)

            // Right pane: settings (collapsible)
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
            if vm.sourceURL == nil {
                dropZoneView
            } else {
                fileContentView
            }

            if !vm.log.isEmpty {
                // Status panel
                Divider()
                statusPaneView

                // Draggable divider
                dragHandle

                // Verbose log console
                logView
                    .frame(height: consoleHeight)
            }
        }
    }

    // MARK: - Status pane

    private var statusPaneView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(vm.statusLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    if line.hasPrefix("Export complete") {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 11))
                    } else if line.hasPrefix("Error:") {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 11))
                    } else if line.hasPrefix("---") {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    } else {
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "- ").union(.whitespaces)))
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

    // MARK: - Drop Zone

    private var dropZoneView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                )
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .opacity(isTargeted ? 1.0 : 0.75)

                Text("Drop a video file here")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)

                Text("MKV, MP4, MOV, AVI and more")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Open File…") {
                    vm.openFilePicker()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            // Load the URL from the file URL provider
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                Task { @MainActor in
                    var resolvedURL: URL?
                    if let data = item as? Data,
                       let urlStr = String(data: data, encoding: .utf8),
                       let url = URL(string: urlStr) {
                        resolvedURL = url
                    } else if let url = item as? URL {
                        resolvedURL = url
                    }
                    if let url = resolvedURL {
                        let ext = url.pathExtension.lowercased()
                        if ContentViewModel.supportedExtensions.contains(ext) {
                            await vm.loadFile(url: url)
                        } else {
                            vm.errorMessage = "Unsupported file type: .\(ext)"
                        }
                    }
                }
            }
            return true
        }
    }

    // MARK: - File Content View

    private var fileContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header
            fileHeader
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            if vm.isInspecting {
                VStack {
                    ProgressView("Inspecting audio streams…")
                        .progressViewStyle(.circular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.tracks.isEmpty {
                VStack {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No audio tracks found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Track list
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(vm.tracks.count) audio track\(vm.tracks.count == 1 ? "" : "s") detected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Select All") {
                            vm.selectedIDs = Set(vm.tracks.map { $0.id })
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)

                        Text("·")
                            .foregroundStyle(.secondary)

                        Button("None") {
                            vm.selectedIDs = []
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    TrackListView()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
            }

            // Output results
            if vm.hasOutput && !vm.isProcessing {
                Divider()
                outputResultsView
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }

            // Progress indicator during processing
            if vm.isProcessing {
                Divider()
                HStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                    Text("Processing…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        vm.cancelProcessing()
                    }
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fileHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.movieTitle)
                    .font(.headline)
                    .lineLimit(1)

                if let url = vm.sourceURL {
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
        }
    }

    private var outputResultsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Export complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline.weight(.medium))

            ForEach(vm.outputURLs, id: \.path) { url in
                HStack {
                    Image(systemName: url.pathExtension.lowercased() == "wav" ? "waveform" : "music.note")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Button {
                vm.revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
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
            Button {
                vm.startProcessing()
            } label: {
                Label("Process", systemImage: "arrow.down.circle.fill")
            }
            .disabled(!vm.canProcess)
            .help("Export selected tracks")

            Button {
                vm.clear()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .disabled(vm.sourceURL == nil && !vm.hasOutput)
            .help("Clear and start over")

            Divider()

            Button {
                withAnimation { vm.showSettings.toggle() }
            } label: {
                Label("Settings", systemImage: vm.showSettings ? "sidebar.right" : "sidebar.right")
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

#Preview {
    ContentView()
        .environment(ContentViewModel())
        .frame(width: 780, height: 520)
}
