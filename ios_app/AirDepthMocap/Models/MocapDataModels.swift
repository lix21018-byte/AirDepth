import Foundation
import ARKit
import simd

/// Canonical 52 ARKit BlendShape definitions in Unreal Engine Live Link Face CSV order
struct ARKitBlendShapeChannel {
    let csvName: String
    let location: ARFaceAnchor.BlendShapeLocation
}

enum ARKitConstants {
    static let all52Channels: [ARKitBlendShapeChannel] = [
        ARKitBlendShapeChannel(csvName: "EyeBlinkLeft", location: .eyeBlinkLeft),
        ARKitBlendShapeChannel(csvName: "EyeLookDownLeft", location: .eyeLookDownLeft),
        ARKitBlendShapeChannel(csvName: "EyeLookInLeft", location: .eyeLookInLeft),
        ARKitBlendShapeChannel(csvName: "EyeLookOutLeft", location: .eyeLookOutLeft),
        ARKitBlendShapeChannel(csvName: "EyeLookUpLeft", location: .eyeLookUpLeft),
        ARKitBlendShapeChannel(csvName: "EyeSquintLeft", location: .eyeSquintLeft),
        ARKitBlendShapeChannel(csvName: "EyeWideLeft", location: .eyeWideLeft),
        ARKitBlendShapeChannel(csvName: "EyeBlinkRight", location: .eyeBlinkRight),
        ARKitBlendShapeChannel(csvName: "EyeLookDownRight", location: .eyeLookDownRight),
        ARKitBlendShapeChannel(csvName: "EyeLookInRight", location: .eyeLookInRight),
        ARKitBlendShapeChannel(csvName: "EyeLookOutRight", location: .eyeLookOutRight),
        ARKitBlendShapeChannel(csvName: "EyeLookUpRight", location: .eyeLookUpRight),
        ARKitBlendShapeChannel(csvName: "EyeSquintRight", location: .eyeSquintRight),
        ARKitBlendShapeChannel(csvName: "EyeWideRight", location: .eyeWideRight),
        ARKitBlendShapeChannel(csvName: "JawForward", location: .jawForward),
        ARKitBlendShapeChannel(csvName: "JawLeft", location: .jawLeft),
        ARKitBlendShapeChannel(csvName: "JawRight", location: .jawRight),
        ARKitBlendShapeChannel(csvName: "JawOpen", location: .jawOpen),
        ARKitBlendShapeChannel(csvName: "MouthClose", location: .mouthClose),
        ARKitBlendShapeChannel(csvName: "MouthFunnel", location: .mouthFunnel),
        ARKitBlendShapeChannel(csvName: "MouthPucker", location: .mouthPucker),
        ARKitBlendShapeChannel(csvName: "MouthLeft", location: .mouthLeft),
        ARKitBlendShapeChannel(csvName: "MouthRight", location: .mouthRight),
        ARKitBlendShapeChannel(csvName: "MouthSmileLeft", location: .mouthSmileLeft),
        ARKitBlendShapeChannel(csvName: "MouthSmileRight", location: .mouthSmileRight),
        ARKitBlendShapeChannel(csvName: "MouthFrownLeft", location: .mouthFrownLeft),
        ARKitBlendShapeChannel(csvName: "MouthFrownRight", location: .mouthFrownRight),
        ARKitBlendShapeChannel(csvName: "MouthDimpleLeft", location: .mouthDimpleLeft),
        ARKitBlendShapeChannel(csvName: "MouthDimpleRight", location: .mouthDimpleRight),
        ARKitBlendShapeChannel(csvName: "MouthStretchLeft", location: .mouthStretchLeft),
        ARKitBlendShapeChannel(csvName: "MouthStretchRight", location: .mouthStretchRight),
        ARKitBlendShapeChannel(csvName: "MouthRollLower", location: .mouthRollLower),
        ARKitBlendShapeChannel(csvName: "MouthRollUpper", location: .mouthRollUpper),
        ARKitBlendShapeChannel(csvName: "MouthShrugLower", location: .mouthShrugLower),
        ARKitBlendShapeChannel(csvName: "MouthShrugUpper", location: .mouthShrugUpper),
        ARKitBlendShapeChannel(csvName: "MouthPressLeft", location: .mouthPressLeft),
        ARKitBlendShapeChannel(csvName: "MouthPressRight", location: .mouthPressRight),
        ARKitBlendShapeChannel(csvName: "MouthLowerDownLeft", location: .mouthLowerDownLeft),
        ARKitBlendShapeChannel(csvName: "MouthLowerDownRight", location: .mouthLowerDownRight),
        ARKitBlendShapeChannel(csvName: "MouthUpperUpLeft", location: .mouthUpperUpLeft),
        ARKitBlendShapeChannel(csvName: "MouthUpperUpRight", location: .mouthUpperUpRight),
        ARKitBlendShapeChannel(csvName: "BrowDownLeft", location: .browDownLeft),
        ARKitBlendShapeChannel(csvName: "BrowDownRight", location: .browDownRight),
        ARKitBlendShapeChannel(csvName: "BrowInnerUp", location: .browInnerUp),
        ARKitBlendShapeChannel(csvName: "BrowOuterUpLeft", location: .browOuterUpLeft),
        ARKitBlendShapeChannel(csvName: "BrowOuterUpRight", location: .browOuterUpRight),
        ARKitBlendShapeChannel(csvName: "CheekPuff", location: .cheekPuff),
        ARKitBlendShapeChannel(csvName: "CheekSquintLeft", location: .cheekSquintLeft),
        ARKitBlendShapeChannel(csvName: "CheekSquintRight", location: .cheekSquintRight),
        ARKitBlendShapeChannel(csvName: "NoseSneerLeft", location: .noseSneerLeft),
        ARKitBlendShapeChannel(csvName: "NoseSneerRight", location: .noseSneerRight),
        ARKitBlendShapeChannel(csvName: "TongueOut", location: .tongueOut)
    ]

    static let rotationChannelNames: [String] = [
        "HeadYaw", "HeadPitch", "HeadRoll",
        "LeftEyeYaw", "LeftEyePitch", "LeftEyeRoll",
        "RightEyeYaw", "RightEyePitch", "RightEyeRoll"
    ]

    static let metaHumanUpperBodyBones: [String] = [
        "pelvis", "spine_01", "spine_02", "spine_03",
        "neck_01", "head",
        "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
        "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r"
    ]
}

/// 3D Joint with normalized 2D screen coordinate + TrueDepth metric 3D coordinate (meters)
struct Joint3DMetric: Codable {
    let name: String
    let uNorm: Float
    let vNorm: Float
    let xMeters: Float
    let yMeters: Float
    let zDepthMeters: Float
    let confidence: Float
}

/// Solved Bone Rotation + Kinematic Control Law state for a single MetaHuman bone
struct BoneControlState: Codable {
    let boneName: String
    /// Euler angles [Roll, Pitch, Yaw] in degrees (UE5 MetaHuman Control Rig convention)
    let eulerDeg: [Float]
    /// Angular velocity [wx, wy, wz] in deg/s
    let angularVelocityDegS: [Float]
    /// Angular acceleration [ax, ay, az] in deg/s^2
    let angularAccelDegS2: [Float]
    /// Computed PD + Feedforward Control Law signal u(t)
    let pdControlSignalU: [Float]
}

/// Complete single-frame snapshot captured from iPhone Air Front TrueDepth + Vision Engine
struct MocapFrameRecord: Codable {
    let frameIndex: Int
    let timestampSec: Double
    let smpteTimecode: String
    let faceDetected: Bool
    let upperBodyDetected: Bool
    let headDistanceMeters: Float
    let chestDistanceMeters: Float
    let leftWristDistanceMeters: Float
    let rightWristDistanceMeters: Float
    /// 52 ARKit BlendShapes in [0, 1]
    let blendShapes: [String: Float]
    /// 9 LiveLink head & eye rotations in radians (for Live Link CSV) and degrees
    let liveLinkRotationsRad: [String: Float]
    let headEulerDeg: [Float]
    let headTranslationMeters: [Float]
    /// TrueDepth-fused 3D Upper-Body & Hand joints in physical meters
    let joints3DMeters: [String: Joint3DMetric]
    /// Solved MetaHuman Upper-Body Bone Rotations & Control Law states
    let boneControlStates: [String: BoneControlState]
}

/// Metadata for a recorded offline Take stored in Documents/Takes/
struct RecordedTakeItem: Identifiable {
    let id: String
    let folderURL: URL
    let createdAt: Date
    let frameCount: Int
    let durationSec: Double
    let hasRawDepthBin: Bool
}
