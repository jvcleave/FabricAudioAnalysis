# Internal Documentation

Start with the [README](../../README.md) for node ports, build setup, and
examples. Follow [AGENTS.md](../../AGENTS.md) for contributor guidance.

## Implementation

The [plug-in plan](todos/PLUG_IN_PLAN.md) describes the core package and
Fabric integration, the live analysis contract, and acceptance checks.

The [Audio Analysis update plan](todos/AUDIO_PLUGIN_UPDATE_PLAN.md) covers
Waveform Trail uploads in Iterators and Live Audio Analysis settings.

## Verification

The [build and verification instructions](../../README.md#build-and-install)
cover the core tests and synthetic-input bundle verifier. The
[example scene guide](../../FabricScenes/README.md) describes how to check
the same outputs in Fabric.

## Handoffs

Keep substantial Audio Analysis checkpoints in
`docs/internal/handoffs/<task-slug>.md`. Record the affected revisions, the
latest verification result, and the next exact action.
