# Fabric Audio Analysis

A Fabric plug-in for live microphone analysis. It registers **Live Audio Analysis**
with stable, typed ports for driving audio-reactive graphs. The behavior and
acceptance checks are in [PLUG_IN_PLAN.md](PLUG_IN_PLAN.md).

## Current state

`AudioAnalysisCore` is a Swift 5.9, macOS 15+ package with no Fabric
dependency. It defines immutable analysis values, a 2048-point FFT frame
analyzer, a streaming onset detector, and microphone capture. The analyzer
emits raw RMS, loudness, five frequency-band energies, spectral flux, spectral
centroid, peak levels, and envelopes.

The node captures the system default microphone and analyzes samples outside
Fabric's render call. Its fixed-size sample ring drops old samples if analysis
falls behind instead of building an unbounded queue. Each graph pass publishes
the newest completed snapshot and preserves any onset since the previous pass.
It also publishes 24 oldest-to-newest waveform rows of 192 signed samples each.
Rows use one byte per sample internally, and capture retains only the newest
24 rows.

`Enabled` defaults to true. Capture starts while the graph runs, after macOS
grants Fabric microphone access, and stops when the graph stops or the node is
disabled. `Running` and `Sample Rate` report capture status. Settings offer
analysis FPS (default 30, range 1 to 120). The node uses the system default
microphone without device selection.

The host application must declare `NSMicrophoneUsageDescription`; Fabric Editor
does so already.

The [box-scaling example](FabricScenes/README.md) uses Live Audio Analysis's
Medium Envelope plus 0.35 to scale a rendered box uniformly. The box stays
visible during silence and grows as the envelope rises.

## Node port reference

All normalized values are in `0...1`. RMS, frequency bands, and spectral flux
use a rolling 180-frame maximum. Loudness Normalized uses a fixed
`-60...0 dB` mapping.

| Port | Direction | Fabric type | Default or requirement | Description |
| --- | --- | --- | --- | --- |
| RMS | Output | Float | 0 before data | Raw root-mean-square amplitude |
| RMS Normalized | Output | Float | 0 before data | RMS divided by the source's normalization-window maximum |
| Loudness dB | Output | Float | -140 before data | `20 log10(RMS)` in decibels |
| Loudness Normalized | Output | Float | 0 before data | Fixed mapping of `-60...0 dB` to `0...1` |
| Onset | Output | Bool | false before data | Pulses once for captured onsets since the previous graph pass |
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
| Waveform History | Output | Array of Float | 24 × 192 zero samples before data | Signed, oldest-to-newest waveform rows for downstream nodes |

### Live Audio Analysis

| Port | Direction | Fabric type | Default or requirement | Description |
| --- | --- | --- | --- | --- |
| Enabled | Input | Bool | true | Allows capture while the graph runs |
| Running | Output | Bool | false | True after the microphone engine starts |
| Sample Rate | Output | Float | 0 before capture | Input sample rate in Hz |

Run the focused core checks with:

```sh
swift test --package-path AudioAnalysisCore
```

Build and install the development bundle from this repository root:

```sh
xcodebuild \
  -project FabricAudioAnalysis/FabricAudioAnalysis.xcodeproj \
  -scheme FabricAudioAnalysis \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

The target builds the adjacent `../Fabric` checkout in an isolated
`.fabric-spm` directory and installs an ad-hoc signed copy in
`~/Library/Application Support/Fabric/Plugins/`. To use a different checkout,
pass `FABRIC_SOURCE_ROOT=/absolute/path/to/Fabric` to `xcodebuild`. The renamed
Debug bundle, discovery, scene save/reopen, and box scaling were verified
against the adjacent Fabric checkout at
`940f3e06881f0bcd4812fc8fecbaa1a98c47bf7e`.

When replacing an earlier development bundle, move it out of Fabric's
`Plugins` directory before running the new plug-in. Both bundles register the
same Live Audio Analysis node name, so installing both causes a registration
conflict. This plug-in uses the identifier `com.jvclabs.FabricAudioAnalysis`.

After building, check registration, graph save/reopen, and uniform box scaling
through Fabric's own `NodeRegistry`:

```sh
sh PluginVerification/verify.sh
```

`PluginVerification/Package.resolved` matches the selected Fabric checkout's
package lock. Refresh it from that checkout when updating the host revision.
The verification script prepares a local Sparkle copy needed by Fabric's
command-line host executable; it does not change the Fabric checkout. It also
accepts `FABRIC_SPM_SCRATCH_PATH` to reuse an existing compatible Fabric build.
The box check disables microphone capture and supplies an envelope value, so
it can verify the saved scene without requesting microphone access.

Restart Fabric Editor after updating the installed bundle; its registry loads
external plug-ins at startup.

The analyzer and onset threshold are adapted from
[AudioSourceProcessorExample](https://github.com/jvcleave/AudioSourceProcessorExample)
commit `4db4e252f88339e7f7833fa37a42230779b4a904`. A separate analyzer instance
is required for each ordered microphone stream because spectral flux depends
on its preceding frame.
