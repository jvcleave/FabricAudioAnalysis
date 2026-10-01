# Sample Fabric graphs

- `LiveAudioAnalysis.fabric` contains Live Audio Analysis driving the uniform
  scale of a rendered box. Run the graph and allow Fabric microphone access
  when macOS asks. The graph adds 0.35 to Medium Envelope to set its size;
  Onset controls the saved scene's box visibility.
- `AudioDepthBlocksLive.fabric` uses Live Audio Analysis to drive a 12 × 24
  field of instanced boxes. The graph downsamples Waveform History, takes each
  sample's magnitude, and uses it for that box's depth. Medium Envelope adds
  gain so quiet microphone samples produce visible motion; Onset flashes the
  blocks orange for 0.2 seconds. The blocks retain a small base depth during
  silence. Run the graph and allow microphone access. This approximates
  MESS's Depth Blocks effect using existing Fabric nodes.

Both graphs demonstrate typed plugin registration and connection persistence.
Check registration and open both saved graphs with
`sh PluginVerification/verify.sh` from the repository root.

Regenerate the live box graph with
`sh PluginVerification/verify.sh --write-samples`.
Regenerate the live Depth Blocks graph with
`sh PluginVerification/verify.sh --write-depth-blocks-sample`.
