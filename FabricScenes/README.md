# Sample Fabric graphs

- `AudioFileAnalysis.fabric` contains Audio File Analysis driving the uniform
  scale of a rendered box. Open node settings and choose an audio file after
  opening the graph. The graph intentionally stores no machine-specific file
  bookmark.
- `LiveAudioAnalysis.fabric` contains Live Audio Analysis driving the same box
  scale. Run the graph and allow Fabric microphone access when macOS asks.

Each graph adds 0.35 to the source's Medium Envelope, then sends that value to
the box's X, Y, and Z scale components. The box remains visible during silence
and grows as the envelope rises.

These graphs demonstrate typed plugin registration and connection persistence.
They do not play sound. Regenerate them after changing node ports with
`sh PluginVerification/verify.sh --write-samples` from the repository root.
