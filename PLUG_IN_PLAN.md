# Fabric Audio Analysis — plug-in plan

## Goal and starting point

Build a macOS Fabric plug-in with **Live Audio Analysis** for microphone-driven
visuals. The node publishes levels, onset detection, five named frequency
bands, spectral measurements, envelopes, and waveform history.

The DSP reference is
[AudioSourceProcessorExample](https://github.com/jvcleave/AudioSourceProcessorExample)
at `4db4e252f88339e7f7833fa37a42230779b4a904`. The plug-in uses AVFoundation and
Accelerate. No additional third-party framework is required.

## Responsibilities

`AudioAnalysisCore` owns DSP, immutable `Sendable` analysis snapshots,
bounded waveform history, and microphone capture. It has no Fabric or Satin
dependency. The `.fabricplugin` target owns node registration, typed ports,
Codable settings, lifecycle integration, and graph publishing.

Waveform Trail owns the Metal drawing of supplied waveform history and a
bounded, scene-time onset trail. It does not create a capture engine or an FFT
analyzer. The advanced example combines it with existing Fabric nodes and keeps
one Live Audio Analysis source for the entire scene.

The Xcode target builds against the adjacent `../Fabric` checkout by default
and accepts `FABRIC_SOURCE_ROOT` for another checkout. It builds the matching
Debug or Release Fabric module, links against the host implementation without
embedding Fabric, and installs a signed development bundle under
`~/Library/Application Support/Fabric/Plugins/`. See the
[Fabric plugin runbook](../FABRIC_PLUGINS/PLUGIN_BUILD_RUNBOOK.md) and
[Fabric plug-in API guide](../Fabric/PLUGINS.md).

## Live analysis contract

- **Settings:** analysis FPS (default `30`, range `1...120`), exposed through a
  Codable settings type and procedural initializer. Capture uses the system
  default microphone.
- **Input:** `Enabled` (`Bool`, default `true`). Capture operates while the
  graph runs and the node is enabled.
- **Levels:** `RMS`, `RMS Normalized`, `Loudness dB`, `Loudness Normalized`.
- **Onset:** `Onset` pulses once when newly captured frames contain an onset.
  Coalescing frames preserves any onset and clears the pulse on the next pass.
- **Bands:** `Sub Bass`, `Bass`, `Low Mid`, `Mid`, `High`.
- **Spectral:** `Spectral Flux`, `Spectral Centroid` (Hz).
- **Response:** `Peak RMS`, `Peak Flux`, `Fast Envelope`, `Medium Envelope`,
  `Slow Envelope`.
- **Waveform:** `Waveform History` contains 24 oldest-to-newest rows with 192
  signed samples each, flattened into a float array and padded with zeroes.
- **Capture status:** `Running` and `Sample Rate` (Hz).
- **Diagnostics:** `Dropped Samples` counts mono samples lost to ring overflow
  or lock contention. It resets with the capture generation.

RMS, bands, and flux normalize to a rolling 180-frame maximum. Normalized
outputs stay in `0...1`; normalized loudness maps `-60...0 dB` to `0...1`.

Keep capture and DSP outside Fabric's render call. Bound pending samples and
retained snapshots. Stop capture and remove its tap when the graph stops, the
node is disabled, or settings change. Ignore callbacks from old capture
generations. Denied permission and missing input devices report a recoverable
error. Preserve the newest measurements when no new snapshot is available.
Expand waveform history only for a connected or published output, and reuse
it until a new analysis frame or capture generation arrives. Report input
drops without waiting for a lock in the audio callback.

## Verification and completion criteria

- Fabric discovers two plug-in nodes: Live Audio Analysis and Waveform Trail.
- Typed node connections survive graph save and reopen.
- Core checks cover silence, known-frequency signals, onset behavior, finite
  normalized values, waveform history, and bounded capture handoff.
- Overflow and contention checks verify cumulative dropped-sample counts.
- Waveform checks verify unused outputs skip expansion and connected or
  published outputs receive zero-padded history before capture begins.
- The Debug bundle builds against the selected Fabric checkout and passes
  installed-bundle discovery checks.
- `LiveAudioAnalysis.fabric` reopens with its connections intact and remains
  visible at a uniform scale of 0.35 during silence. A supplied envelope of
  0.65 changes all scale components to 1.0. Onset turns the material red for
  at least 0.2 seconds before it returns to white. Run it in Fabric Editor to
  verify microphone access, live box scaling, and onset flashes.
- The README documents normalization, the default microphone limitation,
  installation, and the Fabric revision used for verification.
- `LiveAudioAnalysisAdvanced.fabric` uses all 21 source outputs across six named
  subgraphs, and nested node identities and connections survive save/reopen.
  Synthetic input verifies meters, peak positions, raw and capture readouts,
  onset flashes, and Metal waveform rendering without microphone access.
- Onset trail checks cover bounded storage, scene-time scrolling and expiry,
  repeated evaluations at the same timestamp, and reset after a rewind.
- Invalid onset and audio-buffer capacities throw errors instead of terminating
  the process. FFT buffer failures propagate through capture as recoverable
  Fabric execution errors. Nonpositive audio-buffer read sizes leave pending
  samples intact and return an empty result.
