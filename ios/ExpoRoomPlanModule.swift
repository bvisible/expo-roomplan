import ExpoModulesCore
import ModelIO
import QuickLook
import RoomPlan
import SceneKit
import UIKit

@available(iOS 17.0, *)
private class QuickLookDataSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return url as QLPreviewItem
    }
}

@available(iOS 17.0, *)
private class SceneViewerController: UIViewController {
    struct AnnotationData {
        let x: Float
        let y: Float
        let z: Float
        let content: String
        let kind: String
        let photoPath: String?
    }

    let url: URL
    let annotations: [AnnotationData]
    private var sceneView: SCNView!
    // Map of marker nodes back to their annotation index, used by the tap
    // handler to find which annotation was tapped.
    private var markerNodeToIndex: [SCNNode: Int] = [:]
    // Active popup view shown when an annotation is tapped.
    private weak var activePopup: UIView?

    init(url: URL, annotations: [AnnotationData]) {
        self.url = url
        self.annotations = annotations
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        sceneView = SCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.allowsCameraControl = true
        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        sceneView.defaultCameraController.inertiaEnabled = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.antialiasingMode = .multisampling4X
        sceneView.backgroundColor = .systemBackground
        view.addSubview(sceneView)

        if let scene = try? SCNScene(url: url, options: nil) {
            sceneView.scene = scene
            for (i, ann) in annotations.enumerated() {
                let node = makeMarkerNode(number: i + 1, x: ann.x, y: ann.y, z: ann.z)
                scene.rootNode.addChildNode(node)
                markerNodeToIndex[node] = i
            }
        } else {
            sceneView.scene = SCNScene()
        }


        // Tap on a sphere → show the annotation popup. Tap elsewhere → dismiss
        // any active popup.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSceneTap(_:)))
        tap.cancelsTouchesInView = false
        sceneView.addGestureRecognizer(tap)

        // Done button (top-left).
        let doneButton = UIButton(type: .system)
        doneButton.setTitle("Done", for: .normal)
        doneButton.setTitleColor(.label, for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        let bg = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.layer.cornerRadius = 18
        bg.clipsToBounds = true
        view.addSubview(bg)
        bg.contentView.addSubview(doneButton)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bg.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            bg.heightAnchor.constraint(equalToConstant: 36),
            bg.widthAnchor.constraint(equalToConstant: 80),
            doneButton.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            doneButton.centerYAnchor.constraint(equalTo: bg.centerYAnchor)
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func handleSceneTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: sceneView)

        // First, see if the user tapped an annotation marker (or a child of one).
        let hits = sceneView.hitTest(point, options: [
            SCNHitTestOption.boundingBoxOnly: true,
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: true
        ])
        for h in hits {
            // Walk up the parent chain to find a registered marker node.
            var n: SCNNode? = h.node
            while let candidate = n {
                if let idx = markerNodeToIndex[candidate] {
                    showPopup(forIndex: idx, near: point)
                    return
                }
                n = candidate.parent
            }
        }

        // Tap outside any marker → dismiss the popup if any.
        activePopup?.removeFromSuperview()
        activePopup = nil
    }

    private func showPopup(forIndex index: Int, near point: CGPoint) {
        activePopup?.removeFromSuperview()
        guard index < annotations.count else { return }
        let ann = annotations[index]

        let popup = UIView()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.97)
        popup.layer.cornerRadius = 14
        popup.layer.borderColor = UIColor.separator.cgColor
        popup.layer.borderWidth = 0.5
        popup.layer.shadowColor = UIColor.black.cgColor
        popup.layer.shadowOpacity = 0.18
        popup.layer.shadowRadius = 12
        popup.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.addSubview(popup)

        // Header: "1" badge + index label.
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = UIColor(red: 0.05, green: 0.65, blue: 0.93, alpha: 1)
        badge.layer.cornerRadius = 12
        let badgeLabel = UILabel()
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.text = "\(index + 1)"
        badgeLabel.textColor = .white
        badgeLabel.font = .systemFont(ofSize: 13, weight: .heavy)
        badgeLabel.textAlignment = .center
        badge.addSubview(badgeLabel)

        // Photo (optional)
        var photoView: UIImageView?
        if let path = ann.photoPath, let img = Self.loadImage(from: path) {
            let iv = UIImageView(image: img)
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = 8
            photoView = iv
        }

        // Content text
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = ann.content.isEmpty ? "—" : ann.content
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 14)
        label.textColor = .label

        // Close button
        let closeBtn = UIButton(type: .system)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeBtn.tintColor = .secondaryLabel
        closeBtn.addTarget(self, action: #selector(dismissPopup), for: .touchUpInside)

        popup.addSubview(badge)
        popup.addSubview(label)
        popup.addSubview(closeBtn)
        if let photoView { popup.addSubview(photoView) }

        var cs: [NSLayoutConstraint] = [
            popup.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            popup.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            popup.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            badge.leadingAnchor.constraint(equalTo: popup.leadingAnchor, constant: 12),
            badge.topAnchor.constraint(equalTo: popup.topAnchor, constant: 12),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: popup.trailingAnchor, constant: -10),
            closeBtn.topAnchor.constraint(equalTo: popup.topAnchor, constant: 10),
            closeBtn.widthAnchor.constraint(equalToConstant: 24),
            closeBtn.heightAnchor.constraint(equalToConstant: 24)
        ]

        if let photoView {
            cs.append(contentsOf: [
                photoView.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
                photoView.topAnchor.constraint(equalTo: popup.topAnchor, constant: 12),
                photoView.widthAnchor.constraint(equalToConstant: 56),
                photoView.heightAnchor.constraint(equalToConstant: 56),
                label.leadingAnchor.constraint(equalTo: photoView.trailingAnchor, constant: 10),
                label.topAnchor.constraint(equalTo: popup.topAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8),
                label.bottomAnchor.constraint(lessThanOrEqualTo: popup.bottomAnchor, constant: -12),
                photoView.bottomAnchor.constraint(lessThanOrEqualTo: popup.bottomAnchor, constant: -12)
            ])
        } else {
            cs.append(contentsOf: [
                label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
                label.topAnchor.constraint(equalTo: popup.topAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8),
                label.bottomAnchor.constraint(equalTo: popup.bottomAnchor, constant: -12)
            ])
        }
        NSLayoutConstraint.activate(cs)
        activePopup = popup
        _ = point // currently not used — popup docks to bottom; could reuse to anchor near tap.
    }

    @objc private func dismissPopup() {
        activePopup?.removeFromSuperview()
        activePopup = nil
    }

    private static func loadImage(from path: String) -> UIImage? {
        let p = path.hasPrefix("file://") ? String(path.dropFirst("file://".count)) : path
        let decoded = p.removingPercentEncoding ?? p
        return UIImage(contentsOfFile: decoded)
    }

    private func makeMarkerNode(number: Int, x: Float, y: Float, z: Float) -> SCNNode {
        // Solid black sphere — neutral against the white room geometry.
        let sphereRadius: CGFloat = 0.11
        let sphere = SCNSphere(radius: sphereRadius)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.black
        mat.lightingModel = .constant
        sphere.firstMaterial = mat
        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.position = SCNVector3(x, y, z)
        // Always render in front of room geometry so the marker doesn't get
        // half-buried in a wall surface.
        sphereNode.renderingOrder = 100

        // Number text — the radiant element. We layer two SCNText nodes:
        //  - a slightly larger blurred-looking halo behind, in cyan
        //  - the sharp white digit on top
        // Without HDR/bloom we fake the radiance by stacking a soft outline
        // behind the digit.
        let textScale: Float = 0.30
        let frontZ = Float(sphereRadius) + 0.01

        // Background "halo" — same digit, larger, opaque cyan. Sits behind
        // the white digit so the cyan only shows as a ring around the digit.
        // Using `.alpha` blend (not `.add`) so the cyan stays cyan even on
        // white walls — additive blending would clamp to white and disappear.
        let haloText = SCNText(string: "\(number)", extrusionDepth: 0.0)
        haloText.font = UIFont.systemFont(ofSize: 0.6, weight: .heavy)
        haloText.flatness = 0.05
        let haloMat = SCNMaterial()
        haloMat.diffuse.contents = UIColor.clear
        haloMat.emission.contents = UIColor(red: 0.05, green: 0.65, blue: 0.95, alpha: 1.0)
        haloMat.lightingModel = .constant
        haloMat.writesToDepthBuffer = false
        haloText.firstMaterial = haloMat
        let haloNode = SCNNode(geometry: haloText)
        let (hmn, hmx) = haloNode.boundingBox
        haloNode.pivot = SCNMatrix4MakeTranslation(
            hmn.x + (hmx.x - hmn.x) / 2,
            hmn.y + (hmx.y - hmn.y) / 2,
            0
        )
        haloNode.scale = SCNVector3(textScale * 1.45, textScale * 1.45, 0.001)
        haloNode.position = SCNVector3(0, 0, frontZ - 0.002)
        haloNode.renderingOrder = 101
        // Subtle pulse so the halo "breathes".
        let pulseUp = SCNAction.scale(to: CGFloat(textScale * 1.65), duration: 0.9)
        pulseUp.timingMode = .easeInEaseOut
        let pulseDown = SCNAction.scale(to: CGFloat(textScale * 1.45), duration: 0.9)
        pulseDown.timingMode = .easeInEaseOut
        haloNode.runAction(SCNAction.repeatForever(SCNAction.sequence([pulseUp, pulseDown])))

        // Foreground crisp digit in white.
        let text = SCNText(string: "\(number)", extrusionDepth: 0.0)
        text.font = UIFont.systemFont(ofSize: 0.6, weight: .heavy)
        text.flatness = 0.05
        text.firstMaterial?.diffuse.contents = UIColor.white
        text.firstMaterial?.emission.contents = UIColor.white
        text.firstMaterial?.lightingModel = .constant
        let textNode = SCNNode(geometry: text)
        let (mn, mx) = textNode.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            mn.x + (mx.x - mn.x) / 2,
            mn.y + (mx.y - mn.y) / 2,
            0
        )
        textNode.scale = SCNVector3(textScale, textScale, 0.001)
        textNode.position = SCNVector3(0, 0, frontZ)
        textNode.renderingOrder = 102

        let billboard = SCNBillboardConstraint()
        haloNode.constraints = [billboard]
        textNode.constraints = [billboard]
        sphereNode.constraints = [billboard]
        sphereNode.addChildNode(haloNode)
        sphereNode.addChildNode(textNode)
        return sphereNode
    }
}

@available(iOS 17.0, *)
struct SceneAnnotationRecord: Record {
    @Field var x: Double = 0
    @Field var y: Double = 0
    @Field var z: Double = 0
    @Field var content: String = ""
    @Field var kind: String = "text"
    @Field var photoPath: String?
}

@available(iOS 17.0, *)
public class ExpoRoomPlanModule: Module {
    private var captureViewController: RoomPlanCaptureViewController?
    private var quickLookDataSource: QuickLookDataSource?
    private var sceneViewer: SceneViewerController?

    public func definition() -> ModuleDefinition {
        Name("ExpoRoomPlan")

        Events("onDismissEvent")

        // Sync check — RoomCaptureSession.isSupported returns true only on
        // devices with LiDAR (iPhone 12 Pro+, iPhone Pro 13/14/15/16/17,
        // iPad Pro 2020+). Used by JS to grey out the entry point on
        // unsupported devices.
        Function("isSupported") { () -> Bool in
            return RoomCaptureSession.isSupported
        }

        // Convert a USDZ produced by RoomPlan into a glTF binary (.glb) on
        // device. Apple's ModelIO does NOT support glTF export, and no
        // maintained third-party Swift library does either, so we load the
        // USDZ via MDLAsset (which is supported) and then serialize the mesh
        // hierarchy ourselves into a minimal glTF 2.0 binary container.
        //
        // Output glTF includes positions (required), normals + texture
        // coordinates when present, and triangle index buffers. Materials
        // are intentionally omitted — RoomPlan parametric output is
        // texture-less and Three.js will apply a default PBR material.
        AsyncFunction("exportGLB") { (usdzPath: String, outPath: String, promise: Promise) in
            let normalizedIn = usdzPath.hasPrefix("file://")
                ? String(usdzPath.dropFirst("file://".count))
                : usdzPath
            let normalizedOut = outPath.hasPrefix("file://")
                ? String(outPath.dropFirst("file://".count))
                : outPath
            let inUrl = URL(fileURLWithPath: normalizedIn)
            let outUrl = URL(fileURLWithPath: normalizedOut)

            guard FileManager.default.fileExists(atPath: inUrl.path) else {
                promise.reject("EXPORT_GLB_INPUT_MISSING",
                               "Input USDZ does not exist at \(inUrl.path)")
                return
            }

            do {
                let exporter = GLBExporter()
                try exporter.export(usdzURL: inUrl, to: outUrl)
                promise.resolve(outUrl.path)
            } catch let GLBExporter.ExportError.noMeshes(detail) {
                promise.reject("EXPORT_GLB_NO_MESHES", detail)
            } catch {
                promise.reject("EXPORT_GLB_FAILED",
                               "GLB export failed: \(error.localizedDescription)")
            }
        }

        AsyncFunction("startCapture") {
            (scanName: String, exportType: String, sendFileLoc: Bool) in
            DispatchQueue.main.async {
                let captureVC = RoomPlanCaptureViewController()

                captureVC.scanName = scanName
                captureVC.modalPresentationStyle = .fullScreen
                captureVC.exportType = exportType
                captureVC.sendFileLoc = sendFileLoc

                captureVC.onDismiss = { eventData in
                    self.sendEvent("onDismissEvent", eventData)
                }

                guard
                    let rootVC = UIApplication.shared.connectedScenes
                        .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                        .first?.rootViewController
                else {
                    return
                }

                rootVC.present(captureVC, animated: true, completion: nil)
                self.captureViewController = captureVC
            }
        }

        AsyncFunction("stopCapture") {
            DispatchQueue.main.async {
                self.captureViewController?.stopSession()
                self.captureViewController?.dismiss(
                    animated: true,
                    completion: nil
                )
            }
        }

        AsyncFunction("presentQuickLook") { (filePath: String) in
            DispatchQueue.main.async {
                let url = Self.resolveFileURL(filePath)
                guard let url, FileManager.default.fileExists(atPath: url.path) else {
                    return
                }

                let dataSource = QuickLookDataSource(url: url)
                self.quickLookDataSource = dataSource

                let preview = QLPreviewController()
                preview.dataSource = dataSource
                preview.modalPresentationStyle = .fullScreen

                guard let topVC = Self.topViewController() else { return }
                topVC.present(preview, animated: true, completion: nil)
            }
        }

        // Custom 3D viewer: SceneKit-based, loads the USDZ and adds numbered
        // sphere markers at each annotation's world position. Tap on a sphere
        // shows the annotation content. Object-only (no AR), separate from QL.
        AsyncFunction("presentSceneViewer") {
            (filePath: String, annotations: [SceneAnnotationRecord]) in
            DispatchQueue.main.async {
                let url = Self.resolveFileURL(filePath)
                guard let url, FileManager.default.fileExists(atPath: url.path) else {
                    return
                }
                let mapped = annotations.map { ann in
                    SceneViewerController.AnnotationData(
                        x: Float(ann.x),
                        y: Float(ann.y),
                        z: Float(ann.z),
                        content: ann.content,
                        kind: ann.kind,
                        photoPath: ann.photoPath
                    )
                }
                let viewer = SceneViewerController(url: url, annotations: mapped)
                viewer.modalPresentationStyle = .fullScreen
                self.sceneViewer = viewer
                guard let topVC = Self.topViewController() else { return }
                topVC.present(viewer, animated: true, completion: nil)
            }
        }
    }

    private static func resolveFileURL(_ filePath: String) -> URL? {
        let path = filePath.hasPrefix("file://")
            ? String(filePath.dropFirst("file://".count))
            : filePath
        let decoded = path.removingPercentEncoding ?? path
        return URL(fileURLWithPath: decoded)
    }

    private static func topViewController() -> UIViewController? {
        guard
            let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                .first?.rootViewController
        else { return nil }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }
}

// MARK: - GLBExporter
//
// Minimal USDZ → glTF 2.0 binary writer. Loads the USDZ via ModelIO so we
// inherit Apple's USD parser, then walks the MDLObject hierarchy ourselves
// and serializes nodes / meshes / accessors / bufferViews into the glTF
// JSON + BIN chunk format. Materials and textures are intentionally not
// translated — RoomPlan parametric output ships without textures, and
// Three.js will fall back to a default material on consumption.
@available(iOS 17.0, *)
private final class GLBExporter {

    enum ExportError: Error {
        case noMeshes(String)
    }

    // glTF component types.
    private static let GLTF_BYTE: Int           = 5120
    private static let GLTF_UNSIGNED_BYTE: Int  = 5121
    private static let GLTF_SHORT: Int          = 5122
    private static let GLTF_UNSIGNED_SHORT: Int = 5123
    private static let GLTF_UNSIGNED_INT: Int   = 5125
    private static let GLTF_FLOAT: Int          = 5126
    // glTF buffer view targets.
    private static let GLTF_ARRAY_BUFFER: Int          = 34962
    private static let GLTF_ELEMENT_ARRAY_BUFFER: Int  = 34963
    // glTF primitive modes.
    private static let GLTF_MODE_TRIANGLES: Int = 4
    private static let GLTF_MODE_LINES: Int     = 1

    private var binData = Data()
    private var bufferViews: [[String: Any]] = []
    private var accessors: [[String: Any]] = []
    private var meshesJson: [[String: Any]] = []
    private var nodesJson: [[String: Any]] = []
    private var rootNodes: [Int] = []

    func export(usdzURL: URL, to outURL: URL) throws {
        let asset = MDLAsset(url: usdzURL)
        // Force materials/textures to load before we walk — even though we
        // don't serialize textures, this ensures meshes are fully populated.
        asset.loadTextures()

        for i in 0..<asset.count {
            let obj = asset.object(at: i)
            let nodeIdx = walkObject(obj)
            rootNodes.append(nodeIdx)
        }

        if meshesJson.isEmpty {
            throw ExportError.noMeshes(
                "USDZ contains no MDLMesh — verify RoomPlan export succeeded.")
        }

        var gltf: [String: Any] = [
            "asset": [
                "version": "2.0",
                "generator": "expo-roomplan custom GLB exporter"
            ],
            "scene": 0,
            "scenes": [["nodes": rootNodes]],
            "nodes": nodesJson,
            "meshes": meshesJson,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": binData.count]]
        ]
        // Drop empty arrays from the root — glTF validators tolerate them
        // but they bloat the JSON for no benefit.
        if accessors.isEmpty { gltf.removeValue(forKey: "accessors") }
        if bufferViews.isEmpty { gltf.removeValue(forKey: "bufferViews") }

        let jsonData = try JSONSerialization.data(
            withJSONObject: gltf,
            options: [.sortedKeys])
        let jsonPadded = padTo4(jsonData, padByte: 0x20) // space
        let binPadded = padTo4(binData, padByte: 0x00)   // null

        let totalLength = 12 + 8 + jsonPadded.count + 8 + binPadded.count
        var glb = Data(capacity: totalLength)
        // GLB header: magic "glTF", version 2, total length.
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])
        appendUInt32(2, to: &glb)
        appendUInt32(UInt32(totalLength), to: &glb)
        // JSON chunk: length, type "JSON", payload.
        appendUInt32(UInt32(jsonPadded.count), to: &glb)
        glb.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])
        glb.append(jsonPadded)
        // BIN chunk: length, type "BIN\0", payload.
        appendUInt32(UInt32(binPadded.count), to: &glb)
        glb.append(contentsOf: [0x42, 0x49, 0x4E, 0x00])
        glb.append(binPadded)

        try glb.write(to: outURL, options: .atomic)
    }

    // MARK: - Hierarchy walking

    private func walkObject(_ obj: MDLObject) -> Int {
        // Reserve our slot in the nodes array first so that recursive child
        // calls produce later indices than ours.
        let nodeIdx = nodesJson.count
        nodesJson.append([:])

        var node: [String: Any] = [:]
        if !obj.name.isEmpty {
            node["name"] = obj.name
        }
        if let m = obj.transform?.matrix, !matrixIsIdentity(m) {
            node["matrix"] = matrixToColumnMajorFloats(m)
        }
        if let mesh = obj as? MDLMesh, mesh.vertexCount > 0 {
            node["mesh"] = processMesh(mesh)
        }

        var childIndices: [Int] = []
        for child in obj.children.objects {
            let cIdx = walkObject(child)
            childIndices.append(cIdx)
        }
        if !childIndices.isEmpty {
            node["children"] = childIndices
        }

        nodesJson[nodeIdx] = node
        return nodeIdx
    }

    // MARK: - Mesh processing

    private func processMesh(_ mesh: MDLMesh) -> Int {
        let meshIdx = meshesJson.count

        // Per-vertex attributes are shared across submeshes — extract once.
        guard let pos = extractFloat3(mesh, attribute: MDLVertexAttributePosition)
        else {
            // No positions = nothing to draw. Return an empty mesh slot so
            // the index map stays consistent.
            meshesJson.append(["primitives": []])
            return meshIdx
        }
        let posAccessor = appendAccessor(
            data: pos.buffer,
            componentType: GLBExporter.GLTF_FLOAT,
            count: mesh.vertexCount,
            type: "VEC3",
            target: GLBExporter.GLTF_ARRAY_BUFFER,
            min: pos.min.map { Double($0) },
            max: pos.max.map { Double($0) })

        var attributes: [String: Int] = ["POSITION": posAccessor]

        if let normal = extractFloat3(mesh, attribute: MDLVertexAttributeNormal) {
            attributes["NORMAL"] = appendAccessor(
                data: normal.buffer,
                componentType: GLBExporter.GLTF_FLOAT,
                count: mesh.vertexCount,
                type: "VEC3",
                target: GLBExporter.GLTF_ARRAY_BUFFER)
        }
        if let uv = extractFloat2(mesh, attribute: MDLVertexAttributeTextureCoordinate) {
            attributes["TEXCOORD_0"] = appendAccessor(
                data: uv.buffer,
                componentType: GLBExporter.GLTF_FLOAT,
                count: mesh.vertexCount,
                type: "VEC2",
                target: GLBExporter.GLTF_ARRAY_BUFFER)
        }

        var primitives: [[String: Any]] = []
        if let submeshes = mesh.submeshes as? [MDLSubmesh] {
            for sub in submeshes {
                guard let idx = extractIndices(sub, vertexCount: mesh.vertexCount) else {
                    continue
                }
                let idxAccessor = appendAccessor(
                    data: idx.buffer,
                    componentType: idx.componentType,
                    count: sub.indexCount,
                    type: "SCALAR",
                    target: GLBExporter.GLTF_ELEMENT_ARRAY_BUFFER)
                primitives.append([
                    "attributes": attributes,
                    "indices": idxAccessor,
                    "mode": glTFMode(for: sub.geometryType)
                ])
            }
        }
        // If the mesh has no submeshes (rare for RoomPlan output), emit a
        // single primitive that draws all vertices as a triangle list.
        if primitives.isEmpty {
            primitives.append([
                "attributes": attributes,
                "mode": GLBExporter.GLTF_MODE_TRIANGLES
            ])
        }

        meshesJson.append(["primitives": primitives])
        return meshIdx
    }

    // MARK: - Vertex attribute extraction

    private func extractFloat3(
        _ mesh: MDLMesh,
        attribute name: String
    ) -> (buffer: Data, min: [Float], max: [Float])? {
        guard let attr = mesh.vertexAttributeData(forAttributeNamed: name, as: .float3) else {
            return nil
        }
        let count = mesh.vertexCount
        var packed = Data(count: count * 12) // 3 floats × 4 bytes
        var minV: [Float] = [.infinity, .infinity, .infinity]
        var maxV: [Float] = [-.infinity, -.infinity, -.infinity]

        packed.withUnsafeMutableBytes { rawDest in
            guard let dest = rawDest.baseAddress?.assumingMemoryBound(to: Float.self)
            else { return }
            for i in 0..<count {
                let src = attr.dataStart
                    .advanced(by: i * attr.stride)
                    .assumingMemoryBound(to: Float.self)
                let x = src[0], y = src[1], z = src[2]
                dest[i * 3 + 0] = x
                dest[i * 3 + 1] = y
                dest[i * 3 + 2] = z
                if x < minV[0] { minV[0] = x }
                if y < minV[1] { minV[1] = y }
                if z < minV[2] { minV[2] = z }
                if x > maxV[0] { maxV[0] = x }
                if y > maxV[1] { maxV[1] = y }
                if z > maxV[2] { maxV[2] = z }
            }
        }
        return (packed, minV, maxV)
    }

    private func extractFloat2(
        _ mesh: MDLMesh,
        attribute name: String
    ) -> (buffer: Data, min: [Float], max: [Float])? {
        guard let attr = mesh.vertexAttributeData(forAttributeNamed: name, as: .float2) else {
            return nil
        }
        let count = mesh.vertexCount
        var packed = Data(count: count * 8) // 2 floats × 4 bytes
        var minV: [Float] = [.infinity, .infinity]
        var maxV: [Float] = [-.infinity, -.infinity]

        packed.withUnsafeMutableBytes { rawDest in
            guard let dest = rawDest.baseAddress?.assumingMemoryBound(to: Float.self)
            else { return }
            for i in 0..<count {
                let src = attr.dataStart
                    .advanced(by: i * attr.stride)
                    .assumingMemoryBound(to: Float.self)
                let u = src[0], v = src[1]
                dest[i * 2 + 0] = u
                dest[i * 2 + 1] = v
                if u < minV[0] { minV[0] = u }
                if v < minV[1] { minV[1] = v }
                if u > maxV[0] { maxV[0] = u }
                if v > maxV[1] { maxV[1] = v }
            }
        }
        return (packed, minV, maxV)
    }

    private func extractIndices(
        _ submesh: MDLSubmesh,
        vertexCount: Int
    ) -> (buffer: Data, componentType: Int)? {
        let count = submesh.indexCount
        if count == 0 { return nil }
        // glTF requires UNSIGNED_INT (5125) when index values can exceed
        // 65535. RoomPlan rooms can easily cross that threshold.
        let useUInt32 = vertexCount > Int(UInt16.max)
        if useUInt32 {
            let indexBuffer = submesh.indexBuffer(asIndexType: .uInt32)
            let map = indexBuffer.map()
            let data = Data(bytes: map.bytes, count: count * 4)
            return (data, GLBExporter.GLTF_UNSIGNED_INT)
        } else {
            let indexBuffer = submesh.indexBuffer(asIndexType: .uInt16)
            let map = indexBuffer.map()
            let data = Data(bytes: map.bytes, count: count * 2)
            return (data, GLBExporter.GLTF_UNSIGNED_SHORT)
        }
    }

    // MARK: - Accessor / bufferView helpers

    private func appendAccessor(
        data: Data,
        componentType: Int,
        count: Int,
        type: String,
        target: Int? = nil,
        min: [Double]? = nil,
        max: [Double]? = nil
    ) -> Int {
        // glTF requires bufferView byteOffset to be aligned to the component
        // size. We pre-pad binData so each new chunk starts on a 4-byte
        // boundary, which is sufficient for all types we emit (float, ushort,
        // uint).
        while binData.count % 4 != 0 { binData.append(0) }
        let offset = binData.count
        binData.append(data)

        var bv: [String: Any] = [
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": data.count
        ]
        if let t = target {
            bv["target"] = t
        }
        bufferViews.append(bv)

        var acc: [String: Any] = [
            "bufferView": bufferViews.count - 1,
            "componentType": componentType,
            "count": count,
            "type": type
        ]
        if let mn = min { acc["min"] = mn }
        if let mx = max { acc["max"] = mx }
        accessors.append(acc)
        return accessors.count - 1
    }

    // MARK: - Format helpers

    private func glTFMode(for type: MDLGeometryType) -> Int {
        switch type {
        case .triangles, .quads:           return GLBExporter.GLTF_MODE_TRIANGLES
        case .lines:                       return GLBExporter.GLTF_MODE_LINES
        default:                           return GLBExporter.GLTF_MODE_TRIANGLES
        }
    }

    private func matrixIsIdentity(_ m: matrix_float4x4) -> Bool {
        return m.columns.0 == SIMD4<Float>(1, 0, 0, 0)
            && m.columns.1 == SIMD4<Float>(0, 1, 0, 0)
            && m.columns.2 == SIMD4<Float>(0, 0, 1, 0)
            && m.columns.3 == SIMD4<Float>(0, 0, 0, 1)
    }

    private func matrixToColumnMajorFloats(_ m: matrix_float4x4) -> [Float] {
        // glTF expects 16 floats in column-major order, which matches simd's
        // memory layout.
        return [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
        ]
    }

    private func padTo4(_ data: Data, padByte: UInt8) -> Data {
        let remainder = data.count % 4
        if remainder == 0 { return data }
        var out = data
        out.append(contentsOf: Array(repeating: padByte, count: 4 - remainder))
        return out
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        // glTF binary is little-endian; iOS ARM is little-endian.
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { ptr in
            data.append(ptr.bindMemory(to: UInt8.self))
        }
    }
}
