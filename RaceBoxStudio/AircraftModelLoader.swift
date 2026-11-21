import Foundation
import SceneKit
import simd

/// Construit le nœud SceneKit du CAP 10 à partir de `CAP10.usdz` (le même modèle que iABView).
/// Le nœud renvoyé est centré, a une plus grande dimension de `targetSize` unités, et son orientation
/// native est décrite par `nativeAxes` (voir `AircraftScene`).
nonisolated enum AircraftModelLoader {
    /// Plus grande dimension visée.
    private static let targetSize: Float = 4.2
    /// Le mesh d'aile `part001` du CAP 10 embarque des pièces d'animation égarées bien derrière la dérive
    /// (jusqu'à 8,9 m pour une queue à 5,1 m). Les sommets au-delà de cette limite (unités du fichier,
    /// nez vers -Y) sont repliés au chargement.
    private static let maximumTailExtent: Float = 5.6
    /// Durée d'un tour d'hélice à l'écran, en secondes.
    private static let propellerTurnDuration: TimeInterval = 0.25

    static func makeNode(url explicitURL: URL? = nil) throws -> SCNNode {
        guard let url = explicitURL ?? Bundle.main.url(forResource: "CAP10", withExtension: "usdz") else {
            throw AircraftModelError.missingFile
        }
        let model = try texturedNode(from: url)
        model.simdOrientation = zCorrection
        return model
    }

    private static let zCorrection = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))

    private static func texturedNode(from url: URL) throws -> SCNNode {
        let scene = try SCNScene(url: url, options: nil)
        guard let body = scene.rootNode.childNode(withName: "aircraft", recursively: true) else {
            throw AircraftModelError.missingAircraft
        }
        let container = SCNNode()
        container.addChildNode(body)

        body.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            // Beaucoup de surfaces du modèle MSFS n'ont qu'une face : vues de l'autre côté, elles sont invisibles.
            geometry.materials.forEach { $0.isDoubleSided = true }
            if isPropellerBlur(geometry) {
                node.isHidden = true
            } else {
                clipStrayVertices(of: node)
            }
        }

        spinPropeller(in: body)

        guard let bounds = visibleBounds(of: container, relativeTo: container) else {
            throw AircraftModelError.noGeometry
        }
        let center = (bounds.min + bounds.max) / 2
        let largest = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        let scale = largest > 0 ? targetSize / largest : 1

        // `container` porte l'échelle et le recentrage ; le nœud renvoyé reste libre pour l'orientation.
        container.simdScale = SIMD3<Float>(repeating: scale)
        container.simdPosition = -center * scale
        let result = SCNNode()
        result.addChildNode(container)
        return result
    }

    /// Le nœud `prop_anim_AN_` regroupe pales, ogive et flou ; son axe local X est l'axe de l'hélice.
    private static func spinPropeller(in body: SCNNode) {
        var hub: SCNNode?
        body.enumerateHierarchy { node, stop in
            if node.name?.hasPrefix("prop_anim_AN") == true {
                hub = node
                stop.pointee = true
            }
        }
        let turn = SCNAction.rotateBy(x: 2 * .pi, y: 0, z: 0, duration: propellerTurnDuration)
        hub?.runAction(.repeatForever(turn))
    }

    /// Les disques de flou d'hélice sont masqués : ils se superposeraient aux pales.
    private static func isPropellerBlur(_ geometry: SCNGeometry) -> Bool {
        geometry.materials.contains { material in
            let name = (material.name ?? "").uppercased()
            return name.contains("BLUR") || name.contains("PROP_SLOW") || name.contains("PROPELERSIDE")
        }
    }

    /// Boîte englobante des sommets visibles, hors pièces égarées. On parcourt les sommets plutôt que de lire
    /// `boundingBox`, qui compterait aussi ceux que le shader a repliés.
    private static func visibleBounds(
        of root: SCNNode,
        relativeTo reference: SCNNode
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry, !node.isHidden,
                  let positions = geometry.sources(for: .vertex).first,
                  positions.bytesPerComponent == MemoryLayout<Float>.size,
                  positions.componentsPerVector >= 3 else { return }
            positions.data.withUnsafeBytes { raw in
                for index in 0..<positions.vectorCount {
                    let base = positions.dataOffset + index * positions.dataStride
                    let x = raw.loadUnaligned(fromByteOffset: base, as: Float.self)
                    let y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                    let z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                    guard y <= maximumTailExtent else { continue }
                    let point = node.convertPosition(SCNVector3(x, y, z), to: reference)
                    let value = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
                    low = simd_min(low, value)
                    high = simd_max(high, value)
                    found = true
                }
            }
        }
        return found ? (low, high) : nil
    }

    /// Replie au centre les sommets au-delà de `maximumTailExtent` (coordonnées du mesh), ce qui rend leurs
    /// triangles invisibles. On ne reconstruit pas la géométrie : normales et UV y sont indexées par coin de triangle.
    private static func clipStrayVertices(of node: SCNNode) {
        guard let geometry = node.geometry, Float(geometry.boundingBox.max.y) > maximumTailExtent else { return }
        geometry.materials = geometry.materials.map { material in
            let clipped = (material.copy() as? SCNMaterial) ?? material
            clipped.shaderModifiers = [.geometry: tailClipModifier]
            return clipped
        }
    }

    private static let tailClipModifier = """
    #pragma body
    if (_geometry.position.y > \(maximumTailExtent)) {
        _geometry.position = float4(0.0, 0.0, 0.0, 1.0);
    }
    """
}

nonisolated enum AircraftModelError: LocalizedError {
    case missingFile
    case missingAircraft
    case noGeometry

    var errorDescription: String? {
        switch self {
        case .missingFile: "CAP10.usdz est introuvable dans l'app."
        case .missingAircraft: "Le modèle USDZ ne contient pas de nœud « aircraft »."
        case .noGeometry: "Le modèle USDZ ne contient aucune géométrie."
        }
    }
}
