import Foundation
import UIKit
import RoomPlan
import ARKit
import RealityKit
import SceneKit
import ExpoModulesCore
import AVFoundation
import simd
import os.log

@available(iOS 17.0, *)
class RoomPlanCaptureUIView: ExpoView, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, UIGestureRecognizerDelegate {
  private var roomCaptureView: RoomCaptureView!
  private let configuration = RoomCaptureSession.Configuration()
  private var pendingRunning: Bool = false
  private var sessionStarted: Bool = false
  // Annotation badges: world-space anchors with overlay UIViews. Each frame,
  // CADisplayLink reprojects the world position onto the screen and updates
  // the badge center, so the badge tracks the wall like a real AR sticker.
  private struct AnnotationBadge {
    let view: UIView
    let worldPosition: simd_float3
  }
  private var annotationBadges: [AnnotationBadge] = []
  private var displayLink: CADisplayLink?
  // Events
  let onStatus = EventDispatcher()
  let onExported = EventDispatcher()
  let onPreview = EventDispatcher()
  let onAnnotateTap = EventDispatcher()

  // Props
  var scanName: String? = nil
  var exportType: String? = nil
  var sendFileLoc: Bool = false
  var exportOnFinish: Bool = true

  private var capturedRooms: [CapturedRoom] = []
  private let structureBuilder = StructureBuilder(options: [.beautifyObjects])
  private var isRunning: Bool = false
  private var lastExportTrigger: Double? = nil
  private var lastFinishTrigger: Double? = nil
  private var lastAddAnotherTrigger: Double? = nil
  private var lastAnnotateTrigger: Double? = nil
  private var pendingFinish: Bool = false
  private var pendingExport: Bool = false
  private var previewEmitted: Bool = false

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)

    roomCaptureView = RoomCaptureView(frame: .zero)
    roomCaptureView.translatesAutoresizingMaskIntoConstraints = false
    roomCaptureView.captureSession.delegate = self
    addSubview(roomCaptureView)

    NSLayoutConstraint.activate([
      roomCaptureView.topAnchor.constraint(equalTo: topAnchor),
      roomCaptureView.bottomAnchor.constraint(equalTo: bottomAnchor),
      roomCaptureView.leadingAnchor.constraint(equalTo: leadingAnchor),
      roomCaptureView.trailingAnchor.constraint(equalTo: trailingAnchor)
    ])

    // Tap-to-annotate: tap anywhere on the AR view to place an annotation on
    // the wall under the finger. cancelsTouchesInView=false so RoomPlan's own
    // gestures keep working.
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.cancelsTouchesInView = false
    tap.delegate = self
    roomCaptureView.addGestureRecognizer(tap)
  }

  // Defer the AR session start until the view is in a window with a real frame
  // — captureSession.run before layout settles can leave the camera view black.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil && pendingRunning && !sessionStarted {
      DispatchQueue.main.async { [weak self] in self?.startSessionIfReady() }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if pendingRunning && !sessionStarted && bounds.width > 0 && window != nil {
      startSessionIfReady()
    }
  }

  // Allow our tap to coexist with RoomPlan's internal gestures.
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    return true
  }

  // Control running state from JS prop. We don't start the AR session
  // immediately — wait until the view is laid out and in a window, otherwise
  // the camera view appears black on first launch.
  func setRunning(_ running: Bool) {
    guard running != isRunning else { return }
    isRunning = running
    if running {
      pendingRunning = true
      startSessionIfReady()
    } else {
      pendingRunning = false
      if sessionStarted {
        roomCaptureView.captureSession.stop(pauseARSession: false)
        sessionStarted = false
      }
      stopDisplayLink()
    }
  }

  deinit {
    stopDisplayLink()
  }

  private func startSessionIfReady() {
    guard pendingRunning, !sessionStarted else { return }
    guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
    if !RoomCaptureSession.isSupported {
      sendError("RoomPlan is not supported on this device.")
      return
    }
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      runConfiguredSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted {
            self.runConfiguredSession()
          } else {
            self.sendError("Camera permission was not granted.")
          }
        }
      }
    case .denied, .restricted:
      sendError("Camera permission is denied or restricted.")
    @unknown default:
      runConfiguredSession()
    }
  }

  private func runConfiguredSession() {
    previewEmitted = false
    sessionStarted = true
    roomCaptureView.captureSession.run(configuration: configuration)
    startDisplayLinkIfNeeded()
  }

  private func startDisplayLinkIfNeeded() {
    if displayLink != nil { return }
    let link = CADisplayLink(target: self, selector: #selector(tickBadges))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  // Reproject each annotation's world position to the current screen position
  // and update its overlay view's center. Hide the badge when it falls behind
  // the camera or outside the viewport.
  private var tickLogCount = 0
  @objc private func tickBadges() {
    guard !annotationBadges.isEmpty,
          let frame = roomCaptureView?.captureSession.arSession.currentFrame else {
      return
    }
    let viewSize = roomCaptureView.bounds.size
    let camera = frame.camera
    if tickLogCount < 5 {
      tickLogCount += 1
      NSLog("[RoomScan] tickBadges: \(annotationBadges.count) badges, viewSize=\(viewSize)")
    }
    for badge in annotationBadges {
      let p = camera.projectPoint(
        badge.worldPosition,
        orientation: .portrait,
        viewportSize: viewSize
      )
      // Behind the camera or far off-screen → hide.
      let camForward = -simd_float3(
        camera.transform.columns.2.x,
        camera.transform.columns.2.y,
        camera.transform.columns.2.z
      )
      let camOrigin = simd_float3(
        camera.transform.columns.3.x,
        camera.transform.columns.3.y,
        camera.transform.columns.3.z
      )
      let toBadge = badge.worldPosition - camOrigin
      let depth = simd_dot(toBadge, camForward)
      let visible = depth > 0
        && p.x > -60 && p.x < viewSize.width + 60
        && p.y > -60 && p.y < viewSize.height + 60
      badge.view.isHidden = !visible
      if visible {
        badge.view.center = CGPoint(x: p.x, y: p.y)
      }
      if tickLogCount <= 5 {
        NSLog("[RoomScan] tick badge: world=(\(badge.worldPosition.x), \(badge.worldPosition.y), \(badge.worldPosition.z)) → screen=(\(p.x), \(p.y)) depth=\(depth) visible=\(visible) parent=\(badge.view.superview != nil ? "yes" : "no")")
      }
    }
  }

  func handleExportTrigger(_ trigger: Double?) {
    // Only handle when a non-nil trigger value actually changes
    guard let trigger else { return }
    if lastExportTrigger != trigger {
      lastExportTrigger = trigger
      // If nothing captured yet, queue export until capture ends
      guard !capturedRooms.isEmpty else {
        pendingExport = true
        return
      }
      exportResults()
    }
  }

  // Stop current capture, present the preview UI, and prepare to export.
  func handleFinishTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastFinishTrigger == trigger { return }
    lastFinishTrigger = trigger
  // Stop capturing to finalize current room; preview will be presented by RoomPlan
  pendingFinish = true
    roomCaptureView.captureSession.stop(pauseARSession: false)
  }

  // Tap-on-AR handler: places a 3D marker at the world position the user
  // tapped, snapped to the closest wall when possible. Emits an event so JS
  // can open the annotation sheet.
  private static let tapLog = OSLog(subsystem: "io.neoffice.app", category: "RoomScan")

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended else { return }
    let screenPoint = recognizer.location(in: roomCaptureView)
    let viewSize = roomCaptureView.bounds.size
    os_log("handleTap at (%.0f, %.0f) viewSize=(%.0f, %.0f)", log: Self.tapLog, type: .info,
           screenPoint.x, screenPoint.y, viewSize.width, viewSize.height)
    guard let arSession = roomCaptureView?.captureSession.arSession,
          let frame = arSession.currentFrame else {
      os_log("handleTap: no current frame", log: Self.tapLog, type: .error)
      return
    }

    var hitWorld: simd_float3?
    var hitNormal: simd_float3? // surface normal at the hit point
    var hitKind = "free"

    // RoomCaptureView is RealityKit-based, so try ARView.makeRaycastQuery
    // first (correct screen→world conversion handled by the view).
    if let arView = findARView(in: roomCaptureView) {
      os_log("found ARView for raycast", log: Self.tapLog, type: .info)
      if let q = arView.makeRaycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .vertical),
         let r = arSession.raycast(q).first {
        hitWorld = Self.position(of: r.worldTransform)
        hitNormal = Self.normal(of: r.worldTransform)
        hitKind = "wall"
        os_log("ARView vertical raycast HIT", log: Self.tapLog, type: .info)
      } else if let q = arView.makeRaycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .any),
                let r = arSession.raycast(q).first {
        hitWorld = Self.position(of: r.worldTransform)
        hitNormal = Self.normal(of: r.worldTransform)
        hitKind = "any"
        os_log("ARView any raycast HIT", log: Self.tapLog, type: .info)
      } else {
        os_log("ARView raycast: NO HIT", log: Self.tapLog, type: .info)
      }
    } else {
      os_log("ARView NOT found in roomCaptureView", log: Self.tapLog, type: .error)
    }

    // ARSCNView fallback (in case RoomPlan ever ships a SceneKit-based view).
    if hitWorld == nil, let arscn = findARSCNView(in: roomCaptureView) {
      if let q = arscn.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .vertical),
         let r = arSession.raycast(q).first {
        hitWorld = Self.position(of: r.worldTransform)
        hitNormal = Self.normal(of: r.worldTransform)
        hitKind = "wall"
      }
    }

    // Last-resort manual fallback: full inverse view×projection unprojection,
    // accounts for portrait orientation properly.
    if hitWorld == nil {
      let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
      os_log("frame.anchors: %d total, %d vertical planes", log: Self.tapLog, type: .info,
             frame.anchors.count, planeAnchors.filter { $0.alignment == .vertical }.count)
      if let ray = unprojectScreenPoint(screenPoint, frame: frame, viewSize: viewSize) {
        if let hit = manualRaycastAgainstVerticalPlanes(
          origin: ray.origin, direction: ray.direction, anchors: frame.anchors
        ) {
          hitWorld = hit
          hitKind = "wall"
        } else {
          hitWorld = ray.origin + ray.direction * 1.5
          hitKind = "free"
        }
      }
    }

    guard let target = hitWorld else {
      os_log("handleTap: no hit world position, aborting", log: Self.tapLog, type: .error)
      return
    }

    // Add a visible 3D marker in the AR scene so the user sees where the
    // annotation landed, anchored to the world.
    addBadge(at: target)

    var payload: [String: Any] = [
      "x": Double(target.x),
      "y": Double(target.y),
      "z": Double(target.z),
      "screenX": Double(screenPoint.x),
      "screenY": Double(screenPoint.y),
      "hitKind": hitKind
    ]
    if let n = hitNormal {
      payload["nx"] = Double(n.x)
      payload["ny"] = Double(n.y)
      payload["nz"] = Double(n.z)
    }
    onAnnotateTap(payload)
  }

  // Legacy "annotate from camera target" — kept for back-compat with the
  // bottom-button flow. Same semantics as the previous implementation but no
  // marker is shown (the tap-on-AR handler is preferred).
  func handleAnnotateTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastAnnotateTrigger == trigger { return }
    lastAnnotateTrigger = trigger
    guard let arSession = roomCaptureView?.captureSession.arSession,
          let frame = arSession.currentFrame else {
      onAnnotateTap(["error": "no_camera_frame"])
      return
    }
    let cam = frame.camera.transform
    let origin = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
    let forward = -simd_float3(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
    let hit = manualRaycastAgainstVerticalPlanes(origin: origin, direction: forward, anchors: frame.anchors)
    let target = hit ?? (origin + forward * 1.5)
    addBadge(at: target)
    onAnnotateTap([
      "x": Double(target.x),
      "y": Double(target.y),
      "z": Double(target.z),
      "hitKind": hit != nil ? "wall" : "free"
    ])
  }

  // For an ARRaycastResult.worldTransform, the column 3 is the hit position
  // and the column 1 (Y axis) is the surface normal at the hit point.
  private static func position(of m: matrix_float4x4) -> simd_float3 {
    return simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
  }

  private static func normal(of m: matrix_float4x4) -> simd_float3 {
    return simd_normalize(simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
  }

  // Walk the view tree to find the ARSCNView that RoomCaptureView uses to
  // render its AR scene. Used both for screen-point raycasts and to attach
  // 3D marker nodes so they appear inline with the rest of the AR overlay.
  private func findARSCNView(in view: UIView) -> ARSCNView? {
    if let v = view as? ARSCNView { return v }
    for sub in view.subviews {
      if let found = findARSCNView(in: sub) { return found }
    }
    return nil
  }

  // Same idea but for RealityKit's ARView (RoomCaptureView is RealityKit-based
  // on iOS 17+).
  private func findARView(in view: UIView) -> ARView? {
    if let v = view as? ARView { return v }
    for sub in view.subviews {
      if let found = findARView(in: sub) { return found }
    }
    return nil
  }

  private struct Ray { let origin: simd_float3; let direction: simd_float3 }

  // Build a world-space ray from a screen point. Uses the inverse of
  // (projection × view) for the current device orientation so the conversion
  // is correct in portrait — manual axis-by-axis math gets the orientation
  // wrong because the camera transform is in landscape-right reference frame
  // even when the device is held in portrait.
  private func unprojectScreenPoint(_ point: CGPoint, frame: ARFrame, viewSize: CGSize) -> Ray? {
    guard viewSize.width > 0, viewSize.height > 0 else { return nil }
    let camera = frame.camera
    let proj = camera.projectionMatrix(for: .portrait, viewportSize: viewSize, zNear: 0.01, zFar: 100)
    let view = camera.viewMatrix(for: .portrait)
    let viewProj = proj * view
    let invVP = viewProj.inverse
    // NDC: x in [-1, 1] left→right, y in [-1, 1] bottom→top (UIKit y is top→bottom so flip).
    let nx = Float((point.x / viewSize.width) * 2 - 1)
    let ny = Float(1 - (point.y / viewSize.height) * 2)
    let nearH = invVP * simd_float4(nx, ny, -1, 1)
    let farH = invVP * simd_float4(nx, ny, 1, 1)
    let nearWorld = simd_float3(nearH.x / nearH.w, nearH.y / nearH.w, nearH.z / nearH.w)
    let farWorld = simd_float3(farH.x / farH.w, farH.y / farH.w, farH.z / farH.w)
    let direction = simd_normalize(farWorld - nearWorld)
    return Ray(origin: nearWorld, direction: direction)
  }

  // Ray-plane intersection against ARKit's detected vertical planes. Returns
  // the closest forward hit within the plane's extent, or nil if none.
  private func manualRaycastAgainstVerticalPlanes(
    origin: simd_float3,
    direction: simd_float3,
    anchors: [ARAnchor]
  ) -> simd_float3? {
    var bestT: Float = Float.infinity
    var bestPoint: simd_float3?
    for anchor in anchors {
      guard let plane = anchor as? ARPlaneAnchor else { continue }
      guard plane.alignment == .vertical else { continue }

      let tm = plane.transform
      let planeCenter = simd_float3(tm.columns.3.x, tm.columns.3.y, tm.columns.3.z)
      // ARPlaneAnchor: local Y axis is the surface normal.
      let planeNormal = simd_float3(tm.columns.1.x, tm.columns.1.y, tm.columns.1.z)

      let denom = simd_dot(direction, planeNormal)
      if abs(denom) < 1e-4 { continue }
      let tHit = simd_dot(planeCenter - origin, planeNormal) / denom
      if tHit <= 0 || tHit >= bestT { continue }
      let hit = origin + direction * tHit

      let localH = tm.inverse * simd_float4(hit.x, hit.y, hit.z, 1)
      let local = simd_float3(localH.x, localH.y, localH.z)
      let ext = plane.planeExtent
      let pad: Float = 0.1
      if abs(local.x) > ext.width / 2 + pad || abs(local.z) > ext.height / 2 + pad {
        continue
      }
      bestT = tHit
      bestPoint = hit
    }
    return bestPoint
  }

  // Add a UIView "pin" overlay anchored to a world position. The CADisplayLink
  // tick updates its on-screen center each frame so it tracks like AR.
  // The badge is added as a subview of roomCaptureView (not self) so it sits
  // above the AR camera content and isn't repositioned by React Native's
  // layout — RN doesn't traverse into native subviews.
  private func addBadge(at position: simd_float3) {
    let number = annotationBadges.count + 1
    let badge = makeBadgeView(number: number)
    badge.center = CGPoint(x: roomCaptureView.bounds.midX, y: roomCaptureView.bounds.midY)
    roomCaptureView.clipsToBounds = false
    roomCaptureView.addSubview(badge)
    roomCaptureView.bringSubviewToFront(badge)
    annotationBadges.append(AnnotationBadge(view: badge, worldPosition: position))
    NSLog("[RoomScan] addBadge #\(number) at world (\(position.x), \(position.y), \(position.z)) — total=\(annotationBadges.count), displayLink=\(displayLink != nil)")
    // Trigger an immediate reprojection so we don't see the badge flash at
    // the screen center for one frame.
    tickBadges()
  }

  private func makeBadgeView(number: Int) -> UIView {
    let size: CGFloat = 36
    let container = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
    container.layer.cornerRadius = size / 2
    container.backgroundColor = UIColor(red: 0.05, green: 0.65, blue: 0.93, alpha: 1) // #0EA5E9
    container.layer.borderWidth = 2
    container.layer.borderColor = UIColor.white.cgColor
    container.layer.shadowColor = UIColor.black.cgColor
    container.layer.shadowOpacity = 0.35
    container.layer.shadowRadius = 4
    container.layer.shadowOffset = CGSize(width: 0, height: 2)
    container.isUserInteractionEnabled = false
    let label = UILabel(frame: container.bounds)
    label.text = "\(number)"
    label.textColor = .white
    label.font = UIFont.systemFont(ofSize: 16, weight: .heavy)
    label.textAlignment = .center
    container.addSubview(label)
    return container
  }

  // Restart session to accumulate another room like the controller-based flow
  func handleAddAnotherTrigger(_ trigger: Double?) {
    guard let trigger else { return }
    if lastAddAnotherTrigger == trigger { return }
    lastAddAnotherTrigger = trigger
    // Ensure current session is stopped, then start again to capture the next room
  pendingFinish = false
  pendingExport = false
  previewEmitted = false
  roomCaptureView.captureSession.stop(pauseARSession: false)
    DispatchQueue.main.async {
      self.roomCaptureView.captureSession.run(configuration: self.configuration)
    }
  }

  // MARK: - RoomPlan delegates
  func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
    if let error {
      sendError(error.localizedDescription)
      return
    }
    let roomBuilder = RoomBuilder(options: [.beautifyObjects])
    Task {
      do {
        let capturedRoom = try await roomBuilder.capturedRoom(from: data)
        self.capturedRooms.append(capturedRoom)
        // If finishing, emit preview now that the processed room exists
        if self.pendingFinish && !self.previewEmitted {
          self.onPreview([:])
          self.previewEmitted = true
          // If requested, export right after preview
          if self.exportOnFinish {
            self.exportResults()
          }
          self.pendingFinish = false
        }
        // If an export was queued, export now
        if self.pendingExport {
          self.pendingExport = false
          self.exportResults()
        } else {
          self.sendStatus(.OK)
        }
      } catch {
        self.sendError("Failed to build captured room: \(error.localizedDescription)")
      }
    }
  }

  func captureSession(_ session: RoomCaptureSession, didFailWith error: any Error) {
    sendError(error.localizedDescription)
  }

  func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    return true
  }
  
  func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    // RoomPlan presented its own preview UI; notify JS once
    if !previewEmitted {
      onPreview([:])
      previewEmitted = true
    }
  }

  // MARK: - Export
  private func exportResults() {
    let exportedScanName = scanName ?? "Room"

    let destinationFolderURL = FileManager.default.temporaryDirectory.appending(path: "Export")
    let destinationURL = destinationFolderURL.appending(path: "\(exportedScanName).usdz")
    let capturedRoomURL = destinationFolderURL.appending(path: "\(exportedScanName).json")

    Task {
      do {
        let structure = try await structureBuilder.capturedStructure(from: capturedRooms)

        try FileManager.default.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)

        var finalExportType = CapturedRoom.USDExportOptions.parametric
        if exportType == "MESH" { finalExportType = .mesh }
        if exportType == "MODEL" { finalExportType = .model }

        let jsonEncoder = JSONEncoder()
        let jsonData = try jsonEncoder.encode(structure)
        try jsonData.write(to: capturedRoomURL)
        try structure.export(to: destinationURL, exportOptions: finalExportType)

        if sendFileLoc {
          self.onExported([
            "scanUrl": destinationURL.absoluteString,
            "jsonUrl": capturedRoomURL.absoluteString
          ])
        }
  // Also emit a final OK status after export
  self.sendStatus(.OK)
      } catch {
        self.sendError("Export failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Events
  private func sendStatus(_ status: ScanStatus) {
  self.onStatus(["status": status.rawValue])
  }

  private func sendError(_ message: String) {
    self.onStatus(["status": ScanStatus.Error.rawValue, "errorMessage": message])
  }
}
