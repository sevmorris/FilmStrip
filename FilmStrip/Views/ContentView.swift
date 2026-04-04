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

                Text("Drop video files here")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)

                Text("MKV, MP4, MOV, AVI and more")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Open Files…") {
                    vm.openFilePicker()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)

                Text("Best source codec: AAC › E-AC3 › AC3 › DTS")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            vm.handleDrop(providers: providers)
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
            Text(item.trackSummary)
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
}

#Preview {
    ContentView()
        .environment(ContentViewModel())
        .frame(width: 780, height: 520)
}
