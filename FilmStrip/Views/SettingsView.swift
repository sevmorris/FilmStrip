import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ContentViewModel.self) private var vm
    @State private var isDroppingFolder = false

    var body: some View {
        @Bindable var settings = vm.settings

        VStack(spacing: 0) {
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if vm.isProcessing {
                        Text("Settings locked during processing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    // Row 1: Output + profile
                    HStack(alignment: .top, spacing: 24) {
                        settingsGroup("Output") {
                            Picker("", selection: $settings.outputMode) {
                                ForEach(OutputMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Picker("", selection: $settings.m4aBitrate) {
                                ForEach(M4ABitrate.allCases, id: \.self) { br in
                                    Text(br.label).tag(br)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .opacity(settings.outputMode == .wav ? 0.35 : 1)
                            .disabled(settings.outputMode == .wav)
                        }
                        .frame(maxWidth: 280)

                        settingsGroup("Quick Profile") {
                            Picker("", selection: $settings.processingProfile) {
                                ForEach(ProcessingProfile.allCases, id: \.self) { profile in
                                    Text(profile.label).tag(profile)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: settings.processingProfile) { _, profile in
                                vm.applyProcessingProfile(profile)
                            }

                            Text("Sets dialog, leveling, and loudness as a bundle.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Divider()

                    // Row 2: Dialog + dynamics
                    HStack(alignment: .top, spacing: 24) {
                        settingsGroup("Dialog") {
                            toggleRow("Dialog Guard", isOn: $settings.dialogGuard)
                            caption("5.1/7.1 — normalizes center channel before downmix.")

                            labeledRow("Dialog level") {
                                Picker("", selection: $settings.dialogLevel) {
                                    ForEach(DialogLevel.allCases, id: \.self) { lvl in
                                        Text(lvl.label).tag(lvl)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }

                            toggleRow("Stereo Dialog Assist", isOn: $settings.stereoDialogAssist)
                            caption("Stereo/mono — normalizes mid (dialog) before level riding.")

                            if settings.dialogLevel != .normal && !settings.loudnormEnabled {
                                Text("Enable Loudness Normalization when using Boost or Strong.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        settingsGroup("Dynamics") {
                            toggleRow("High Pass Filter", isOn: $settings.highPassFilter)
                            caption("80 Hz roll-off — removes rumble and LFE fold-in.")

                            toggleRow("Level Riding", isOn: $settings.levelRiding)
                            if settings.levelRiding {
                                caption(settings.levelRidingPreset.shortDescription)

                                Toggle("Show advanced controls", isOn: $settings.levelRidingAdvanced)
                                    .font(.subheadline)

                                if settings.levelRidingAdvanced {
                                    HStack {
                                        Text("Aggressiveness")
                                        Spacer()
                                        Text("\(settings.levelAggressiveness)")
                                            .font(.system(size: 12).monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Slider(
                                        value: Binding(
                                            get: { Double(settings.levelAggressiveness) },
                                            set: { settings.levelAggressiveness = Int($0.rounded()) }
                                        ),
                                        in: 1...10,
                                        step: 1
                                    )
                                }
                            }

                            toggleRow("Loudness Normalization", isOn: $settings.loudnormEnabled)
                            if settings.loudnormEnabled {
                                HStack {
                                    Text("Target")
                                    Spacer()
                                    Text(String(format: "%.0f LUFS", settings.loudnormTarget))
                                        .font(.system(size: 12).monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settings.loudnormTarget, in: -23 ... -14, step: 1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Divider()

                    // Row 3: Output folder
                    settingsGroup("Output Folder") {
                        HStack {
                            Text(vm.settings.resolvedOutputDir(fallback: nil).lastPathComponent)
                                .font(.system(size: 12))
                                .foregroundStyle(isDroppingFolder ? Color.accentColor : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(vm.settings.resolvedOutputDir(fallback: nil).path)

                            Spacer()

                            Button("Choose…") { vm.chooseOutputDir() }
                                .font(.system(size: 12))

                            if vm.settings.outputDir != nil {
                                Button("Reset to Desktop") { vm.settings.outputDir = nil }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    isDroppingFolder ? Color.accentColor : Color.secondary.opacity(0.25),
                                    lineWidth: 1
                                )
                        )
                        .onDrop(of: [.fileURL], isTargeted: $isDroppingFolder) { providers in
                            guard let provider = providers.first else { return false }
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                Task { @MainActor in
                                    var resolved: URL?
                                    if let data = item as? Data,
                                       let str = String(data: data, encoding: .utf8),
                                       let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                        resolved = url
                                    } else if let url = item as? URL {
                                        resolved = url
                                    }
                                    if let url = resolved {
                                        var isDir: ObjCBool = false
                                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                                           isDir.boolValue {
                                            vm.settings.outputDir = url
                                        }
                                    }
                                }
                            }
                            return true
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .disabled(vm.isProcessing)
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.subheadline)
        }
        .toggleStyle(.switch)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
            content()
        }
    }
}
