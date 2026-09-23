# Sample Fabric graphs

- `AudioFileAnalysis.fabric` contains Audio File Analysis with RMS connected to
  a Number Binary Operator. Open node settings and choose an audio file after
  opening the graph. The graph intentionally stores no machine-specific file
  bookmark.
- `LiveAudioAnalysis.fabric` contains Live Audio Analysis with the same RMS
  connection. Run the graph and allow Fabric microphone access when macOS asks.

These graphs demonstrate typed plugin registration and connection persistence.
They do not play sound. Regenerate them after changing node ports with
`sh PluginVerification/verify.sh --write-samples` from the repository root.
