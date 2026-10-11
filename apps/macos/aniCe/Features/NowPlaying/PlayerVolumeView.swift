// SPDX-License-Identifier: GPL-3.0-or-later
// Presents one final source-bound volume command after native slider editing completes.
import SwiftUI

struct PlayerVolumeView: View {
  let model: MacPlaybackModel
  @State private var preview: Double?
  @State private var target: MediaPlayback?
  @State private var cancelled = false
  var body: some View {
    if let level=model.displayedVolume {
      VStack(spacing:4) {
        HStack { Text("Player volume");Spacer();Text("\(Int(preview ?? Double(level)))%").monospacedDigit() }.font(.caption)
        Slider(value:Binding(get:{ preview ?? Double(level) },set:{ if !cancelled { preview=$0 } }),in:0...100) { editing in
          if editing { target=model.playback;cancelled=false }
          else {
            if !cancelled, let target, let preview { model.commandVolume(source:target.source,revision:target.revision,value:Int64(preview.rounded())) { _ in } }
            target=nil;preview=nil;cancelled=false
          }
        }.accessibilityLabel("Player volume").disabled(model.busy)
      }
      .onChange(of:model.playback.source) { _,_ in if target != nil { cancelled=true;preview=nil } }
      .onChange(of:model.playback.revision) { _,_ in if target != nil { cancelled=true;preview=nil } }
    }
  }
}
