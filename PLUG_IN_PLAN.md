# Fabric Audio Source Processor — plug-in plan

## Goal and starting point

Build one macOS Fabric plug-in with **Audio File Analysis** and **Live Audio Analysis** nodes. Both expose the same useful per-frame measurements for driving Fabric graphs. The file node follows graph time; the live node follows microphone capture. Neither node needs to play audio.

The reference implementation is [AudioSourceProcessorExample](https://github.com/jvcleave/AudioSourceProcessorExample) at `4db4e252f88339e7f7833fa37a42230779b4a904`. It provides `DefaultAudioSourceProcessor`, `LiveAudioAnalyzer`, `AdvancedAudioFrameAnalyzer`, and the feature models. The current local Fabric host is `develop-beta-plugin-2` at `69b8a580a1ef79f5c8a9b150b5d3483193c541ac`. Recheck the Fabric API revision before building; the plug-in should not depend on this branch unless a specific missing API is identified.

Fabric already has an **Audio Spectrum** microphone node that emits a normalized spectrum. This plug-in adds file analysis and the reference implementation's RMS, loudness, onset, five named frequency bands, spectral flux, centroid, and envelopes. It uses AVFoundation and Accelerate; no new third-party framework is planned.

## Repository layout

```text
FabricAudioSourceProcessor/
├── PLUG_IN_PLAN.md
├── README.md
├── AudioSourceProcessorCore/
│   ├── Package.swift
│   ├── Sources/AudioSourceProcessorCore/
│   └── Tests/AudioSourceProcessorCoreTests/
├── FabricAudioSourceProcessor/
│   ├── FabricAudioSourceProcessor.xcodeproj
│   └── FabricAudioSourceProcessor/
│       ├── Info.plist
│       ├── Plugin/
│       ├── Nodes/
│       └── Settings/
└── FabricScenes/
```

`AudioSourceProcessorCore` owns decoding, DSP, analysis results, and microphone capture without a Fabric or Satin dependency. The `.fabricplugin` target owns node registration, typed ports, settings, graph timing, and publishing. The sample app's SwiftUI views and playback runner are not part of the plug-in. Retain attribution to the reference code when adapting it.

The Xcode target builds against the adjacent `../Fabric` checkout by default and accepts `FABRIC_SOURCE_ROOT` for another checkout. It builds the matching Debug or Release Fabric module, links against the host's Fabric implementation, installs the local development bundle under `~/Library/Application Support/Fabric/Plugins/`, and signs that copy for local use. Follow the [Fabric plugin runbook](../FABRIC_PLUGINS/PLUGIN_BUILD_RUNBOOK.md) and [Fabric plug-in API guide](../Fabric/PLUGINS.md).

## Shared analysis contract

Use a compact, immutable `Sendable` analysis snapshot at the core-to-node boundary. The same projection code maps file frames and live snapshots to Fabric outputs. Do not transfer `AudioSource` or `AudioFrame` reference objects, raw audio samples, or `AVAudioPCMBuffer` through graph ports.

The first version should expose these shared outputs on both nodes, with stable registration keys and explicit descriptions:

| Output group | Fabric outputs | Units and meaning |
| --- | --- | --- |
| Level | `RMS`, `RMS Normalized`, `Loudness dB`, `Loudness Normalized` | Raw RMS; normalized RMS in `0...1`; loudness in dB; fixed `-60...0 dB` mapping to `0...1` |
| Onset | `Onset` | `Bool`; file mode reports whether the selected frame contains an onset, while live mode pulses once when new captured frames contain an onset |
| Bands | `Sub Bass`, `Bass`, `Low Mid`, `Mid`, `High` | Five normalized `0...1` band energies using the reference frequency ranges |
| Spectral | `Spectral Flux`, `Spectral Centroid` | Normalized flux `0...1`; centroid in Hz |
| Response | `Peak RMS`, `Peak Flux`, `Fast Envelope`, `Medium Envelope`, `Slow Envelope` | Normalized `0...1` values from the reference analyzer |

The two sources have different normalization windows: file RMS, bands, and flux use whole-file maxima; live values use the reference's rolling 180-frame window. Keep those semantics visible in port descriptions and the README. Do not imply that equally normalized values from the two nodes represent equal absolute sound levels.

### Audio File Analysis

- **Settings:** selected audio file and analysis FPS (default `30`), in a Codable settings type with a procedural initializer. Fabric Editor is not sandboxed, so new selections store a local file URL. Older saved bookmarks remain readable. A sample graph may still require the user to reselect its file on another machine.
- **Inputs:** `Time` (`Float`, seconds; connected value is authoritative), `Loop` (`Bool`, default `true`), and `Playback Rate` (`Float`, default `1`; applies only to unconnected graph time).
- **Additional outputs:** `Ready`, `Current Frame`, `Frame Count`, `Frame Rate`, `Duration`, and `Average BPM`. Publish an explicit not-ready state until the selected file has been analyzed; never publish measurements from an obsolete source or FPS setting.
- Decode and analyze outside the render call. Once ready, select the exact precomputed frame for each requested time, including backward scrubbing, looping, and non-looping end holds. Changes to source or FPS invalidate the old result using a generation identifier. Define export behavior explicitly: an export started before analysis is ready must fail or report not-ready rather than silently using stale data.
- Adapt the reference processor's whole-file PCM allocation and retained per-frame sample arrays into bounded-memory processing and compact stored measurements. Audio output/playback and video-audio extraction are outside the first version.

### Live Audio Analysis

- **Settings:** analysis FPS (default `30`). First version uses the system default microphone, matching the reference analyzer. Device selection can be a later feature if needed; Fabric's existing Audio Spectrum node has a different capture path with per-device selection.
- **Input:** `Enabled` (`Bool`, default `true`). Capture operates only while the graph executes and the node is enabled.
- **Additional outputs:** `Running` and `Sample Rate`. Publish the newest completed snapshot at most once per graph pass. The handoff must preserve an onset flag when several capture frames are coalesced, pulse it once, and clear it on the next graph pass. Retain other measurements when no new snapshot exists.
- Start permission and capture without blocking Fabric's render thread. Stop and remove the audio tap on graph stop, disable, or settings change. Ignore callbacks from an old capture generation. A denied permission or missing input device must produce a clear recoverable status.
- Keep DSP off the render thread. Review the reference tap's per-buffer allocation and queue handoff before using it in a long-running Fabric graph; bound pending work so an overloaded graph cannot accumulate unbounded audio snapshots.

## Milestones and acceptance checks

1. **Core contract.** Add the Swift package, define immutable analysis values, and port the shared DSP with a documented source revision. Verify silence, a known-frequency signal, onset behavior, and finite normalized values with small independent fixtures. Confirm the package builds for macOS 15 with Swift 5.9.
2. **Plug-in shell.** Add the Xcode bundle target, API version `1` metadata, principal class, and both node registrations. Build against the selected Fabric checkout without embedding Fabric. Install the signed development bundle and confirm Fabric discovers both names.
3. **File node.** Add settings, secure file access, asynchronous bounded analysis, exact graph-time frame selection, status outputs, and serialization. Verify first, middle, last, looped, reversed, and scrubbed frames; verify stale work cannot replace a newer selection. Save and reopen a graph with connections intact.
4. **Live node.** Add microphone permission, capture lifecycle, thread-safe latest-snapshot handoff, and shared ports. Verify permission-denied and missing-input behavior, enabling/disabling, graph stop/restart, and that no tap survives shutdown. Compare a known test tone's band and centroid values with the core analyzer.
5. **Integration and documentation.** Add a small file-driven graph and a microphone graph, README port tables and setup instructions, Debug and Release bundle builds, installed-bundle metadata/signature/resource checks, and a manual Fabric run. Document normalization, file relinking, and the default-microphone limitation.

## Completion criteria

- Both nodes appear in Fabric and publish values of the documented types and units.
- File output follows the requested graph time after analysis completes; live output reflects new microphone snapshots without blocking rendering.
- Source changes, microphone restarts, and graph shutdown do not publish stale results or leak capture resources.
- Core tests, plug-in builds, discovery, graph save/reopen, and the included example graphs pass on the targeted Fabric checkout.
- The README states the exact Fabric revision or release used for the verified build and how to install and use the plug-in.

## Audio file playback extension

**Audio File Playback** is an audio-output Consumer with an `AVPlayer` owned
for the graph execution lifetime. It stores a local file URL in Settings, or
accepts a procedural File URL input. Play, loop, volume, and seek inputs control
it; Volume reports the effective player gain, while Current Time and File URL
drive Audio File Analysis's corresponding inlets.
Both nodes can still select files independently when used on their own. The
sample graph shares the player file selection and uses the analysis envelope
to scale a box.
