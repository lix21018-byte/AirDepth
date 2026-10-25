import SwiftUI
import ARKit
import SceneKit

/// Renders the live iPhone Air Front TrueDepth Camera + 1,220-vertex 3D ARSCNFaceGeometry wireframe mesh
struct ARPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView(frame: .zero)
        scnView.session = session
        scnView.delegate = context.coordinator
        scnView.automaticallyUpdatesLighting = true
        scnView.backgroundColor = .black
        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let sceneView = renderer as? ARSCNView,
                  anchor is ARFaceAnchor,
                  let device = sceneView.device,
                  let faceGeometry = ARSCNFaceGeometry(device: device) else {
                return nil
            }
            let material = faceGeometry.firstMaterial
            material?.fillMode = .lines
            material?.diffuse.contents = UIColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.78)
            material?.isDoubleSided = true
            return SCNNode(geometry: faceGeometry)
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let faceAnchor = anchor as? ARFaceAnchor,
                  let faceGeometry = node.geometry as? ARSCNFaceGeometry else {
                return
            }
            faceGeometry.update(from: faceAnchor.geometry)
        }
    }
}
