import SwiftUI

struct SettingsView: View {
    @Environment(ContentViewModel.self) private var vm

    var body: some View {
        @Bindable var settings = vm.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

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

                    Text("Attenuates loud sections only — never boosts quiet ones")
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
                        Text(vm.settings.resolvedOutputDir.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Choose…") {
                            vm.chooseOutputDir()
                        }
                        .font(.system(size: 12))
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
    }
}
