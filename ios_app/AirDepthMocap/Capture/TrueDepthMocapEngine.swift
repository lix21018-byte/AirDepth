import Foundation
import ARKit
import AVFoundation
import Vision
import CoreImage
import UIKit
import Combine
import simd

/// Core Native iOS Engine for iPhone Air:
/// Combines Front TrueDepth Camera (ARFaceTrackingConfiguration + AVDepthData)
/// with Neural Engine Vision Upper-Body & Hand Pose Tracking + Metric 3D Control Law Solver.
final class TrueDepthMocapEngine: NSObject, ObservableObject, ARSessionDelegate {
    let arSession = ARSession()
    let recorder = TakeRecorder()

    // Published UI Telemetry (Updated on Main Thread)
    @Published var isTrueDepthSupported: Bool = ARFaceTrackingConfiguration.isSupported
    @Published var isRecording: Bool = false
    @Published var recordedFramesCount: Int = 0
    @Published var recordingTimecode: String = "00:00:00:00"
    @Published var currentFPS: Int = 60
    @Published var faceDetected: Bool = false
    @Published var upperBodyDetected: Bool = false
    @Published var headDistanceCm: Float = 60.0
    @Published var chestDistanceCm: Float = 66.0
    @Published var leftHandDistanceCm: Float = 58.0
    @Published var rightHandDistanceCm: Float = 58.0
    @Published var headEulerDeg: [Float] = [0, 0, 0]
    @Published var topBlendShapes: [(String, Float)] = []
    @Published var depthPreviewCGImage: CGImage?
    @Published var overlayJoints2D: [String: CGPoint] = [:]
    @Published var recordedTakes: [RecordedTakeItem] = []

    // Internal processing state
    private let visionQueue = DispatchQueue(label: "com.deepth.airdepthmocap.vision", qos: .userInteractive)
    private var isProcessingVision = false
    private var frameCounter: Int = 0
    private var recordingStartTimestamp: Double = 0
    private var lastFrameTimestamp: Double = 0
    private var prevBoneEuler: [String: SIMD3<Float>] = [:]
    private var prevBoneOmega: [String: SIMD3<Float>] = [:]

    // Cached latest Vision Upper-Body 2D normalized joints
    private var latestBodyPoints: [String: (u: Float, v: Float, conf: Float)] = [:]
    private let bodyPointsLock = NSLock()

    override init() {
        super.init()
        arSession.delegate = self
        refreshRecordedTakes()
    }

    func startSession() {
        guard ARFaceTrackingConfiguration.isSupported else {
            isTrueDepthSupported = false
            return
        }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        if #available(iOS 13.0, *) {
            config.maximumNumberOfTrackedFaces = 1
        }
        // Select highest FPS video format available on iPhone Air Front TrueDepth camera
        if let bestFormat = ARFaceTrackingConfiguration.supportedVideoFormats.max(by: { $0.framesPerSecond < $1.framesPerSecond }) {
            config.videoFormat = bestFormat
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pauseSession() {
        arSession.pause()
    }

    func toggleRecording() {
        if isRecording {
            isRecording = false
            recorder.stopRecording { [weak self] _ in
                self?.refreshRecordedTakes()
            }
        } else {
            frameCounter = 0
            recordingStartTimestamp = CACurrentMediaTime()
            if recorder.startRecording() != nil {
                isRecording = true
            }
        }
    }

    func refreshRecordedTakes() {
        let root = TakeRecorder.takesRootDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var items: [RecordedTakeItem] = []
        for url in contents where url.hasDirectoryPath {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let binURL = url.appendingPathComponent("depth_raw_16bit_mm.bin")
            let hasBin = FileManager.default.fileExists(atPath: binURL.path)
            items.append(
                RecordedTakeItem(
                    id: url.lastPathComponent,
                    folderURL: url,
                    createdAt: created,
                    frameCount: 0,
                    durationSec: 0,
                    hasRawDepthBin: hasBin
                )
            )
        }
        items.sort { $0.createdAt > $1.createdAt }
        DispatchQueue.main.async {
            self.recordedTakes = items
        }
    }

    // MARK: - ARSessionDelegate (60Hz TrueDepth Frame Callback)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        let dt = Float(max(now - lastFrameTimestamp, 1.0 / 120.0))
        if lastFrameTimestamp > 0 {
            let instFPS = Int(round(1.0 / Double(dt)))
            if frameCounter % 10 == 0 {
                DispatchQueue.main.async {
                    self.currentFPS = min(max(instFPS, 15), 60)
                }
            }
        }
        lastFrameTimestamp = now

        // 1. Trigger Async Vision Upper-Body + Hand Pose Detection on capturedImage
        if !isProcessingVision {
            isProcessingVision = true
            let pixelBuffer = frame.capturedImage
            visionQueue.async { [weak self] in
                self?.runVisionUpperBodyPose(on: pixelBuffer)
                self?.isProcessingVision = false
            }
        }

        // 2. Process Hardware TrueDepth Map (frame.capturedDepthData -> Float32 meters & UInt16 mm & Turbo CGImage)
        var depthFloatMeters: [Float] = []
        var depthUInt16MM: [UInt16]? = nil
        var depthW = 0
        var depthH = 0
        var depthCGImage: CGImage? = nil

        if let depthData = frame.capturedDepthData {
            let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let dBuf = converted.depthDataMap
            CVPixelBufferLockBaseAddress(dBuf, .readOnly)
            depthW = CVPixelBufferGetWidth(dBuf)
            depthH = CVPixelBufferGetHeight(dBuf)
            let floatPtr = unsafeBitCast(CVPixelBufferGetBaseAddress(dBuf), to: UnsafeMutablePointer<Float>.self)
            let count = depthW * depthH
            depthFloatMeters = Array(UnsafeBufferPointer(start: floatPtr, count: count))
            CVPixelBufferUnlockBaseAddress(dBuf, .readOnly)

            // Convert to 16-bit millimeters & render Turbo Colormap preview image
            let (mmArr, cgImg) = Self.convertDepthToMMAndColormap(
                depthMeters: depthFloatMeters,
                width: depthW,
                height: depthH
            )
            depthUInt16MM = mmArr
            depthCGImage = cgImg
        }

        // 3. Extract Facial 52 ARKit BlendShapes & 6DoF Head Transform from ARFaceAnchor
        var blendShapesDict: [String: Float] = [:]
        for ch in ARKitConstants.all52Channels {
            blendShapesDict[ch.csvName] = 0.0
        }
        var liveLinkRotRad: [String: Float] = [:]
        for rName in ARKitConstants.rotationChannelNames {
            liveLinkRotRad[rName] = 0.0
        }

        var hasFace = false
        var headZ: Float = 0.60
        var headEuler: [Float] = [0, 0, 0]
        var headTrans: [Float] = [0, 0, 0.60]

        if let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, faceAnchor.isTracked {
            hasFace = true
            for ch in ARKitConstants.all52Channels {
                if let val = faceAnchor.blendShapes[ch.location]?.floatValue {
                    blendShapesDict[ch.csvName] = min(max(val, 0.0), 1.0)
                }
            }

            let t = faceAnchor.transform
            let tx = t.columns.3.x
            let ty = t.columns.3.y
            let tz = abs(t.columns.3.z)
            headZ = min(max(tz, 0.20), 2.00)
            headTrans = [tx, ty, headZ]

            let (rollRad, pitchRad, yawRad) = Self.extractEulerAnglesRad(from: t)
            liveLinkRotRad["HeadYaw"] = yawRad
            liveLinkRotRad["HeadPitch"] = pitchRad
            liveLinkRotRad["HeadRoll"] = rollRad

            let rad2deg: Float = 180.0 / .pi
            headEuler = [rollRad * rad2deg, pitchRad * rad2deg, yawRad * rad2deg]

            // Left & Right Eye rotations
            let (lRoll, lPitch, lYaw) = Self.extractEulerAnglesRad(from: faceAnchor.leftEyeTransform)
            let (rRoll, rPitch, rYaw) = Self.extractEulerAnglesRad(from: faceAnchor.rightEyeTransform)
            liveLinkRotRad["LeftEyeYaw"] = lYaw
            liveLinkRotRad["LeftEyePitch"] = lPitch
            liveLinkRotRad["LeftEyeRoll"] = lRoll
            liveLinkRotRad["RightEyeYaw"] = rYaw
            liveLinkRotRad["RightEyePitch"] = rPitch
            liveLinkRotRad["RightEyeRoll"] = rRoll
        }

        // 4. Fuse Vision Upper-Body 2D Joints with Hardware TrueDepth Buffer & Camera Intrinsics
        bodyPointsLock.lock()
        let bodyPts = latestBodyPoints
        bodyPointsLock.unlock()

        let hasBody = !bodyPts.isEmpty
        var joints3D: [String: Joint3DMetric] = [:]
        var uiPoints2D: [String: CGPoint] = [:]

        for (jName, pt) in bodyPts {
            uiPoints2D[jName] = CGPoint(x: CGFloat(pt.u), y: CGFloat(pt.v))
            let sampledZ = Self.sampleTrueDepthMeters(
                uNorm: pt.u,
                vNorm: pt.v,
                depthMeters: depthFloatMeters,
                width: depthW,
                height: depthH,
                fallbackZ: headZ + 0.05
            )
            // Unproject (u, v, Z) to 3D Metric Camera Space (meters)
            let xM = (pt.u - 0.5) * sampledZ * 1.15
            let yM = (0.5 - pt.v) * sampledZ * 1.50
            joints3D[jName] = Joint3DMetric(
                name: jName,
                uNorm: pt.u,
                vNorm: pt.v,
                xMeters: xM,
                yMeters: yM,
                zDepthMeters: sampledZ,
                confidence: pt.conf
            )
        }

        let chestZ = joints3D["neck"]?.zDepthMeters ?? (headZ + 0.05)
        let lWristZ = joints3D["leftWrist"]?.zDepthMeters ?? headZ
        let rWristZ = joints3D["rightWrist"]?.zDepthMeters ?? headZ

        // 5. Solve MetaHuman Upper-Body Bone Rotations & PD Control Law States
        let boneStates = solveMetaHumanBoneControlLaws(
            joints3D: joints3D,
            headEulerDeg: headEuler,
            dt: min(max(dt, 1.0 / 120.0), 0.1)
        )

        // 6. If Recording, Write Frame to TakeRecorder
        let idx = frameCounter
        frameCounter += 1
        let elapsed = isRecording ? max(0, CACurrentMediaTime() - recordingStartTimestamp) : 0
        let smpte = Self.formatSMPTETimecode(frameIndex: idx, fps: max(currentFPS, 30))

        if isRecording {
            let record = MocapFrameRecord(
                frameIndex: idx,
                timestampSec: elapsed,
                smpteTimecode: smpte,
                faceDetected: hasFace,
                upperBodyDetected: hasBody,
                headDistanceMeters: headZ,
                chestDistanceMeters: chestZ,
                leftWristDistanceMeters: lWristZ,
                rightWristDistanceMeters: rWristZ,
                blendShapes: blendShapesDict,
                liveLinkRotationsRad: liveLinkRotRad,
                headEulerDeg: headEuler,
                headTranslationMeters: headTrans,
                joints3DMeters: joints3D,
                boneControlStates: boneStates
            )
            recorder.appendFrame(
                record: record,
                rgbPixelBuffer: frame.capturedImage,
                depthColormapImage: depthCGImage,
                depthMillimetersUInt16: depthUInt16MM
            )
        }

        // 7. Update UI Telemetry at ~20Hz to keep SwiftUI ultra-responsive
        if idx % 3 == 0 {
            let topBS = blendShapesDict
                .sorted { $0.value > $1.value }
                .prefix(6)
                .map { ($0.key, $0.value) }

            DispatchQueue.main.async {
                self.faceDetected = hasFace
                self.upperBodyDetected = hasBody
                self.headDistanceCm = headZ * 100.0
                self.chestDistanceCm = chestZ * 100.0
                self.leftHandDistanceCm = lWristZ * 100.0
                self.rightHandDistanceCm = rWristZ * 100.0
                self.headEulerDeg = headEuler
                self.topBlendShapes = topBS
                self.depthPreviewCGImage = depthCGImage
                self.overlayJoints2D = uiPoints2D
                if self.isRecording {
                    self.recordedFramesCount = self.recorder.recordedFrameCount
                    self.recordingTimecode = smpte
                }
            }
        }
    }

    // MARK: - Vision Upper-Body Pose Detection

    private func runVisionUpperBodyPose(on pixelBuffer: CVPixelBuffer) {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return }
            let recognized = try observation.recognizedPoints(.all)

            let mapping: [(String, VNHumanBodyPoseObservation.JointName)] = [
                ("nose", .nose),
                ("neck", .neck),
                ("leftShoulder", .leftShoulder),
                ("rightShoulder", .rightShoulder),
                ("leftElbow", .leftElbow),
                ("rightElbow", .rightElbow),
                ("leftWrist", .leftWrist),
                ("rightWrist", .rightWrist),
                ("root", .root),
                ("leftHip", .leftHip),
                ("rightHip", .rightHip)
            ]

            var extracted: [String: (u: Float, v: Float, conf: Float)] = [:]
            for (key, jName) in mapping {
                if let pt = recognized[jName], pt.confidence > 0.2 {
                    // Vision normalized coordinates have origin at bottom-left; convert to top-left [0,1]
                    let u = Float(1.0 - pt.location.x) // mirrored front camera
                    let v = Float(1.0 - pt.location.y)
                    extracted[key] = (u: u, v: v, conf: Float(pt.confidence))
                }
            }

            bodyPointsLock.lock()
            latestBodyPoints = extracted
            bodyPointsLock.unlock()
        } catch {
            // Ignore transient single-frame Vision errors
        }
    }

    // MARK: - MetaHuman Upper-Body Bone Rotations & PD Control Law Solver

    private func solveMetaHumanBoneControlLaws(
        joints3D: [String: Joint3DMetric],
        headEulerDeg: [Float],
        dt: Float
    ) -> [String: BoneControlState] {
        var eulerMap: [String: SIMD3<Float>] = [:]
        for bone in ARKitConstants.metaHumanUpperBodyBones {
            eulerMap[bone] = SIMD3<Float>(0, 0, 0)
        }

        // Head & Neck split
        let headVec = SIMD3<Float>(headEulerDeg[0], headEulerDeg[1], headEulerDeg[2])
        eulerMap["neck_01"] = headVec * 0.35
        eulerMap["head"] = headVec * 0.65

        // Spine lean from root/hips to neck
        if let neck = joints3D["neck"], let lSh = joints3D["leftShoulder"], let rSh = joints3D["rightShoulder"] {
            let shRoll = atan2(lSh.yMeters - rSh.yMeters, max(abs(lSh.xMeters - rSh.xMeters), 0.15)) * (180.0 / .pi)
            let shYaw = atan2(lSh.zDepthMeters - rSh.zDepthMeters, max(abs(lSh.xMeters - rSh.xMeters), 0.15)) * (180.0 / .pi)
            let chestPitch = (neck.zDepthMeters - 0.5 * (lSh.zDepthMeters + rSh.zDepthMeters)) * -180.0
            let totalSpine = SIMD3<Float>(shRoll, chestPitch, shYaw)
            eulerMap["pelvis"] = totalSpine * 0.15
            eulerMap["spine_01"] = totalSpine * 0.30
            eulerMap["spine_02"] = totalSpine * 0.30
            eulerMap["spine_03"] = totalSpine * 0.25
        }

        // Left Arm (upperarm_l, lowerarm_l)
        if let sh = joints3D["leftShoulder"], let el = joints3D["leftElbow"] {
            let dx = el.xMeters - sh.xMeters
            let dy = el.yMeters - sh.yMeters
            let dz = el.zDepthMeters - sh.zDepthMeters
            let roll = atan2(dy, max(abs(dx), 0.05)) * (180.0 / .pi)
            let pitch = atan2(-dz, sqrt(dx * dx + dy * dy + 1e-4)) * (180.0 / .pi)
            eulerMap["upperarm_l"] = SIMD3<Float>(roll, pitch, 0)

            if let wr = joints3D["leftWrist"] {
                let fdx = wr.xMeters - el.xMeters
                let fdy = wr.yMeters - el.yMeters
                let fdz = wr.zDepthMeters - el.zDepthMeters
                let fRoll = atan2(fdy, max(abs(fdx), 0.05)) * (180.0 / .pi) - roll
                let fPitch = atan2(-fdz, sqrt(fdx * fdx + fdy * fdy + 1e-4)) * (180.0 / .pi) - pitch
                eulerMap["lowerarm_l"] = SIMD3<Float>(fRoll, fPitch, 0)
            }
        }

        // Right Arm (upperarm_r, lowerarm_r)
        if let sh = joints3D["rightShoulder"], let el = joints3D["rightElbow"] {
            let dx = el.xMeters - sh.xMeters
            let dy = el.yMeters - sh.yMeters
            let dz = el.zDepthMeters - sh.zDepthMeters
            let roll = atan2(dy, max(abs(dx), 0.05)) * (180.0 / .pi)
            let pitch = atan2(-dz, sqrt(dx * dx + dy * dy + 1e-4)) * (180.0 / .pi)
            eulerMap["upperarm_r"] = SIMD3<Float>(roll, pitch, 0)

            if let wr = joints3D["rightWrist"] {
                let fdx = wr.xMeters - el.xMeters
                let fdy = wr.yMeters - el.yMeters
                let fdz = wr.zDepthMeters - el.zDepthMeters
                let fRoll = atan2(fdy, max(abs(fdx), 0.05)) * (180.0 / .pi) - roll
                let fPitch = atan2(-fdz, sqrt(fdx * fdx + fdy * fdy + 1e-4)) * (180.0 / .pi) - pitch
                eulerMap["lowerarm_r"] = SIMD3<Float>(fRoll, fPitch, 0)
            }
        }

        // Compute Velocities, Accelerations & PD Action Control Law Signal u(t)
        let kp: Float = 85.0
        let kd: Float = 16.5
        var states: [String: BoneControlState] = [:]

        for bone in ARKitConstants.metaHumanUpperBodyBones {
            let currEul = eulerMap[bone] ?? SIMD3<Float>(0, 0, 0)
            let prevEul = prevBoneEuler[bone] ?? currEul
            let prevOmg = prevBoneOmega[bone] ?? SIMD3<Float>(0, 0, 0)

            // EMA smoothed Euler & derivatives
            let smoothEul = prevEul * 0.35 + currEul * 0.65
            let omega = (smoothEul - prevEul) / dt
            let alpha = (omega - prevOmg) / dt
            let uCtrl = alpha + kd * omega * 0.15 + kp * (currEul - smoothEul)

            prevBoneEuler[bone] = smoothEul
            prevBoneOmega[bone] = omega

            states[bone] = BoneControlState(
                boneName: bone,
                eulerDeg: [smoothEul.x, smoothEul.y, smoothEul.z],
                angularVelocityDegS: [omega.x, omega.y, omega.z],
                angularAccelDegS2: [alpha.x, alpha.y, alpha.z],
                pdControlSignalU: [uCtrl.x, uCtrl.y, uCtrl.z]
            )
        }

        return states
    }

    // MARK: - TrueDepth Utilities

    private static func sampleTrueDepthMeters(
        uNorm: Float,
        vNorm: Float,
        depthMeters: [Float],
        width: Int,
        height: Int,
        fallbackZ: Float
    ) -> Float {
        guard width > 0, height > 0, depthMeters.count == width * height else {
            return fallbackZ
        }
        let cx = Int(min(max(uNorm * Float(width - 1), 0), Float(width - 1)))
        let cy = Int(min(max(vNorm * Float(height - 1), 0), Float(height - 1)))

        var validSamples: [Float] = []
        for dy in -2...2 {
            for dx in -2...2 {
                let x = min(max(cx + dx, 0), width - 1)
                let y = min(max(cy + dy, 0), height - 1)
                let d = depthMeters[y * width + x]
                if d.isFinite && d > 0.18 && d < 2.50 {
                    validSamples.append(d)
                }
            }
        }
        guard !validSamples.isEmpty else { return fallbackZ }
        validSamples.sort()
        return validSamples[validSamples.count / 2]
    }

    private static func convertDepthToMMAndColormap(
        depthMeters: [Float],
        width: Int,
        height: Int
    ) -> ([UInt16], CGImage?) {
        let count = width * height
        var mmBuffer = [UInt16](repeating: 0, count: count)
        var rgbaBuffer = [UInt8](repeating: 255, count: count * 4)

        let minD: Float = 0.25
        let maxD: Float = 1.60
        let invRange: Float = 1.0 / (maxD - minD)

        for i in 0..<count {
            let d = depthMeters[i]
            if d.isFinite && d > 0.10 && d < 5.0 {
                let mm = Int(round(d * 1000.0))
                mmBuffer[i] = UInt16(min(max(mm, 0), 65535))

                // Normalized inverse depth t in [0, 1] (1 = closest/warm red-yellow, 0 = far/cool blue)
                let t = min(max(1.0 - (d - minD) * invRange, 0.0), 1.0)
                let r = UInt8(min(max(Int(255.0 * min(max(1.5 - abs(4.0 * t - 3.0), 0.0), 1.0)), 0), 255))
                let g = UInt8(min(max(Int(255.0 * min(max(1.5 - abs(4.0 * t - 2.0), 0.0), 1.0)), 0), 255))
                let b = UInt8(min(max(Int(255.0 * min(max(1.5 - abs(4.0 * t - 1.0), 0.0), 1.0)), 0), 255))

                let p = i * 4
                rgbaBuffer[p] = r
                rgbaBuffer[p + 1] = g
                rgbaBuffer[p + 2] = b
                rgbaBuffer[p + 3] = 255
            } else {
                let p = i * 4
                rgbaBuffer[p] = 15
                rgbaBuffer[p + 1] = 18
                rgbaBuffer[p + 2] = 28
                rgbaBuffer[p + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let cgImage: CGImage? = rgbaBuffer.withUnsafeMutableBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return nil }
            guard let ctx = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }

        return (mmBuffer, cgImage)
    }

    private static func extractEulerAnglesRad(from matrix: simd_float4x4) -> (roll: Float, pitch: Float, yaw: Float) {
        let r00 = matrix.columns.0.x
        let r01 = matrix.columns.1.x
        let r02 = matrix.columns.2.x
        let r12 = matrix.columns.2.y
        let r22 = matrix.columns.2.z

        let pitch = asin(min(max(-r12, -1.0), 1.0))
        let yaw = atan2(r02, r22)
        let roll = atan2(r01, r00)
        return (roll, pitch, yaw)
    }

    private static func formatSMPTETimecode(frameIndex: Int, fps: Int) -> String {
        let f = max(fps, 1)
        let totalSec = frameIndex / f
        let ff = frameIndex % f
        let hh = totalSec / 3600
        let mm = (totalSec % 3600) / 60
        let ss = totalSec % 60
        return String(format: "%02d:%02d:%02d:%02d.000", hh, mm, ss, ff)
    }
}
