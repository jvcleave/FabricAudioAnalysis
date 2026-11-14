# Handoff for the Audio Analysis update

- Updated 2026-11-14, 01:37 EST
- Owning repository `FabricAudioAnalysis`
- Starting revision `6a63f3f` on `codex/audio-plugin-update`
- Build against Fabric `c1da6639` and Satin `ff825e49`

## Objective

Implement the [Audio Analysis update plan](../todos/AUDIO_PLUGIN_UPDATE_PLAN.md)
and verify the Debug plug-in with the workspace and synthetic scenes.

## Current milestone

Verify that Live Audio Analysis resumes publishing after an FPS change
during live capture in the rebuilt Fabric Editor.

## Repository state

Waveform Trail uses Satin buffers for its cached samples and per-dispatch
onset columns. Live Audio Analysis routes FPS changes through `NodeSettings`
and saves them under the existing `liveSettings` key. The build setup and Xcode
signing edits in the surrounding workspace predate this update.

## Decisions and constraints

Keep Metal uploads in the plug-in and use the pinned Satin allocator. Keep the
existing waveform input, output, and scene contracts.

## Relevant files

- `FabricAudioAnalysis/FabricAudioAnalysis/Nodes/WaveformTrailNode.swift`
- `FabricAudioAnalysis/FabricAudioAnalysis/Nodes/LiveAudioAnalysisNode.swift`
- `FabricAudioAnalysis/FabricAudioAnalysis/Settings/`
- `PluginVerification/Sources/VerifyPluginDiscovery/`
- `docs/internal/todos/AUDIO_PLUGIN_UPDATE_PLAN.md`

## Verification

The original staged bundle failed the new Iterator verifier with three
distinct images across five passes (`.build/logs/audio-iterator-before.log`
in the shared workspace).

After replacing the fixed slots, `./Scripts/build-workspace.sh` passed. The
staged-bundle verifier confirmed all five image versions and waveform pixels
and passed the existing scene checks (`.build/logs/audio-iterator-after.log`).

The full workspace build and staged-bundle verifier passed again after the FPS
change. Iterator output passed with both retained and unretained Metal command
buffers. A 57 FPS scene reopened at 57 FPS, and removing `liveSettings` yielded
the 30 FPS default. The core suite passed all 11 tests. Logs are in the shared
workspace's `.build/logs/` as `audio-update-build.log`, `verify-audio-update.log`,
and `audio-update-core.log`.

The rebuilt Editor's FPS stepper changed from 30 to 31 on a test graph with
capture disabled. A separate check confirmed that an existing panel model
refreshed to 64 FPS after `Node.setSettings`.

## Remaining issues

The live restart check needs an active input in Fabric Editor. This Mac has a
built-in microphone set as the default input. BlackHole is optional for routing
system audio into Fabric.

## Next exact action

Run `FabricScenes/LiveAudioAnalysisAdvanced.fabric` in the staged Editor.
Once the capture readout shows `RUNNING true`, change Analysis FPS and confirm
the readout returns to `RUNNING true` and the waveform resumes updating.
