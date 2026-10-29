// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local playback with source-bound controls and locally extrapolated progress.
import SwiftUI

struct MediaProgressSchedule: TimelineSchedule {
  let active: Bool
  func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
    // Playback needs four local updates per second, without a display-link animation clock.
    if active { return AnySequence(PeriodicTimelineSchedule(from:startDate,by:0.25).entries(from:startDate,mode:mode)) }
    return AnySequence(CollectionOfOne(startDate))
  }
}

struct MediaView: View {
  let model: MacPlaybackModel
  var compact = false
  var overview = false
  var origin: String?
  var visible = true
  var open: (() -> Void)? = nil
  @State private var expanded = false
  private var detailed: Bool { !compact || expanded }
  @State private var scrub: Double?
  @State private var cancelled = false
  @State private var target: MediaPlayback?
  @Environment(\.colorScheme) private var scheme
  private var media: MediaPlayback { model.playback }
  var body: some View {
    Group {
      if overview { overviewContent } else { standardContent }
    }
    .onChange(of: media.revision) { _, _ in
      if target != nil { cancelled = true }; target = nil; scrub = nil
    }
  }

  private var standardContent: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      if compact {
        HStack {
          if let open {
            Button(action: open) { HStack { Label("Now playing", systemImage: "music.note"); Image(systemName: "chevron.forward").font(.caption).accessibilityHidden(true) }.font(.headline).contentShape(Rectangle()) }
              .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("Open Now Playing")
          } else { Label("Now playing", systemImage: "music.note").font(.headline) }
          Spacer()
          Text("On this Mac").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
          Button { expanded.toggle() } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
            .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("More playback controls")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
      } else {
        HStack(spacing: 8) {
          Spacer()
          Text("Player").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
          Picker("Player",selection:Binding(get:{ model.selection },set:{ id in model.command(source:id,revision:model.catalogue,action:id.isEmpty ? 6:5) })) {
            Text("Auto").tag("")
            ForEach(model.sources) { Text($0.name).tag($0.id) }
          }
          .labelsHidden()
          .frame(maxWidth: 180)
          .disabled(model.busy)
          Menu {
            Button("Refresh controls", action: model.refreshCapabilities).disabled(model.busy)
            if model.volumeCandidate && model.playerVolume == nil {
              Button("Allow player volume…", action: model.requestPermission)
              Button("Verify player volume", action: model.verifyPlayerVolume).disabled(model.busy)
            }
            if !model.feedback.isEmpty { Button("Retry observation", action: model.retryObservation) }
          } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
            .menuStyle(.borderlessButton).aniCeControlFeedback()
            .fixedSize().accessibilityLabel("Playback options")
        }
      }
      if compact && (expanded || model.sources.count > 1) {
        Picker("Player",selection:Binding(get:{ model.selection },set:{ id in model.command(source:id,revision:model.catalogue,action:id.isEmpty ? 6:5) })) {
          Text("Auto").tag("")
          ForEach(model.sources) { Text($0.name).tag($0.id) }
        }.disabled(model.busy)
      }
      if !media.source.isEmpty {
        if compact {
          HStack(alignment:.top,spacing:12) {
            artwork(size: 50)
            VStack(alignment:.leading,spacing:2) {
              trackMetadata(centered: false, compact: true)
              Text(media.player).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
            }
          }
          progress
          transport(centered: true)
        } else {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
              artwork(size: 164)
              playbackDetails(centered: false).frame(minWidth: 300, maxWidth: 340)
            }
            VStack(alignment: .leading, spacing: 18) {
              artwork(size: 128)
              playbackDetails(centered: false)
            }
          }
          .frame(maxWidth: .infinity, alignment: .center)
          if model.displayedVolume != nil {
            Divider().padding(.vertical, 4)
            PlayerVolumeView(model: model)
          }
          if media.actions & 16 != 0 { Button("Allow playback control…") { model.requestPermission() } }
        }
      } else if !compact {
        Text(model.selection.isEmpty ? "Play media on this Mac to see it here.":"Waiting for playback information from the selected player.").foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if compact && detailed {
        PlayerVolumeView(model:model)
      }
      if !model.feedback.isEmpty && detailed {
        Text(model.feedback).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
        if media.source.isEmpty { Button("Retry observation") { model.retryObservation() } }
      }
    }
      .tint(AniCePalette.accent(scheme))
      .padding(compact ? 0 : 20)
      .frame(maxWidth: compact ? .infinity : 620, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: compact ? .leading : .top)
      .background(Color.clear)
      .onChange(of:detailed) { _, value in
        if !value { cancelled = target != nil; target = nil; scrub = nil }
      }
      .onChange(of:media.revision) { _,_ in if target != nil { cancelled=true }; target=nil; scrub=nil }
  }

  private func artwork(size: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8).fill(AniCePalette.secondarySurface(scheme))
      if let bytes = model.artwork, let image = NSImage(data: bytes) {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: "music.note").font(size < 100 ? .title2 : .largeTitle).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityHidden(true)
  }

  @ViewBuilder private func trackMetadata(centered: Bool, compact: Bool = false) -> some View {
    if !media.title.isEmpty { Text(media.title).font(compact ? .body.weight(.medium) : .system(size: 22, weight: .medium)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(centered ? .center : .leading) }
    if !media.artist.isEmpty { Text(media.artist).font(compact ? .subheadline : .callout).foregroundStyle(AniCePalette.secondaryText(scheme)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(centered ? .center : .leading) }
  }

  private func playbackDetails(centered: Bool) -> some View {
    VStack(alignment: centered ? .center : .leading, spacing: 4) {
      trackMetadata(centered: centered)
      progress
        .padding(.top, 12)
        .padding(.bottom, 4)
      transport(centered: centered)
    }
    .frame(maxWidth: 340, alignment: centered ? .center : .leading)
  }

  private func transport(centered: Bool) -> some View {
    HStack(spacing: 12) {
      control("backward.end.fill", "Previous", 2, 2)
      control(media.state == 1 ? "pause.fill" : "play.fill", media.state == 1 ? "Pause" : "Play", 1, 1)
      control("forward.end.fill", "Next", 3, 4)
    }
    .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
  }
  private var overviewContent: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Button { open?() } label: {
          HStack(spacing: 8) {
            Text("Now Playing").font(.system(size: 14, weight: .medium))
            Image(systemName: "chevron.forward").font(.caption).accessibilityHidden(true)
          }.contentShape(Rectangle())
        }.buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("Open Now Playing")
        Spacer()
        Text(origin ?? "This Mac").font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
        Button { expanded.toggle() } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
          .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("More playback controls")
          .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      }
      HStack(alignment: .top, spacing: 16) {
        ZStack {
          RoundedRectangle(cornerRadius: 8).fill(AniCePalette.secondarySurface(scheme))
          if let bytes = model.artwork, let image = NSImage(data: bytes) {
            Image(nsImage: image).resizable().scaledToFit()
          } else { Image(systemName: "music.note").font(.title2).foregroundStyle(AniCePalette.secondaryText(scheme)) }
        }.frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 8) {
          if !media.title.isEmpty { Text(media.title).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true) }
          if !media.artist.isEmpty { Text(media.artist).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme)) }
          if !media.player.isEmpty { Text(media.player).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)) }
          progress
          HStack(spacing: 16) {
            control("backward.end", "Previous", 2, 2)
            control(media.state == 1 ? "pause" : "play", media.state == 1 ? "Pause" : "Play", 1, 1)
            control("forward.end", "Next", 3, 4)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if expanded {
        Picker("Player", selection: Binding(get: { model.selection }, set: { id in
          model.command(source: id, revision: model.catalogue, action: id.isEmpty ? 6 : 5)
        })) {
          Text("Auto").tag("")
          ForEach(model.sources) { Text($0.name).tag($0.id) }
        }.disabled(model.busy)
        PlayerVolumeView(model: model)
        if media.actions & 16 != 0 { Button("Allow playback control…") { model.requestPermission() } }
      }
      if !model.feedback.isEmpty { Text(model.feedback).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)) }
    }.foregroundStyle(AniCePalette.primaryText(scheme)).tint(AniCePalette.accent(scheme))
  }

  private var progress: some View {
    TimelineView(MediaProgressSchedule(active: media.state == 1 && media.position >= 0 && visible)) { _ in
      let elapsed = media.elapsed(at: ProcessInfo.processInfo.systemUptime)
      if overview {
        HStack(spacing: 10) {
          if media.position >= 0 { Text(Self.time(scrub ?? elapsed)) }
          if media.actions & 8 != 0 && media.duration > 0 { seekSlider(elapsed: elapsed).controlSize(.mini) }
          else { Spacer(minLength: 0) }
          if media.duration > 0 { Text(Self.time(Double(media.duration) / 1000)) }
        }.font(.caption.monospacedDigit()).foregroundStyle(AniCePalette.secondaryText(scheme))
      } else {
        HStack(spacing: 10) {
          if media.position >= 0 { Text(Self.time(scrub ?? elapsed)) }
          if media.actions & 8 != 0 && media.duration > 0 { seekSlider(elapsed: elapsed).controlSize(.small) }
          else { Spacer(minLength: 0) }
          if media.duration > 0 { Text(Self.time(Double(media.duration) / 1000)) }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
    }
  }

  private func seekSlider(elapsed: Double) -> some View {
    Slider(value:Binding(get:{scrub ?? elapsed},set:{ value in
                guard !cancelled else { return }; if target == nil { target=media }; scrub=value
              }),in:0...(Double(media.duration)/1000),onEditingChanged:{ editing in
                if editing { cancelled=false; target=media; scrub=elapsed }
                else { if !cancelled, let captured=target, captured.source==media.source, captured.revision==media.revision, let value=scrub { model.command(source:captured.source,revision:captured.revision,action:4,value:Int64(value*1000)) }; target=nil; scrub=nil; cancelled=false }
              }).disabled(model.busy).accessibilityLabel("Playback position")
  }

  private func control(_ symbol: String,_ label: String,_ action: Int64,_ mask: Int64) -> some View {
    Button { model.command(source:media.source,revision:media.revision,action:action) } label: {
      Image(systemName:symbol)
        .frame(width: action == 1 ? 40 : 32, height: 32)
        .foregroundStyle(action == 1 && !overview ? AniCePalette.onAccent(scheme) : AniCePalette.primaryText(scheme))
        .background { if action == 1 { RoundedRectangle(cornerRadius: 7).fill(overview ? AniCePalette.subtleAccent(scheme) : AniCePalette.accent(scheme)) } }
    }.buttonStyle(AniCeHoverButtonStyle(prominent: action == 1 && !overview))
      .disabled(model.busy || media.actions & mask == 0).accessibilityLabel(label)
  }
  static func time(_ seconds: Double) -> String { let value=Int(max(0,seconds)); return String(format:"%d:%02d",value/60,value%60) }
}
