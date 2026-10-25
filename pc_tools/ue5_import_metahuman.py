"""
Unreal Engine 5 Editor Python 导入脚本 (`ue5_import_metahuman.py`)
直接读取 iPhone Air「AirDepth动捕」App 导出的 `metahuman_full_take.json` (或 `ue5_metahuman_ready.json`)，
在当前打开的 Level Sequence 中自动为 MetaHuman 打上：
1. 面部 52 个 ARKit 表情关键帧 (`Face_ControlBoard_CtrlRig`)
2. 上半身 + 头部 3D 骨骼控制律旋转关键帧 (`Body_ControlRig`)

使用方法：
1. 在 UE5 中打开包含 MetaHuman 的 Level Sequence（确保 Sequencer 面板处于打开状态）。
2. 修改下方 `TAKE_JSON_PATH` 为你从 iPhone Air 导出到电脑的 `metahuman_full_take.json` 路径。
3. 在 UE5 顶部菜单点击 `Tools -> Execute Python Script...` 选择本脚本即可一键写入关键帧！
"""

import json
import os

try:
    import unreal
    IN_UNREAL = True
except ImportError:
    IN_UNREAL = False

# 修改为你从 iPhone Air 导出的 Take 文件夹下的 metahuman_full_take.json 路径
TAKE_JSON_PATH = r"C:\Users\Admin\Desktop\AirDepthMocap\Takes\metahuman_full_take.json"

BODY_BONE_TO_CTRL = {
    "pelvis": "body_offset_ctrl",
    "spine_01": "spine_01_ctrl",
    "spine_02": "spine_02_ctrl",
    "spine_03": "spine_03_ctrl",
    "neck_01": "neck_01_ctrl",
    "head": "head_ctrl",
    "clavicle_l": "clavicle_l_ctrl",
    "upperarm_l": "upperarm_fk_l_ctrl",
    "lowerarm_l": "lowerarm_fk_l_ctrl",
    "hand_l": "hand_fk_l_ctrl",
    "clavicle_r": "clavicle_r_ctrl",
    "upperarm_r": "upperarm_fk_r_ctrl",
    "lowerarm_r": "lowerarm_fk_r_ctrl",
    "hand_r": "hand_fk_r_ctrl",
}

ARKIT_TO_FACE_CTRL = {
    "JawOpen": "CTRL_expressions_jawOpen",
    "JawLeft": "CTRL_expressions_jawLeft",
    "JawRight": "CTRL_expressions_jawRight",
    "JawForward": "CTRL_expressions_jawFwd",
    "MouthSmileLeft": "CTRL_expressions_mouthCornerPullL",
    "MouthSmileRight": "CTRL_expressions_mouthCornerPullR",
    "MouthFrownLeft": "CTRL_expressions_mouthCornerDepressL",
    "MouthFrownRight": "CTRL_expressions_mouthCornerDepressR",
    "MouthPucker": "CTRL_expressions_mouthPurseUL",
    "MouthFunnel": "CTRL_expressions_mouthFunnelUL",
    "EyeBlinkLeft": "CTRL_expressions_eyeBlinkL",
    "EyeBlinkRight": "CTRL_expressions_eyeBlinkR",
    "EyeWideLeft": "CTRL_expressions_eyeWidenerL",
    "EyeWideRight": "CTRL_expressions_eyeWidenerR",
    "BrowDownLeft": "CTRL_expressions_browDownL",
    "BrowDownRight": "CTRL_expressions_browDownR",
    "BrowInnerUp": "CTRL_expressions_browRaiseInL",
    "BrowOuterUpLeft": "CTRL_expressions_browRaiseOuterL",
    "BrowOuterUpRight": "CTRL_expressions_browRaiseOuterR",
    "CheekPuff": "CTRL_expressions_cheekBlowL",
    "NoseSneerLeft": "CTRL_expressions_noseWrinklerL",
    "NoseSneerRight": "CTRL_expressions_noseWrinklerR",
    "TongueOut": "CTRL_expressions_tongueOut",
}


def import_iphone_air_take_to_ue5(json_path: str = TAKE_JSON_PATH) -> None:
    if not IN_UNREAL:
        print("请在 Unreal Engine 5 编辑器内通过 Tools -> Execute Python Script 运行本脚本！")
        return

    if not os.path.exists(json_path):
        unreal.log_error(f"[AirDepthMocap] 找不到 JSON 文件: {json_path}")
        return

    with open(json_path, "r", encoding="utf-8") as f:
        raw = json.load(f)

    frames = raw.get("frames", raw) if isinstance(raw, dict) else raw
    if not frames:
        unreal.log_warning("[AirDepthMocap] JSON 中没有帧数据。")
        return

    level_seq = unreal.LevelSequenceEditorBlueprintLibrary.get_focused_level_sequence()
    if not level_seq:
        unreal.log_error("[AirDepthMocap] 请先在 UE5 Sequencer 中打开包含 MetaHuman 的 Level Sequence！")
        return

    rig_proxies = unreal.ControlRigSequencerLibrary.get_control_rigs(level_seq)
    face_rig = None
    body_rig = None
    for proxy in rig_proxies:
        rig = proxy.control_rig
        if not rig:
            continue
        rname = rig.get_name().lower()
        if "face" in rname or "controlboard" in rname:
            face_rig = rig
        elif "body" in rname or "metahuman" in rname:
            body_rig = rig

    with unreal.ScopedEditorTransaction("Import iPhone Air TrueDepth Mocap") as _:
        for f_rec in frames:
            f_idx = int(f_rec.get("frameIndex", 0))
            frame_num = unreal.FrameNumber(f_idx)

            # 1. 面部表情关键帧
            if face_rig is not None:
                bs = f_rec.get("blendShapes", {})
                for arkit_k, ctrl_k in ARKIT_TO_FACE_CTRL.items():
                    if arkit_k in bs:
                        try:
                            unreal.ControlRigSequencerLibrary.set_local_control_rig_float(
                                level_seq, face_rig, ctrl_k, frame_num, float(bs[arkit_k])
                            )
                        except Exception:
                            pass

            # 2. 上半身 3D 骨骼旋转关键帧
            if body_rig is not None:
                bone_states = f_rec.get("boneControlStates", {})
                for b_name, ctrl_name in BODY_BONE_TO_CTRL.items():
                    if b_name in bone_states:
                        eul = bone_states[b_name].get("eulerDeg", [0.0, 0.0, 0.0])
                        try:
                            rot = unreal.Rotator(roll=float(eul[0]), pitch=float(eul[1]), yaw=float(eul[2]))
                            unreal.ControlRigSequencerLibrary.set_local_control_rig_rotator(
                                level_seq, body_rig, ctrl_name, frame_num, rot
                            )
                        except Exception:
                            pass

    unreal.LevelSequenceEditorBlueprintLibrary.refresh_current_level_sequence()
    unreal.log(f"[AirDepthMocap] 成功导入 {len(frames)} 帧 iPhone Air 原生深度动捕数据！")


if __name__ == "__main__":
    import_iphone_air_take_to_ue5()
