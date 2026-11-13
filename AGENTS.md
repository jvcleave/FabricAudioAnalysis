# Fabric Audio Analysis Agent Guidance

Read the [README](README.md) for setup and the
[plug-in plan](docs/internal/todos/PLUG_IN_PLAN.md) for the capture, analysis,
and graph contracts. Use the [internal documentation index](docs/internal/INTERNAL_DOCUMENTATION.md)
to find maintainer records.

- Keep capture and DSP in `AudioAnalysisCore`. Keep Fabric registration,
  typed ports, lifecycle, settings, and Metal drawing in the plug-in target.
- Use the core tests for analysis changes. Use the synthetic-input verifier
  when changing bundle registration or graph behavior. See
  [Build and install](README.md#build-and-install) for the commands.
- Verify links and the scoped diff for documentation changes. Keep
  substantial task checkpoints in `docs/internal/handoffs/`.
