# Fabric Audio Source Processor

A work-in-progress Fabric plug-in for audio-file and live-microphone analysis.
The planned node behavior, ports, and milestones are in [PLUG_IN_PLAN.md](PLUG_IN_PLAN.md).

## Current state

`AudioSourceProcessorCore` is a Swift 5.9, macOS 15+ package with no Fabric
dependency. It defines immutable analysis values, a 2048-point FFT frame
analyzer, and a streaming onset detector. The analyzer emits raw RMS,
loudness, five frequency-band energies, spectral flux, and spectral centroid.

The `.fabricplugin` development bundle registers **Audio File Analysis** and
**Live Audio Analysis** with stable, typed ports. The file node decodes a
selected audio file in bounded chunks and publishes compact, source-normalized
measurements at graph time. The live node remains a registration shell:
`Running` reports `false` until microphone capture is implemented.

For the file node, choose an audio file in its settings and set the analysis
FPS (default 30). `Ready` stays false while analysis runs. Once ready, a
connected `Time` input selects the frame in seconds; otherwise graph time is
multiplied by `Playback Rate`. `Loop` wraps time at the file duration. The node
analyzes audio without playing it. Saved graphs carry a security-scoped file
bookmark; reselect the file if the bookmark is stale or the graph moves to a
different machine.

Run the focused core checks with:

```sh
swift test --package-path AudioSourceProcessorCore
```

Build and install the development bundle from this repository root:

```sh
xcodebuild \
  -project FabricAudioSourceProcessor/FabricAudioSourceProcessor.xcodeproj \
  -scheme FabricAudioSourceProcessor \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

The target builds the adjacent `../Fabric` checkout in an isolated
`.fabric-spm` directory and installs an ad-hoc signed copy in
`~/Library/Application Support/Fabric/Plugins/`. To use a different checkout,
pass `FABRIC_SOURCE_ROOT=/absolute/path/to/Fabric` to `xcodebuild`. The first
verified bundle build used Fabric `69b8a580a1ef79f5c8a9b150b5d3483193c541ac`.

After building, check registration and graph save/reopen through Fabric's own
`NodeRegistry`:

```sh
sh PluginVerification/verify.sh
```

`PluginVerification/Package.resolved` matches the selected Fabric checkout's
package lock. Refresh it from that checkout when updating the host revision.
The verification script prepares a local Sparkle copy needed by Fabric's
command-line host executable; it does not change the Fabric checkout.

Restart Fabric Editor after updating the installed bundle; its registry loads
external plug-ins at startup.

The analyzer and onset threshold are adapted from
[AudioSourceProcessorExample](https://github.com/jvcleave/AudioSourceProcessorExample)
commit `4db4e252f88339e7f7833fa37a42230779b4a904`. This package stores
compact measurements instead of the sample app's per-frame PCM arrays. A
separate analyzer instance is required for each ordered source stream because
spectral flux depends on its preceding frame.
