import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ContentViewModel.self) private var vm
    @State private var isDroppingFolder = false

    var body: some View {
        @Bindable var settings = vm.settings

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if vm.isProcessing {
                    Text("Locked during processing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 8)
                }

                row(nil) {
                    Picker("", selection: $settings.outputMode) {
                        ForEach(OutputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                row(nil) {
                    Picker("", selection: $settings.m4aBitrate) {
                        ForEach(M4ABitrate.allCases, id: \.self) { br in
                            Text(br.label).tag(br)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .disabled(settings.outputMode == .wav)
                .opacity(settings.outputMode == .wav ? 0.4 : 1)
                .help(settings.outputMode == .wav ? "Only applies when output format is M4A" : "")

                sectionDivider

                row("Dialog Guard", caption: "5.1/7.1 — normalizes center channel before downmix.") {
                    Toggle("", isOn: $settings.dialogGuard)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                row("Stereo Assist", caption: "Stereo/mono — boosts quiet midrange dialog.") {
                    Toggle("", isOn: $settings.stereoDialogAssist)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                sectionDivider

                row("High Pass", caption: "80 Hz roll-off — removes rumble and LFE fold-in.") {
                    Toggle("", isOn: $settings.highPassFilter)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                row("Level Riding", caption: "Gentle peak control — tames action peaks without lifting ambience.") {
                    Toggle("", isOn: $settings.levelRiding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                row("Loudness Norm", caption: "Two-pass EBU R128 to a target LUFS.") {
                    Toggle("", isOn: $settings.loudnormEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if settings.loudnormEnabled {
                    row("Target") {
                        HStack(spacing: 6) {
                            Slider(value: $settings.loudnormTarget, in: -23 ... -14, step: 1)
                            Text(String(format: "%.0f", settings.loudnormTarget))
                                .font(.system(size: 11).monospaced())
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }

                sectionDivider

                VStack(alignment: .leading, spacing: 5) {
                    Text("OUTPUT FOLDER")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .kerning(0.4)

                    if let dir = vm.settings.outputDir {
                        Text(dir.lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(isDroppingFolder ? Color.accentColor : .secondary)
                            .help(dir.path)
                    } else {
                        Text("Not set — you'll be prompted when processing")
                            .font(.system(size: 11))
                            .foregroundStyle(isDroppingFolder ? Color.accentColor : .secondary)
                    }

                    HStack(spacing: 6) {
                        Button("Choose…") { vm.chooseOutputDir() }
                            .controlSize(.small)
                        if vm.settings.outputDir != nil {
                            Button("Reset") { vm.settings.outputDir = nil }
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
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
            .padding(12)
        }
        .background(.thinMaterial)
        .disabled(vm.isProcessing)
    }

    private var sectionDivider: some View {
        Divider().padding(.vertical, 6)
    }

    @ViewBuilder
    private func row<Content: View>(
        _ label: String?,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .kerning(0.4)
            }
            content()
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}
