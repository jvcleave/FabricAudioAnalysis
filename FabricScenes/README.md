# Live audio box scaling

`LiveAudioAnalysis.fabric` contains eight nodes. Live Audio Analysis's Medium
Envelope is increased by 0.35 and sent to the box's X, Y, and Z scale. The box
stays visible during silence and grows as the envelope rises. Each Onset
flashes the box red for at least 0.2 seconds, then it returns to white.

Onset drives a Trigger node named Onset Flash, whose output selects the
white or red color through an Easing node named Onset Color. Change the
Trigger's Minimum Duration to adjust the flash length.

Run the graph and allow Fabric microphone access when macOS asks. The example
requires the `com.jvclabs.FabricAudioAnalysis` plug-in.

Check registration and reopen the saved graph with
`sh PluginVerification/verify.sh` from the repository root.

Regenerate the example with
`sh PluginVerification/verify.sh --write-samples`.
