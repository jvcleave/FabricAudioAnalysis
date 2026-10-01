# Sample Fabric graphs

- `AudioFileAnalysis.fabric` contains Audio File Analysis driving the uniform
  scale of a rendered box. Open node settings and choose an audio file after
  opening the graph. The graph intentionally stores no machine-specific file
  path.
- `LiveAudioAnalysis.fabric` contains Live Audio Analysis driving the same box
  scale. Run the graph and allow Fabric microphone access when macOS asks.
- `AudioWaveformPlayback.fabric` plays an audio file and connects the player's
  Current Time to Audio File Analysis. The analysis node's Medium Envelope
  scales a box. The player's File URL also feeds Audio File Analysis, so select
  the file once in Playback Settings after opening the graph.
- `AudioDepthBlocksLive.fabric` uses Live Audio Analysis to drive a 12 × 24
  field of instanced boxes. The graph downsamples Waveform History, takes each
  sample's magnitude, and uses it for that box's depth. Medium Envelope adds
  gain so quiet microphone samples produce visible motion; Onset flashes the
  blocks orange for 0.2 seconds. The blocks retain a small base depth during
  silence. Run the graph and allow microphone access.
  This uses only existing Fabric nodes; it approximates MESS's Depth Blocks
  effect without its image-sampled per-block colors.

The box graphs add 0.35 to the source's Medium Envelope, then send that value to
the box's X, Y, and Z scale components. The box remains visible during silence
and grows as the envelope rises.

All three graphs demonstrate typed plugin registration and connection persistence.
Only AudioWaveformPlayback plays sound. Regenerate the box graphs after changing node ports with
`sh PluginVerification/verify.sh --write-samples` from the repository root.
Regenerate the playback scene with
`sh PluginVerification/verify.sh --write-playback-sample`.
Regenerate the live Depth Blocks scene with
`sh PluginVerification/verify.sh --write-depth-blocks-sample`.
