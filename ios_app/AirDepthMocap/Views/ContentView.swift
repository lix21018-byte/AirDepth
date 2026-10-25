import SwiftUI

struct ContentView: View {
    @StateObject private var engine = TrueDepthMocapEngine()
    @State private var showTakesSheet = false
    @State private var splitDepthMode = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 1. Live ARKit TrueDepth Camera + 3D Face Mesh + Upper-Body Skeleton Overlay
            GeometryReader { geo in
                ZStack {
                    ARPreviewView(session: engine.arSession)
                        .ignoresSafeArea()

                    // Upper-Body 3D/2D Skeleton Overlay
                    UpperBodySkeletonOverlay(
                        joints: engine.overlayJoints2D,
                        viewSize: geo.size
                    )
                }
            }

            // 2. HUD & Controls Layer
            VStack(spacing: 10) {
                // Top Telemetry Header
                topStatusBar

                Spacer()

                // Middle-Right Live Hardware TrueDepth Colormap PiP + BlendShapes Bars
                HStack(alignment: .bottom, spacing: 10) {
                    // Live Top 52 BlendShapes Bar Panel
                    blendShapesPanel

                    Spacer()

                    // Live Hardware TrueDepth Infrared Depth Map Preview
                    if splitDepthMode, let depthCG = engine.depthPreviewCGImage {
                        VStack(spacing: 4) {
                            Text("TrueDepth 红外深度图")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            Image(decorative: depthCG, scale: 1.0, orientation: .right)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 135, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.cyan.opacity(0.8), lineWidth: 1.5)
                                )
                        }
                        .padding(6)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 12)

                // Bottom Recording Control Deck
                bottomControlDeck
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            engine.startSession()
        }
        .onDisappear {
            engine.pauseSession()
        }
        .sheet(isPresented: $showTakesSheet) {
            TakesListSheet(engine: engine)
        }
    }

    // MARK: - Subviews

    private var topStatusBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isTrueDepthSupported ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("iPhone Air TrueDepth 动捕")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                StatusBadge(title: "表情52", active: engine.faceDetected)
                StatusBadge(title: "上半身3D", active: engine.upperBodyDetected)
                Text("\(engine.currentFPS) FPS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(6)
            }

            HStack(spacing: 12) {
                Text(String(format: "头距: %.1fcm", engine.headDistanceCm))
                    .foregroundColor(distanceSweetSpotColor)
                Text(String(format: "胸距: %.1fcm", engine.chestDistanceCm))
                    .foregroundColor(.white.opacity(0.9))
                Text(String(format: "左手: %.1fcm", engine.leftHandDistanceCm))
                    .foregroundColor(.cyan)
                Text(String(format: "右手: %.1fcm", engine.rightHandDistanceCm))
                    .foregroundColor(.orange)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.72))
        .cornerRadius(12)
        .padding(.horizontal, 12)
    }

    private var distanceSweetSpotColor: Color {
        if engine.headDistanceCm >= 30 && engine.headDistanceCm <= 95 {
            return .green
        }
        return .orange
    }

    private var blendShapesPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ARKit 52 表情 & 头部 6DoF")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.green)

            Text(String(
                format: "R:%.1f° P:%.1f° Y:%.1f°",
                engine.headEulerDeg[0],
                engine.headEulerDeg[1],
                engine.headEulerDeg[2]
            ))
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))

            ForEach(engine.topBlendShapes, id: \.0) { item in
                HStack(spacing: 4) {
                    Text(String(item.0.prefix(13)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 82, alignment: .leading)

                    GeometryReader { barGeo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.18))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.cyan)
                                .frame(width: max(0, min(CGFloat(item.1) * barGeo.size.width, barGeo.size.width)))
                        }
                    }
                    .frame(width: 56, height: 6)

                    Text(String(format: "%.2f", item.1))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.cyan)
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.68))
        .cornerRadius(10)
    }

    private var bottomControlDeck: some View {
        VStack(spacing: 8) {
            if engine.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("REC \(engine.recordingTimecode) | 帧数: \(engine.recordedFramesCount)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.8))
                .cornerRadius(8)
            }

            HStack(spacing: 28) {
                // Toggle Depth PiP button
                Button(action: { splitDepthMode.toggle() }) {
                    VStack(spacing: 3) {
                        Image(systemName: splitDepthMode ? "eye.fill" : "eye.slash")
                            .font(.system(size: 20))
                        Text("深度窗")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.cyan)
                    .frame(width: 64, height: 52)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(12)
                }

                // Main Record / Stop Button
                Button(action: { engine.toggleRecording() }) {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 74, height: 74)
                        if engine.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 34, height: 34)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                        }
                    }
                }

                // Open Recorded Takes Drawer
                Button(action: {
                    engine.refreshRecordedTakes()
                    showTakesSheet = true
                }) {
                    VStack(spacing: 3) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 20))
                        Text("动作库(\(engine.recordedTakes.count))")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.yellow)
                    .frame(width: 64, height: 52)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(12)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(Color.black.opacity(0.78))
            .cornerRadius(20)
        }
    }
}

struct StatusBadge: View {
    let title: String
    let active: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(active ? .black : .white.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(active ? Color.green : Color.white.opacity(0.15))
            .cornerRadius(6)
    }
}

struct UpperBodySkeletonOverlay: View {
    let joints: [String: CGPoint]
    let viewSize: CGSize

    private let connections: [(String, String)] = [
        ("nose", "neck"),
        ("neck", "leftShoulder"),
        ("neck", "rightShoulder"),
        ("leftShoulder", "rightShoulder"),
        ("leftShoulder", "leftElbow"),
        ("leftElbow", "leftWrist"),
        ("rightShoulder", "rightElbow"),
        ("rightElbow", "rightWrist"),
        ("leftShoulder", "leftHip"),
        ("rightShoulder", "rightHip"),
        ("leftHip", "rightHip")
    ]

    var body: some View {
        Canvas { context, size in
            for (a, b) in connections {
                if let pa = joints[a], let pb = joints[b] {
                    let ptA = CGPoint(x: pa.x * size.width, y: pa.y * size.height)
                    let ptB = CGPoint(x: pb.x * size.width, y: pb.y * size.height)
                    var path = Path()
                    path.move(to: ptA)
                    path.addLine(to: ptB)
                    context.stroke(path, with: .color(.green.opacity(0.85)), lineWidth: 3)
                }
            }
            for (_, pt) in joints {
                let p = CGPoint(x: pt.x * size.width, y: pt.y * size.height)
                let rect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: rect), with: .color(.yellow))
            }
        }
        .allowsHitTesting(false)
    }
}

struct TakesListSheet: View {
    @ObservedObject var engine: TrueDepthMocapEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("导出提示：可在 iPhone「文件」App -> 我的 iPhone -> AirDepth动捕 -> Takes 查看，或点击右侧直接隔空投送/发微信/存文件到电脑")) {
                    if engine.recordedTakes.isEmpty {
                        Text("暂无录制记录，请点击主界面红色按钮开始录制。")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(engine.recordedTakes) { take in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(take.id)
                                        .font(.headline)
                                    Text("包含: RGB-D深度视频 + 16bit深度.bin + UE5 LiveLink CSV + 上半身控制律JSON/CSV")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                ShareLink(item: take.folderURL) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.title3)
                                        .foregroundColor(.cyan)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("已录制深度与动捕数据")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
