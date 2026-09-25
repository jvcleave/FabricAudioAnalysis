# Fabric Audio Source Processor

A work-in-progress Fabric plug-in for audio-file and live-microphone analysis.
The planned node behavior, ports, and milestones are in [PLUG_IN_PLAN.md](PLUG_IN_PLAN.md).

## Current state

`AudioSourceProcessorCore` is a Swift 5.9, macOS 15+ package with no Fabric
dependency. It defines immutable analysis values, a 2048-point FFT frame
analyzer, and a streaming onset detector. The analyzer emits raw RMS,
loudness, five frequency-band energies, spectral flux, and spectral centroid.

The `.fabricplugin` development bundle registers **Audio File Analysis**,
**Audio File Playback**, **Live Audio Analysis**, **Audio 3D Waveform**, and **Audio Waveform Geometry**
with stable, typed ports. The file node decodes a selected audio file in
bounded chunks and publishes compact, source-normalized measurements at graph
time. The live node captures the system default microphone, analyzes samples
outside Fabric's render call, and publishes the newest completed frame. Its
fixed-size sample ring drops old samples if
analysis falls behind instead of building an unbounded queue.
Both sources also publish 24 signed waveform rows with 192 samples each. File
rows are quantized to one byte per sample during analysis, and live capture
keeps only its 24 newest rows. This gives the visualizer a bounded input
without retaining full PCM windows.

For the file node, choose an audio file in its settings and set the analysis
FPS (default 30). `Ready` stays false while analysis runs. Once ready, a
connected `Time` input selects the frame in seconds; otherwise graph time is
multiplied by `Playback Rate`. `Loop` wraps time at the file duration. The node
analyzes audio without playing it. Saved graphs carry a local file URL. Reselect
the file if its path changes or the graph moves to a different machine. Older
graphs containing security-scoped bookmarks remain readable.

For the live node, `Enabled` defaults to true. Capture starts while the graph
runs, after macOS grants Fabric microphone access, and stops when the graph
stops or the node is disabled. `Running` and `Sample Rate` report capture
status. Settings offer analysis FPS (default 30, range 1 to 120); the first
version uses the system default microphone without device selection.
The host application must declare `NSMicrophoneUsageDescription`; Fabric
Editor does so already.

Audio File Playback uses `AVPlayer` to play a selected local audio file. It
starts when the graph runs if Playing is enabled, pauses when Playing is off,
and stops when graph execution ends. Select the file in node Settings to save
its local URL. The File URL inlet also accepts an absolute path or file URL
for procedural graphs and overrides the Settings selection. Connect Current
Time and File URL to Audio File Analysis's matching inputs to share the
audible clock and file selection. Playback continues
when the analysis node is still preparing its file measurements.

Seven example graphs are in [FabricScenes](FabricScenes/README.md). The box
examples use the source node's Medium Envelope to scale a rendered box uniformly. Choose a file
after opening the file graph; the sample deliberately contains no
machine-specific file path.
The waveform examples connect a source's Waveform History to Audio 3D Waveform,
then show its Image on an Image Mesh. The visualizer uses a bundled Metal
shader adapted from MESS's `Audio3DWaveformVisualizerFilter` and encodes into
Fabric's command buffer. It draws perspective waveform layers, with controls
for image size, row count, amplitude, thickness, spacing, rotation, scale,
fade, color, and background alpha. MESS's text, scan, and bloom overlays are
outside this first version.
The waveform image redraws when its history or controls change. The default
source analysis rate is 30 FPS; increase it in the source settings for more
frequent waveform updates, or lower the image Width and Height to reduce GPU
work.
The playback example connects the player's Current Time and File URL to Audio
File Analysis and uses Medium Envelope to scale a box. Select the file once in
Playback Settings; Analysis uses that selection.
The geometry examples connect Waveform History to Audio Waveform Geometry,
then connect Geometry and a Color Material to a Mesh. This produces actual
three-dimensional ribbon vertices, so Mesh transforms and the scene camera
control the view. It avoids the offscreen waveform image and Image Mesh pass.
The geometry uses a stable Satin object, rebuilding its dynamic vertex data
only when waveform history or shape controls change. Its UV coordinates carry
sample position and row age for custom materials.

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
| Waveform History | Output | Array of Float | 24 × 192 zero samples before data | Signed, oldest-to-newest waveform rows for either waveform node |

### Audio File Analysis

| Port | Direction | Fabric type | Default or requirement | Description |
| --- | --- | --- | --- | --- |
| Time | Input | Float | Graph time when unconnected | Requested playback time in seconds |
| Loop | Input | Bool | true | Wraps time at the source duration |
| Playback Rate | Input | Float | 1 | Scales graph time only when Time is unconnected |
| File URL | Input | String | Empty | Optional absolute path or file URL, overriding Settings |
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

### Audio File Playback

| Port | Direction | Fabric type | Default | Description |
| --- | --- | --- | --- | --- |
| File URL | Input | String | Empty | Optional absolute path or file URL, overriding Settings |
| Playing / Loop | Input | Bool | true / true | Start or pause playback; restart at the end |
| Volume | Input | Float | 1 | Audio output level, 0 to 1 |
| Seek Time | Input | Float | -1 | Set a nonnegative time in seconds to seek |
| Current Time / Duration | Output | Float | 0 / 0 | Player time and file length in seconds |
| Is Playing / Ready | Output | Bool | false / false | Player state |
| Finished | Output | Bool | false | One graph-pass pulse at the file end |
| File URL | Output | String | Empty before selection | Selected local file URL for downstream analysis |

### Audio 3D Waveform

| Port | Direction | Fabric type | Default or requirement | Description |
| --- | --- | --- | --- | --- |
| Waveform History | Input | Array of Float | 24 × 192 signed samples | Connect either audio source's Waveform History |
| Width / Height | Input | Int | 1280 / 720 | Output image size in pixels |
| History | Input | Int | 24 | Number of newest rows to draw |
| Amplitude / Line Thickness / Spacing | Input | Float | 0.6 / 1.5 / 1.1 | Waveform displacement, pixel radius, and depth spacing |
| Angle X / Angle Y / Scale / Fade | Input | Float | 0.43 / -0.23 / 1.98 / 0 | Perspective and depth styling |
| Color / Transparent Background | Input | Vector 4 / Bool | Green / false | Line color and background alpha |
| Image | Output | Fabric Image | Redrawn when input changes | Perspective waveform texture |

### Audio Waveform Geometry

| Port | Direction | Fabric type | Default or requirement | Description |
| --- | --- | --- | --- | --- |
| Waveform History | Input | Array of Float | 24 × 192 signed samples | Connect either audio source's Waveform History |
| History | Input | Int | 24 | Number of newest rows to build |
| Width / Depth | Input | Float | 2 / 1.2 | Mesh dimensions in world units |
| Amplitude / Thickness | Input | Float | 0.6 / 0.01 | Vertical displacement and ribbon width in world units |
| Primitive | Input | String | Triangle | Standard geometry primitive; keep Triangle for filled ribbons |
| Geometry | Output | Satin Geometry | Dynamic ribbon mesh | Connect to a Mesh node's Geometry inlet |

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

Regenerate and GPU-check the waveform examples with:

```sh
sh PluginVerification/verify.sh --write-waveform-samples
```

Generate and verify the geometry examples with:

```sh
sh PluginVerification/verify.sh --write-geometry-samples
```

Generate the playback example and check play, pause, seek, and the clock
connection using a temporary muted test tone:

```sh
sh PluginVerification/verify.sh --write-playback-sample --verify-playback
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
