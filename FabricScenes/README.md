# Sample Fabric graphs

- `AudioFileAnalysis.fabric` contains Audio File Analysis driving the uniform
  scale of a rendered box. Open node settings and choose an audio file after
  opening the graph. The graph intentionally stores no machine-specific file
  bookmark.
- `LiveAudioAnalysis.fabric` contains Live Audio Analysis driving the same box
  scale. Run the graph and allow Fabric microphone access when macOS asks.
- `Audio3DWaveformFile.fabric` connects Audio File Analysis to Audio 3D
  Waveform and displays the result on an Image Mesh. Select an audio file in
  the source node's settings after opening it.
- `Audio3DWaveformLive.fabric` uses Live Audio Analysis for the same image
  path. Allow Fabric microphone access when macOS asks.
- `AudioWaveformGeometryFile.fabric` connects Audio File Analysis to Audio
  Waveform Geometry, then to a Color Material and Mesh. Select an audio file
  in the source node's settings after opening it.
- `AudioWaveformGeometryLive.fabric` uses Live Audio Analysis for the same
  geometry path. Allow Fabric microphone access when macOS asks.

The box graphs add 0.35 to the source's Medium Envelope, then send that value to
the box's X, Y, and Z scale components. The box remains visible during silence
and grows as the envelope rises.

All six graphs demonstrate typed plugin registration and connection persistence.
They do not play sound. Regenerate the box graphs after changing node ports with
`sh PluginVerification/verify.sh --write-samples` from the repository root.
Regenerate the waveform scenes separately with
`sh PluginVerification/verify.sh --write-waveform-samples`; this leaves edits to
the existing box scenes untouched.
Regenerate the geometry scenes with
`sh PluginVerification/verify.sh --write-geometry-samples`.
