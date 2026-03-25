//
//  AUInfo.swift
//  ConjureDSPExportAUTemplate
//

import Foundation

/// AU metadata read from the embedded extension's Info.plist.
struct AUInfo {
    let name: String
    let subtype: String
    let manufacturer: String
    let version: Int

    static let placeholder = AUInfo(
        name: "Export Template",
        subtype: "TMPL",
        manufacturer: "CONJ",
        version: 1
    )

    /// Reads AU identity from the embedded extension's Info.plist.
    /// Same pattern as AudioUnitHostModel.discoverExtensionIdentity().
    static func discover() -> AUInfo? {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else { return nil }
        let plistURL = plugInsURL
            .appendingPathComponent("ConjureDSPExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let nsExtension = plist["NSExtension"] as? [String: Any],
              let attrs = nsExtension["NSExtensionAttributes"] as? [String: Any],
              let components = attrs["AudioComponents"] as? [[String: Any]],
              let component = components.first,
              let name = component["name"] as? String,
              let subtype = component["subtype"] as? String,
              let manufacturer = component["manufacturer"] as? String
        else { return nil }
        let version = component["version"] as? Int ?? 1
        return AUInfo(name: name, subtype: subtype, manufacturer: manufacturer, version: version)
    }
}
