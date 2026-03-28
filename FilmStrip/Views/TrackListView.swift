import SwiftUI

struct TrackListView: View {
    @Environment(ContentViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                Text("")
                    .frame(width: 28)
                Text("#")
                    .frame(width: 36, alignment: .leading)
                Text("Language")
                    .frame(width: 100, alignment: .leading)
                Text("Codec")
                    .frame(width: 70, alignment: .leading)
                Text("Channels")
                    .frame(width: 80, alignment: .leading)
                Text("Bitrate")
                    .frame(minWidth: 80, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.tracks) { track in
                        TrackRow(track: track)
                        if track.id != vm.tracks.last?.id {
                            Divider()
                                .padding(.leading, 40)
                        }
                    }
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }
}

struct TrackRow: View {
    @Environment(ContentViewModel.self) private var vm
    let track: AudioTrack

    private var isSelected: Bool {
        vm.selectedIDs.contains(track.id)
    }

    var body: some View {
        Button {
            if vm.selectedIDs.contains(track.id) {
                vm.selectedIDs.remove(track.id)
            } else {
                vm.selectedIDs.insert(track.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 28)

                    Text("a\(track.audioIndex)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)

                    Text(track.displayLanguage)
                        .frame(width: 100, alignment: .leading)
                        .lineLimit(1)

                    Text(track.displayCodec)
                        .frame(width: 70, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(track.displayChannels)
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)

                    Text(track.displayBitrate)
                        .frame(minWidth: 80, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let title = track.title {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 28)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
    }
}
