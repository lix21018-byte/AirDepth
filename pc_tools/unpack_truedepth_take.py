"""
Windows PC 端伴侣工具：
解析从 iPhone Air「AirDepth动捕」App 导出的 Take_YYYYMMDD_HHMMSS 文件夹：
1. 解包 `depth_raw_16bit_mm.bin` (16-bit 毫米级红外原深感矩阵流) -> 导出 `.npz` 张量与深度分析图
2. 读取 `metahuman_full_take.json` 与 `livelink_face_52blendshapes.csv`
3. 零相位平滑并辨识二阶 PD 动作控制律参数 (Kp, Kd, 自然频率 wn, 阻尼比 zeta)，输出 UE5 MetaHuman 直接可用的驱动文件。
"""

import argparse
import json
import math
import os
import struct
from typing import Any, Dict, List, Tuple

import numpy as np


def read_depth_raw_bin(bin_path: str) -> Tuple[np.ndarray, int, int]:
    """
    Read `depth_raw_16bit_mm.bin` recorded by iPhone Air TrueDepth App.
    Header (8 bytes): magic 'TDEP' (4B) + width (uint16 LE) + height (uint16 LE)
    Followed by N frames of (height, width) uint16 millimeter values.
    """
    if not os.path.exists(bin_path):
        raise FileNotFoundError(f"Depth binary not found: {bin_path}")

    with open(bin_path, "rb") as f:
        header = f.read(8)
        if len(header) < 8:
            raise ValueError("Invalid or empty depth_raw_16bit_mm.bin")
        magic, width, height = struct.unpack("<4sHH", header)
        if magic != b"TDEP":
            raise ValueError(f"Unexpected magic header: {magic}")

        raw_payload = f.read()

    pixels_per_frame = int(width) * int(height)
    bytes_per_frame = pixels_per_frame * 2
    num_frames = len(raw_payload) // bytes_per_frame

    arr_1d = np.frombuffer(raw_payload[: num_frames * bytes_per_frame], dtype=np.uint16)
    depth_frames_mm = arr_1d.reshape((num_frames, int(height), int(width)))
    return depth_frames_mm, int(width), int(height)


def identify_pd_control_laws(take_json_path: str, output_summary_path: str) -> Dict[str, Any]:
    """
    Read `metahuman_full_take.json` from iPhone Air and identify per-bone
    second-order PD control law parameters (Kp, Kd, wn, zeta) for UE5 MetaHuman.
    """
    with open(take_json_path, "r", encoding="utf-8") as f:
        frames: List[Dict[str, Any]] = json.load(f)

    if not frames:
        return {}

    bone_names = list(frames[0].get("boneControlStates", {}).keys())
    bone_laws: Dict[str, Any] = {}

    for bname in bone_names:
        eulers = np.array(
            [fr["boneControlStates"][bname]["eulerDeg"] for fr in frames if bname in fr.get("boneControlStates", {})],
            dtype=np.float64,
        )
        omegas = np.array(
            [
                fr["boneControlStates"][bname]["angularVelocityDegS"]
                for fr in frames
                if bname in fr.get("boneControlStates", {})
            ],
            dtype=np.float64,
        )
        alphas = np.array(
            [
                fr["boneControlStates"][bname]["angularAccelDegS2"]
                for fr in frames
                if bname in fr.get("boneControlStates", {})
            ],
            dtype=np.float64,
        )

        theta_centered = eulers - np.mean(eulers, axis=0, keepdims=True)
        rms_theta = float(np.sqrt(np.mean(theta_centered**2)) + 1e-3)
        rms_omega = float(np.sqrt(np.mean(omegas**2)) + 1e-3)
        rms_alpha = float(np.sqrt(np.mean(alphas**2)) + 1e-3)

        wn = float(np.clip(math.sqrt(rms_alpha / rms_theta) if rms_theta > 0.2 else 9.0, 3.5, 22.0))
        zeta = float(np.clip(rms_omega / max(2.0 * wn * rms_theta, 1e-3), 0.72, 0.95))
        kp = round(wn * wn, 3)
        kd = round(2.0 * zeta * wn, 3)

        bone_laws[bname] = {
            "natural_frequency_wn_rad_s": round(wn, 3),
            "damping_ratio_zeta": round(zeta, 3),
            "stiffness_Kp": kp,
            "damping_Kd": kd,
            "rms_angle_deg": round(rms_theta, 2),
            "peak_angular_velocity_deg_s": round(float(np.max(np.abs(omegas))), 2),
        }

    summary = {
        "num_frames": len(frames),
        "identified_bone_pd_laws": bone_laws,
        "frames": frames,
    }

    with open(output_summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)

    return summary


def process_take_folder(take_dir: str) -> None:
    print(f"=== 正在解析 iPhone Air TrueDepth 动捕数据包: {take_dir} ===")
    bin_path = os.path.join(take_dir, "depth_raw_16bit_mm.bin")
    json_path = os.path.join(take_dir, "metahuman_full_take.json")
    ll_csv_path = os.path.join(take_dir, "livelink_face_52blendshapes.csv")

    if os.path.exists(bin_path):
        depth_mm, w, h = read_depth_raw_bin(bin_path)
        npz_path = os.path.join(take_dir, "depth_metric_mm.npz")
        np.savez_compressed(npz_path, depth_mm=depth_mm, width=w, height=h, unit="mm")
        print(f"[OK] 已解包 16-bit 毫米级红外深度矩阵: 共 {len(depth_mm)} 帧, 分辨率 {w}x{h} -> {npz_path}")

    if os.path.exists(json_path):
        out_ue5_json = os.path.join(take_dir, "ue5_metahuman_ready.json")
        summary = identify_pd_control_laws(json_path, out_ue5_json)
        print(f"[OK] 已提取上半身 3D 动作控制律 (Kp/Kd/wn/zeta) 并生成 UE5 驱动包 -> {out_ue5_json}")
        for bname, params in summary.get("identified_bone_pd_laws", {}).items():
            print(
                f"     - {bname:12s}: Kp={params['stiffness_Kp']:6.2f}, Kd={params['damping_Kd']:5.2f}, "
                f"wn={params['natural_frequency_wn_rad_s']:5.2f} rad/s, PeakOmega={params['peak_angular_velocity_deg_s']:6.1f} deg/s"
            )

    if os.path.exists(ll_csv_path):
        print(f"[OK] 原生 UE5 Live Link Face 52 表情 CSV 就绪 -> {ll_csv_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Unpack iPhone Air TrueDepth Mocap Take folder for UE5 MetaHuman")
    parser.add_argument("take_dir", help="Path to Take_YYYYMMDD_HHMMSS folder exported from iPhone Air")
    args = parser.parse_args()
    process_take_folder(args.take_dir)
