# Fabric Audio Source Processor — plug-in plan

## Goal and starting point

Build a macOS Fabric plug-in with **Live Audio Analysis** for microphone-driven
visuals. The node publishes levels, onset detection, five named frequency
bands, spectral measurements, envelopes, and waveform history.

The DSP reference is
[AudioSourceProcessorExample](https://github.com/jvcleave/AudioSourceProcessorExample)
at `4db4e252f88339e7f7833fa37a42230779b4a904`. The plug-in uses AVFoundation and
Accelerate. No additional third-party framework is required.

## Responsibilities

`AudioSourceProcessorCore` owns DSP, immutable `Sendable` analysis snapshots,
bounded waveform history, and microphone capture. It has no Fabric or Satin
dependency. The `.fabricplugin` target owns node registration, typed ports,
Codable settings, lifecycle integration, and graph publishing.

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

RMS, bands, and flux normalize to a rolling 180-frame maximum. Normalized
outputs stay in `0...1`; normalized loudness maps `-60...0 dB` to `0...1`.

Keep capture and DSP outside Fabric's render call. Bound pending samples and
retained snapshots. Stop capture and remove its tap when the graph stops, the
node is disabled, or settings change. Ignore callbacks from old capture
generations. Denied permission and missing input devices report a recoverable
error. Preserve the newest measurements when no new snapshot is available.

## Verification and completion criteria

- Fabric discovers exactly one plug-in node: Live Audio Analysis.
- Typed node connections survive graph save and reopen.
- Core checks cover silence, known-frequency signals, onset behavior, finite
  normalized values, waveform history, and bounded capture handoff.
- The Debug bundle builds against the selected Fabric checkout and passes
  installed-bundle discovery checks.
- `LiveAudioAnalysis.fabric` and `AudioDepthBlocksLive.fabric` reopen with their
  connections intact. Run them in Fabric Editor to verify microphone access
  and reactive visuals.
- The README documents normalization, the default microphone limitation,
  installation, and the Fabric revision used for verification.
