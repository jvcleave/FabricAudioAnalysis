# Live audio box scaling

`LiveAudioAnalysis.fabric` contains six nodes. Live Audio Analysis's Medium
Envelope is increased by 0.35 and sent to the box's X, Y, and Z scale. The box
stays visible during silence and grows as the envelope rises.

Run the graph and allow Fabric microphone access when macOS asks. The example
requires the `com.jvclabs.FabricAudioAnalysis` plug-in.

Check registration and reopen the saved graph with
`sh PluginVerification/verify.sh` from the repository root.

Regenerate the example with
`sh PluginVerification/verify.sh --write-samples`.
