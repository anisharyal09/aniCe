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
  var visible = true
  var playerPicker = true
  var open: () -> Void = {}
  @State private var scrub: Double?
  @State private var cancelled = false
  @State private var target: MediaPlayback?
  @Environment(\.colorScheme) private var scheme
  private var media: MediaPlayback { model.playback }
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      if compact {
        Button(action: open) {
          HStack {
            Text("Now Playing").font(.headline)
            Spacer()
            Image(systemName: "arrow.up.right")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(AniCePalette.secondaryText(scheme))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View phone controls")
      } else {
        HStack {
          Text("Now Playing").font(.headline)
          Spacer()
        }
      }
      if playerPicker && (!compact || model.sources.count > 1) {
        Picker("Player",selection:Binding(get:{ model.selection },set:{ id in model.command(source:id,revision:model.catalogue,action:id.isEmpty ? 6:5) })) {
          Text("Auto").tag("")
          ForEach(model.sources) { Text($0.name).tag($0.id) }
        }.disabled(model.busy)
      }
      if !media.source.isEmpty {
        HStack(alignment:.top,spacing:12) {
          if let bytes=model.artwork, let image=NSImage(data:bytes) {
            Image(nsImage:image).resizable().scaledToFit().frame(width:compact ? 44:96,height:compact ? 44:96).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true)
          }
          VStack(alignment:.leading,spacing:2) {
            if !media.title.isEmpty { Text(media.title).font(.body.weight(.medium)).fixedSize(horizontal:false,vertical:true) }
            if !media.artist.isEmpty { Text(media.artist).font(.subheadline).foregroundStyle(AniCePalette.secondaryText(scheme)).fixedSize(horizontal:false,vertical:true) }
            Text(media.player).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
          }
        }
        TimelineView(MediaProgressSchedule(active:media.state == 1 && media.position >= 0 && visible)) { _ in
          let elapsed=media.elapsed(at:ProcessInfo.processInfo.systemUptime)
          VStack(spacing:2) {
            if media.actions & 8 != 0, media.duration>0 {
              Slider(value:Binding(get:{scrub ?? elapsed},set:{ value in
                guard !cancelled else { return }; if target == nil { target=media }; scrub=value
              }),in:0...(Double(media.duration)/1000),onEditingChanged:{ editing in
                if editing { cancelled=false; target=media; scrub=elapsed }
                else { if !cancelled, let captured=target, captured.source==media.source, captured.revision==media.revision, let value=scrub { model.command(source:captured.source,revision:captured.revision,action:4,value:Int64(value*1000)) }; target=nil; scrub=nil; cancelled=false }
              }).disabled(model.busy).accessibilityLabel("Playback position")
            }
            if media.position>=0 {
              HStack { Text(Self.time(scrub ?? elapsed)); Spacer(); if media.duration>0 { Text(Self.time(Double(media.duration)/1000)) } }.font(.caption.monospacedDigit()).foregroundStyle(AniCePalette.secondaryText(scheme))
            }
          }
        }
        HStack(spacing: compact ? 12 : 16) {
          control("backward.end.fill","Previous",2,2)
          control(media.state == 1 ? "pause.fill":"play.fill",media.state == 1 ? "Pause":"Play",1,1)
          control("forward.end.fill","Next",3,4)
          Spacer()
        }
        if media.actions & 16 != 0 { Button("Allow playback control…") { model.requestPermission() } }
      } else if !compact {
        Text(model.selection.isEmpty ? "Play media on this Mac to see it here.":"Waiting for playback information from the selected player.").foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if !compact {
        PlayerVolumeView(model:model)
      }
      if !model.feedback.isEmpty && !compact {
        Text(model.feedback).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
        if media.source.isEmpty { Button("Retry observation") { model.retryObservation() } }
      }
    }.padding(compact ? 12 : 16).frame(maxWidth:.infinity,alignment:.leading)
      .background(AniCePalette.surface(scheme),in:RoundedRectangle(cornerRadius:12))
      .onChange(of:media.revision) { _,_ in if target != nil { cancelled=true }; target=nil; scrub=nil }
  }
  private func control(_ symbol: String,_ label: String,_ action: Int64,_ mask: Int64) -> some View {
    Button { model.command(source:media.source,revision:media.revision,action:action) } label: { Image(systemName:symbol).frame(minWidth:compact ? 28:32,minHeight:compact ? 24:28) }
      .disabled(model.busy || media.actions & mask == 0).accessibilityLabel(label)
  }
  static func time(_ seconds: Double) -> String { let value=Int(max(0,seconds)); return String(format:"%d:%02d",value/60,value%60) }
}
