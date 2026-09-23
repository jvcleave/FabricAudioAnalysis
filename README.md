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
measurements at graph time. The live node captures the system default
microphone, analyzes samples outside Fabric's render call, and publishes the
newest completed frame. Its fixed-size sample ring drops old samples if
analysis falls behind instead of building an unbounded queue.

For the file node, choose an audio file in its settings and set the analysis
FPS (default 30). `Ready` stays false while analysis runs. Once ready, a
connected `Time` input selects the frame in seconds; otherwise graph time is
multiplied by `Playback Rate`. `Loop` wraps time at the file duration. The node
analyzes audio without playing it. Saved graphs carry a security-scoped file
bookmark; reselect the file if the bookmark is stale or the graph moves to a
different machine.

For the live node, `Enabled` defaults to true. Capture starts while the graph
runs, after macOS grants Fabric microphone access, and stops when the graph
stops or the node is disabled. `Running` and `Sample Rate` report capture
status. Settings offer analysis FPS (default 30, range 1 to 120); the first
version uses the system default microphone without device selection.
The host application must declare `NSMicrophoneUsageDescription`; Fabric
Editor does so already.

Two example graphs are in [FabricScenes](FabricScenes/README.md). Each uses the
source node's Medium Envelope to scale a rendered box uniformly. Choose a file
after opening the file graph; the sample deliberately contains no
machine-specific bookmark.

## Node port reference

Both nodes expose these outlets. All normalized values are in `0...1`.
The file node uses whole-file maxima for RMS, bands, and flux; the live node
uses a rolling 180-frame maximum. Equal normalized values from different
sources do not imply equal absolute sound levels.

| Port | Direction | Fabric type | Default or requirement | Description |
| --- | --- | --- | --- | --- |
| RMS | Output | Float | 0 before data | Raw root-mean-square amplitude |
| RMS Normalized | Output | Float | 0 before data | RMS divided by the source's normalization-window maximum |
| Loudness dB | Output | Float | -140 before data | `20 log10(RMS)` in decibels |
| Loudness Normalized | Output | Float | 0 before data | Fixed mapping of `-60...0 dB` to `0...1` |
| Onset | Output | Bool | false before data | File-frame onset flag; live onset pulses once for captured frames since the previous graph pass |
| Sub Bass | Output | Float | 0 before data | Normalized energy at 20 to 60 Hz |
| Bass | Output | Float | 0 before data | Normalized energy at 60 to 250 Hz |
| Low Mid | Output | Float | 0 before data | Normalized energy at 250 to 500 Hz |
| Mid | Output | Float | 0 before data | Normalized energy at 500 to 2000 Hz |
| High | Output | Float | 0 before data | Normalized energy at 2000 Hz to Nyquist or 20000 Hz |
| Spectral Flux | Output | Float | 0 before data | Normalized positive spectral change |
| Spectral Centroid | Output | Float | 0 before data | Spectral center of mass in Hz |
| Peak RMS | Output | Float | 0 before data | Peak-held normalized RMS |
| Peak Flux | Output | Float | 0 before data | Peak-held normalized flux |
| Fast Envelope | Output | Float | 0 before data | Normalized RMS envelope with fast release |
| Medium Envelope | Output | Float | 0 before data | Normalized RMS envelope with medium release |
| Slow Envelope | Output | Float | 0 before data | Normalized RMS envelope with slow release |

### Audio File Analysis

| Port | Direction | Fabric type | Default or requirement | Description |
| --- | --- | --- | --- | --- |
| Time | Input | Float | Graph time when unconnected | Requested playback time in seconds |
| Loop | Input | Bool | true | Wraps time at the source duration |
| Playback Rate | Input | Float | 1 | Scales graph time only when Time is unconnected |
| Ready | Output | Bool | false | True after the selected file finishes analysis |
| Current Frame | Output | Int | 0 before data | Zero-based selected analysis frame |
| Frame Count | Output | Int | 0 before data | Number of analyzed frames |
| Frame Rate | Output | Float | 0 before data | Actual analysis frames per second |
| Duration | Output | Float | 0 before data | File duration in seconds |
| Average BPM | Output | Float | 0 without onsets | Estimate from the median onset interval |

### Live Audio Analysis

| Port | Direction | Fabric type | Default or requirement | Description |
| --- | --- | --- | --- | --- |
| Enabled | Input | Bool | true | Allows capture while the graph runs |
| Running | Output | Bool | false | True after the microphone engine starts |
| Sample Rate | Output | Float | 0 before capture | Input sample rate in Hz |

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
