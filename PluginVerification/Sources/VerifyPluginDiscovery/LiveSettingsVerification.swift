import Fabric
import Foundation
import Satin

private enum LiveSettingsError: Error
{
    case verificationFailed(String)
}

func verifyLiveSettings(_ node: Node, in graph: Graph, context: Context) throws -> Graph
{
    guard let originalSettings = node.settings else
    {
        throw LiveSettingsError.verificationFailed("Live Audio Analysis did not expose NodeSettings")
    }
    let settingsType = type(of: originalSettings)
    let initialFPS = 30
    let updatedFPS = 57
    let defaultSettings = try JSONDecoder().decode(settingsType, from: Data("{\"analysisFramesPerSecond\":\(initialFPS)}".utf8))
    let updatedSettings = try JSONDecoder().decode(settingsType, from: Data("{\"analysisFramesPerSecond\":\(updatedFPS)}".utf8))
    guard originalSettings.isEqual(to: defaultSettings) else
    {
        throw LiveSettingsError.verificationFailed("A new node did not default to 30 FPS")
    }

    node.setSettings(updatedSettings)
    let encoded = try JSONEncoder().encode(graph)
    guard var document = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
          var nodes = document["nodeMap"] as? [[String: Any]],
          let nodeIndex = nodes.firstIndex(where: { ($0["value"] as? [String: Any])?["id"] as? String == node.id.uuidString }),
          var savedNode = nodes[nodeIndex]["value"] as? [String: Any],
          let savedSettings = savedNode["liveSettings"] as? [String: Int],
          savedSettings["analysisFramesPerSecond"] == updatedFPS else
    {
        throw LiveSettingsError.verificationFailed("The new FPS was not saved under liveSettings")
    }

    let decoder = JSONDecoder()
    decoder.context = DecoderContext(documentContext: context)
    let reopened = try decoder.decode(Graph.self, from: encoded)
    guard reopened.nodes.first(where: { $0.id == node.id })?.settings?.isEqual(to: updatedSettings) == true else
    {
        throw LiveSettingsError.verificationFailed("The reopened graph lost the updated FPS")
    }

    savedNode.removeValue(forKey: "liveSettings")
    nodes[nodeIndex]["value"] = savedNode
    document["nodeMap"] = nodes
    let legacyData = try JSONSerialization.data(withJSONObject: document)
    let legacy = try decoder.decode(Graph.self, from: legacyData)
    guard legacy.nodes.first(where: { $0.id == node.id })?.settings?.isEqual(to: defaultSettings) == true else
    {
        throw LiveSettingsError.verificationFailed("A saved node without liveSettings did not default to 30 FPS")
    }
    print("Verified Live Audio Analysis saves and restores 57 FPS and defaults older graphs to 30 FPS")
    return reopened
}
