import ExpoModulesCore
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
