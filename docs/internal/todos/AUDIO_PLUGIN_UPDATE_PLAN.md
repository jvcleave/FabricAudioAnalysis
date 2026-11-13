# Fabric Audio Analysis Update Plan

Fix Waveform Trail inside Fabric’s Iterator first. In a five-pass GPU check,
the three upload slots produced three distinct images and the last two passes
reused the third image. A prototype using Satin’s allocator produced five
distinct images with the expected waveform pixels and passed the existing
synthetic scene verifier. Target the workspace’s Fabric `c1da6639` and Satin
`ff825e49` pins. [Fabric’s Satin pin](https://github.com/Fabric-Project/Fabric/commit/c1da66398ae4b28c266e0b3d4ef456d60c97f171)

## Waveform Trail uploads

1. Replace the three upload slots and their busy flags with buffers from
   `context.gpuAllocator.makeBuffer(..., memoryClass: .cpuWrites)`. Cache an
   immutable waveform buffer between input changes and allocate a buffer for
   each dispatch’s onset columns sized to the current image width. Use the
   existing Metal kernel and publish a `renderer.newImage(...)` result after
   encoding the dispatch. Keep the waveform input’s current row selection,
   zero padding, and sample clamping. [Waveform Trail node](../../../FabricAudioAnalysis/FabricAudioAnalysis/Nodes/WaveformTrailNode.swift) · [Satin GPU allocator](https://github.com/Fabric-Project/Satin/pull/68)
2. Invalidate the cached waveform before attempting its replacement. Fabric
   clears `valueDidChange` after a recoverable execution error, so a failed
   upload must leave the cache empty for the next evaluation. Report upload
   allocation errors as recoverable Fabric errors. For an unretained Metal
   command buffer, explicitly retain the uploads until the segment that reads
   them completes. [Fabric graph execution](https://github.com/Fabric-Project/Fabric/blob/c1da66398ae4b28c266e0b3d4ef456d60c97f171/Fabric/Graph/GraphRenderer.swift#L472-L509)
3. Add a regression check to `VerifyPluginDiscovery`. Send five different
   waveforms through one Iterator on a single command buffer, then use Metal
   readback to check five distinct image versions and the expected line
   position in each. Confirm the check detects the original three-slot
   behavior and run the existing sample scene checks with the rebuilt bundle.
   [Plug-in verification](../../../README.md#build-and-install)

## Live Audio Analysis settings

1. Adopt Fabric’s `NodeSettings` and route edits through `setSettings(_:)`.
   Keep the typed initializer and have `setLiveSettings(_:)` forward to the
   shared setter. Apply FPS changes through the existing capture store. Use
   `performOnMainSync` to create the settings view and `performOnMainAsync`
   to refresh an open panel after a programmatic change. [Live Audio Analysis node](../../../FabricAudioAnalysis/FabricAudioAnalysis/Nodes/LiveAudioAnalysisNode.swift) · [Fabric settings API](https://github.com/Fabric-Project/Fabric/commit/c2423394) · [Fabric main-thread helpers](https://github.com/Fabric-Project/Fabric/commit/e2202325)
2. Verify a non-default FPS round-trips under the existing `liveSettings`
   key, a scene with the key absent defaults to 30 FPS, and the open panel
   follows programmatic changes. In Fabric Editor, change FPS during live
   capture and check that the node resumes publishing.

## Workspace verification

Build the Debug workspace with `./Scripts/build-workspace.sh` and run
`PluginVerification/verify.sh` against the staged Audio Analysis bundle using
the workspace’s isolated runtime home. Update the plug-in README’s upload
description and verified Fabric revision before recording the tested plug-in
revision in the workspace. The Fabric checkout currently named in the plug-in
README predates these APIs. [Plug-in build and verification](../../../README.md#build-and-install)
