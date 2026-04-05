import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ContentViewModel.self) private var vm
    @State private var isDroppingFolder = false

    var body: some View {
        @Bindable var settings = vm.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if vm.isProcessing {
                    Text("Settings locked during processing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 4)
                }

                // Output Mode
                VStack(alignment: .leading, spacing: 6) {
                    Text("Output")
                        .font(.headline)

                    Picker("", selection: $settings.outputMode) {
                        ForEach(OutputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // M4A Bitrate (shown when M4A or Both)
                if vm.settings.outputMode != .wav {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("M4A Bitrate")
                            .font(.headline)

                        Picker("", selection: $settings.m4aBitrate) {
                            ForEach(M4ABitrate.allCases, id: \.self) { br in
                                Text(br.label).tag(br)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                Divider()

                // Level Riding
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $settings.levelRiding) {
                        Text("Level Riding")
                            .font(.headline)
                    }
                    .toggleStyle(.switch)

                    Text("Attenuates loud peaks and boosts quiet passages to reduce dynamic range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.levelRiding {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Aggressiveness")
                                    .font(.subheadline)
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
                            HStack {
                                Text("Gentle")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("Heavy")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                        .transition(.opacity)
                    }
                }

                Divider()

                // Loudness Normalization
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $settings.loudnormEnabled) {
                        Text("Loudness Normalization")
                            .font(.headline)
                    }
                    .toggleStyle(.switch)

                    Text("Two-pass EBU R128 — brings the integrated loudness to a target LUFS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.loudnormEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Target")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.0f LUFS", settings.loudnormTarget))
                                    .font(.system(size: 12).monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.loudnormTarget, in: -23 ... -14, step: 1)
                            HStack {
                                Text("-23 (broadcast)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("-14 (streaming)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                        .transition(.opacity)
                    }
                }

                Divider()

                // Output Directory
                VStack(alignment: .leading, spacing: 6) {
                    Text("Output Folder")
                        .font(.headline)

                    HStack {
                        Text(vm.settings.resolvedOutputDir(fallback: nil).lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(isDroppingFolder ? Color.accentColor : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Choose…") {
                            vm.chooseOutputDir()
                        }
                        .font(.system(size: 12))
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isDroppingFolder ? Color.accentColor : Color.clear,
                                lineWidth: 1.5
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

                    if vm.settings.outputDir != nil {
                        Button("Reset to Desktop") {
                            vm.settings.outputDir = nil
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(16)
        }
        .disabled(vm.isProcessing)
    }
}
