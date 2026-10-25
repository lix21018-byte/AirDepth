import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import UIKit

/// Records synchronized RGB-D Video, 16-bit Millimeter Raw TrueDepth Binary,
/// UE5 Live Link Face CSV (52 BlendShapes), and Upper-Body 3D Control Law CSV/JSON.
final class TakeRecorder {
    private let recordQueue = DispatchQueue(label: "com.deepth.airdepthmocap.recorder", qos: .userInitiated)
    private(set) var isRecording: Bool = false
    private var currentTakeFolder: URL?
    private var startTime: Double = 0

    // AVAssetWriter for RGB-D Side-by-Side MP4
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let ciContext = CIContext()

    // Raw 16-bit millimeter TrueDepth binary file handle
    private var depthFileHandle: FileHandle?
    private var depthWidth: Int = 320
    private var depthHeight: Int = 240

    // Live Link Face CSV & Upper-Body Control Law CSV file handles
    private var liveLinkCSVHandle: FileHandle?
    private var controlLawCSVHandle: FileHandle?

    // Collected JSON frame records
    private var frameRecords: [MocapFrameRecord] = []
    private(set) var recordedFrameCount: Int = 0

    static func takesRootDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("Takes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    func startRecording(videoWidth: Int = 1280, videoHeight: Int = 720, depthW: Int = 320, depthH: Int = 240) -> URL? {
        guard !isRecording else { return currentTakeFolder }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let folderName = "Take_\(formatter.string(from: Date()))"
        let folderURL = Self.takesRootDirectory().appendingPathComponent(folderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            print("[TakeRecorder] Failed to create folder: \(error)")
            return nil
        }

        self.currentTakeFolder = folderURL
        self.depthWidth = depthW
        self.depthHeight = depthH
        self.frameRecords.removeAll()
        self.recordedFrameCount = 0
        self.startTime = CACurrentMediaTime()

        // 1. Setup AVAssetWriter for RGB-D Side-by-Side Video (rgbd_side_by_side.mp4)
        let mp4URL = folderURL.appendingPathComponent("rgbd_side_by_side.mp4")
        setupVideoWriter(at: mp4URL, width: videoWidth, height: videoHeight)

        // 2. Setup 16-bit Millimeter Raw TrueDepth Binary Stream (depth_raw_16bit_mm.bin)
        let binURL = folderURL.appendingPathComponent("depth_raw_16bit_mm.bin")
        FileManager.default.createFile(atPath: binURL.path, contents: nil)
        depthFileHandle = try? FileHandle(forWritingTo: binURL)
        writeDepthBinHeader(width: UInt16(depthW), height: UInt16(depthH))

        // 3. Setup Unreal Engine Live Link Face CSV (livelink_face_52blendshapes.csv)
        let llURL = folderURL.appendingPathComponent("livelink_face_52blendshapes.csv")
        FileManager.default.createFile(atPath: llURL.path, contents: nil)
        liveLinkCSVHandle = try? FileHandle(forWritingTo: llURL)
        writeLiveLinkCSVHeader()

        // 4. Setup Upper-Body 3D Action Control Law CSV (upper_body_control_law.csv)
        let ctrlURL = folderURL.appendingPathComponent("upper_body_control_law.csv")
        FileManager.default.createFile(atPath: ctrlURL.path, contents: nil)
        controlLawCSVHandle = try? FileHandle(forWritingTo: ctrlURL)
        writeControlLawCSVHeader()

        isRecording = true
        return folderURL
    }

    func appendFrame(
        record: MocapFrameRecord,
        rgbPixelBuffer: CVPixelBuffer,
        depthColormapImage: CGImage?,
        depthMillimetersUInt16: [UInt16]?
    ) {
        guard isRecording else { return }
        recordedFrameCount += 1

        recordQueue.async { [weak self] in
            guard let self = self, self.isRecording else { return }

            // 1. Append Frame Record
            self.frameRecords.append(record)

            // 2. Append Live Link Face CSV Row
            self.appendLiveLinkCSVRow(record: record)

            // 3. Append Upper-Body Control Law CSV Row
            self.appendControlLawCSVRow(record: record)

            // 4. Append Raw 16-bit Millimeter Depth Frame to .bin
            if let mmData = depthMillimetersUInt16, let handle = self.depthFileHandle {
                mmData.withUnsafeBufferPointer { ptr in
                    let data = Data(buffer: ptr)
                    try? handle.write(contentsOf: data)
                }
            }

            // 5. Append RGB-D Side-by-Side Frame to MP4 Video
            self.appendRGBDVideoFrame(
                rgbBuffer: rgbPixelBuffer,
                depthCGImage: depthColormapImage,
                timestampSec: record.timestampSec
            )
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isRecording else {
            completion(nil)
            return
        }
        isRecording = false

        recordQueue.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }

            // Close binary & CSV handles
            try? self.depthFileHandle?.close()
            self.depthFileHandle = nil

            try? self.liveLinkCSVHandle?.close()
            self.liveLinkCSVHandle = nil

            try? self.controlLawCSVHandle?.close()
            self.controlLawCSVHandle = nil

            // Write Full JSON Package (metahuman_full_take.json)
            if let folder = self.currentTakeFolder {
                let jsonURL = folder.appendingPathComponent("metahuman_full_take.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let jsonData = try? encoder.encode(self.frameRecords) {
                    try? jsonData.write(to: jsonURL)
                }
            }

            let folder = self.currentTakeFolder
            if let writer = self.assetWriter, writer.status == .writing {
                self.videoInput?.markAsFinished()
                writer.finishWriting {
                    DispatchQueue.main.async {
                        completion(folder)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(folder)
                }
            }
        }
    }

    // MARK: - Private Writers

    private func setupVideoWriter(at url: URL, width: Int, height: Int) {
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: attrs
            )

            if writer.canAdd(input) {
                writer.add(input)
            }
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            self.assetWriter = writer
            self.videoInput = input
            self.pixelBufferAdaptor = adaptor
        } catch {
            print("[TakeRecorder] Video writer error: \(error)")
        }
    }

    private func appendRGBDVideoFrame(rgbBuffer: CVPixelBuffer, depthCGImage: CGImage?, timestampSec: Double) {
        guard
            let writer = assetWriter,
            writer.status == .writing,
            let input = videoInput,
            input.isReadyForMoreMediaData,
            let adaptor = pixelBufferAdaptor,
            let pool = adaptor.pixelBufferPool
        else { return }

        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard let destBuffer = outBuffer else { return }

        let targetW = CVPixelBufferGetWidth(destBuffer)
        let targetH = CVPixelBufferGetHeight(destBuffer)
        let halfW = targetW / 2

        // Compose Left = RGB Camera (portrait oriented), Right = TrueDepth Colormap
        let rgbCI = CIImage(cvPixelBuffer: rgbBuffer).oriented(.right)
        let rgbExtent = rgbCI.extent
        let scaleX = CGFloat(halfW) / max(rgbExtent.width, 1)
        let scaleY = CGFloat(targetH) / max(rgbExtent.height, 1)
        let scaledRGB = rgbCI
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(x: 0, y: 0, width: halfW, height: targetH))

        var composite = scaledRGB
        if let depthCG = depthCGImage {
            let depthCI = CIImage(cgImage: depthCG)
            let dExt = depthCI.extent
            let dScaleX = CGFloat(halfW) / max(dExt.width, 1)
            let dScaleY = CGFloat(targetH) / max(dExt.height, 1)
            let scaledDepth = depthCI
                .transformed(by: CGAffineTransform(scaleX: dScaleX, y: dScaleY))
                .transformed(by: CGAffineTransform(translationX: CGFloat(halfW), y: 0))
            composite = scaledDepth.composited(over: composite)
        }

        ciContext.render(composite, to: destBuffer)
        let cmTime = CMTime(seconds: max(0, timestampSec), preferredTimescale: 600)
        adaptor.append(destBuffer, withPresentationTime: cmTime)
    }

    private func writeDepthBinHeader(width: UInt16, height: UInt16) {
        guard let handle = depthFileHandle else { return }
        // 8-byte header: "TDEP" (4B) + width (uint16) + height (uint16)
        var magic: [UInt8] = [0x54, 0x44, 0x45, 0x50] // "TDEP"
        var w = width.littleEndian
        var h = height.littleEndian
        var headerData = Data(bytes: &magic, count: 4)
        headerData.append(Data(bytes: &w, count: 2))
        headerData.append(Data(bytes: &h, count: 2))
        try? handle.write(contentsOf: headerData)
    }

    private func writeLiveLinkCSVHeader() {
        guard let handle = liveLinkCSVHandle else { return }
        var cols = ["Timecode", "BlendShapeCount"]
        cols.append(contentsOf: ARKitConstants.all52Channels.map { $0.csvName })
        cols.append(contentsOf: ARKitConstants.rotationChannelNames)
        let line = cols.joined(separator: ",") + "\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func appendLiveLinkCSVRow(record: MocapFrameRecord) {
        guard let handle = liveLinkCSVHandle else { return }
        var fields: [String] = [
            record.smpteTimecode,
            "61"
        ]
        for ch in ARKitConstants.all52Channels {
            let v = record.blendShapes[ch.csvName] ?? 0.0
            fields.append(String(format: "%.6f", v))
        }
        for rName in ARKitConstants.rotationChannelNames {
            let r = record.liveLinkRotationsRad[rName] ?? 0.0
            fields.append(String(format: "%.6f", r))
        }
        let line = fields.joined(separator: ",") + "\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func writeControlLawCSVHeader() {
        guard let handle = controlLawCSVHandle else { return }
        var cols = [
            "Frame", "Timestamp_s",
            "Head_Z_m", "Chest_Z_m", "LeftWrist_Z_m", "RightWrist_Z_m"
        ]
        for bone in ARKitConstants.metaHumanUpperBodyBones {
            cols.append(contentsOf: [
                "\(bone)_Roll_deg", "\(bone)_Pitch_deg", "\(bone)_Yaw_deg",
                "\(bone)_OmegaX_deg_s", "\(bone)_OmegaY_deg_s", "\(bone)_OmegaZ_deg_s",
                "\(bone)_CtrlU_X", "\(bone)_CtrlU_Y", "\(bone)_CtrlU_Z"
            ])
        }
        let line = cols.joined(separator: ",") + "\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func appendControlLawCSVRow(record: MocapFrameRecord) {
        guard let handle = controlLawCSVHandle else { return }
        var fields: [String] = [
            "\(record.frameIndex)",
            String(format: "%.5f", record.timestampSec),
            String(format: "%.4f", record.headDistanceMeters),
            String(format: "%.4f", record.chestDistanceMeters),
            String(format: "%.4f", record.leftWristDistanceMeters),
            String(format: "%.4f", record.rightWristDistanceMeters)
        ]
        for bone in ARKitConstants.metaHumanUpperBodyBones {
            if let st = record.boneControlStates[bone] {
                fields.append(contentsOf: [
                    String(format: "%.3f", st.eulerDeg[0]),
                    String(format: "%.3f", st.eulerDeg[1]),
                    String(format: "%.3f", st.eulerDeg[2]),
                    String(format: "%.2f", st.angularVelocityDegS[0]),
                    String(format: "%.2f", st.angularVelocityDegS[1]),
                    String(format: "%.2f", st.angularVelocityDegS[2]),
                    String(format: "%.2f", st.pdControlSignalU[0]),
                    String(format: "%.2f", st.pdControlSignalU[1]),
                    String(format: "%.2f", st.pdControlSignalU[2])
                ])
            } else {
                fields.append(contentsOf: ["0", "0", "0", "0", "0", "0", "0", "0", "0"])
            }
        }
        let line = fields.joined(separator: ",") + "\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
