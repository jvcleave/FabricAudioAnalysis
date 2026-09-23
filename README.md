# Fabric Audio Source Processor

A work-in-progress Fabric plug-in for audio-file and live-microphone analysis.
The planned node behavior, ports, and milestones are in [PLUG_IN_PLAN.md](PLUG_IN_PLAN.md).

## Current state

The first implementation slice is `AudioSourceProcessorCore`, a Swift 5.9,
macOS 15+ package with no Fabric dependency. It defines immutable analysis
values, a 2048-point FFT frame analyzer, and a streaming onset detector.
The analyzer emits raw RMS, loudness, five frequency-band energies, spectral
flux, and spectral centroid. The file processor, microphone capture adapter,
normalization, and `.fabricplugin` bundle are still planned work.

Run the focused core checks with:

```sh
swift test --package-path AudioSourceProcessorCore
```

The analyzer and onset threshold are adapted from
[AudioSourceProcessorExample](https://github.com/jvcleave/AudioSourceProcessorExample)
commit `4db4e252f88339e7f7833fa37a42230779b4a904`. This package stores
compact measurements instead of the sample app's per-frame PCM arrays. A
separate analyzer instance is required for each ordered source stream because
spectral flux depends on its preceding frame.
