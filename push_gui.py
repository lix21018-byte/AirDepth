"""
One-Click GitHub Cloud IPA Builder Launcher (GUI + CLI)
Avoids Windows cmd.exe GBK/UTF-8 batch file encoding issues completely.
"""

import os
import subprocess
import sys
import threading
import webbrowser
import tkinter as tk
from tkinter import messagebox, scrolledtext


PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))


def run_git_push(repo_url: str, log_func) -> bool:
    repo_url = repo_url.strip()
    if not repo_url:
        log_func("[错误] 请先粘贴你的 GitHub 仓库地址！\n")
        return False

    cmds = [
        (["git", "init"], "初始化本地 Git 仓库..."),
        (["git", "branch", "-M", "main"], "设置主分支为 main..."),
        (["git", "add", "."], "添加 iOS TrueDepth 动捕源码与云编译配置..."),
        (
            ["git", "commit", "-m", "Build AirDepthMocap iOS TrueDepth App for iPhone Air"],
            "提交本地代码...",
        ),
    ]

    for cmd, desc in cmds:
        log_func(f">>> {desc}\n")
        res = subprocess.run(
            cmd,
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if res.stdout:
            log_func(res.stdout + "\n")
        if res.stderr and "nothing to commit" not in res.stderr:
            log_func(res.stderr + "\n")

    # Configure remote origin
    subprocess.run(["git", "remote", "remove", "origin"], cwd=PROJECT_DIR, capture_output=True)
    res_rem = subprocess.run(
        ["git", "remote", "add", "origin", repo_url],
        cwd=PROJECT_DIR,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if res_rem.returncode != 0:
        log_func(f"[错误] 添加远程仓库失败: {res_rem.stderr}\n")
        return False

    log_func(">>> 正在推送到 GitHub 触发 macOS + Xcode 16 云端自动编译 (可能需要弹出 GitHub 登录窗口)...\n")
    res_push = subprocess.run(
        ["git", "push", "-u", "origin", "main", "--force"],
        cwd=PROJECT_DIR,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if res_push.stdout:
        log_func(res_push.stdout + "\n")
    if res_push.stderr:
        log_func(res_push.stderr + "\n")

    if res_push.returncode == 0:
        actions_url = repo_url[:-4] + "/actions" if repo_url.endswith(".git") else repo_url.rstrip("/") + "/actions"
        log_func("\n========================================================\n")
        log_func("✅ 推送成功！云端 macOS 服务器已开始自动编译 .ipa 安装包！\n")
        log_func(f"👉 正在为你打开 GitHub Actions 页面: {actions_url}\n")
        log_func("   等待约 2~3 分钟变成绿色对勾后，点进去在底部 Artifacts 下载 AirDepthMocap_iPhoneAir_IPA 即可！\n")
        log_func("========================================================\n")
        try:
            webbrowser.open(actions_url)
        except Exception:
            pass
        return True
    else:
        log_func("\n[提示] 推送未完成，请检查网络或 GitHub 账号权限。\n")
        return False


def main():
    root = tk.Tk()
    root.title("AirDepth动捕 - 一键推送 GitHub 云端编译 iOS .ipa")
    root.geometry("680x460")
    root.configure(bg="#1e1e2e")

    title_lbl = tk.Label(
        root,
        text="iPhone Air 前置 TrueDepth 深度与动捕 App 云编译助手",
        font=("Microsoft YaHei UI", 13, "bold"),
        fg="#00f0c8",
        bg="#1e1e2e",
    )
    title_lbl.pack(pady=(14, 4))

    sub_lbl = tk.Label(
        root,
        text="步骤 1：在 GitHub 新建一个公开 (Public) 空仓库，把仓库地址粘贴到下方：",
        font=("Microsoft YaHei UI", 10),
        fg="#e0e0e0",
        bg="#1e1e2e",
    )
    sub_lbl.pack(anchor="w", padx=20, pady=(4, 4))

    url_frame = tk.Frame(root, bg="#1e1e2e")
    url_frame.pack(fill="x", padx=20)

    url_var = tk.StringVar(value="https://github.com/lix21018-byte/AirDepth.git")
    url_entry = tk.Entry(
        url_frame,
        textvariable=url_var,
        font=("Consolas", 11),
        bg="#2b2b3c",
        fg="#ffffff",
        insertbackground="#ffffff",
        relief="flat",
    )
    url_entry.pack(side="left", fill="x", expand=True, ipady=6, padx=(0, 8))

    new_repo_btn = tk.Button(
        url_frame,
        text="打开 GitHub 新建仓库",
        font=("Microsoft YaHei UI", 9),
        bg="#3b3b52",
        fg="#ffffff",
        relief="flat",
        command=lambda: webbrowser.open("https://github.com/new"),
    )
    new_repo_btn.pack(side="right", ipady=4, ipadx=8)

    log_box = scrolledtext.ScrolledText(
        root,
        font=("Consolas", 9),
        bg="#14141f",
        fg="#a6e3a1",
        height=14,
        relief="flat",
    )
    log_box.pack(fill="both", expand=True, padx=20, pady=12)
    log_box.insert(
        "end",
        "准备就绪。\n1. 点击右上角【打开 GitHub 新建仓库】创建一个空仓库（例如命名为 AirDepthMocap）\n"
        "2. 复制仓库地址 (如 https://github.com/你的用户名/AirDepthMocap.git) 粘贴到上方输入框\n"
        "3. 点击下方【一键推送并开始云端编译 .ipa】按钮\n\n",
    )

    def append_log(msg: str):
        log_box.after(0, lambda: (log_box.insert("end", msg), log_box.see("end")))

    push_btn = tk.Button(
        root,
        text="🚀 一键推送并开始云端编译 .ipa",
        font=("Microsoft YaHei UI", 11, "bold"),
        bg="#00c896",
        fg="#11111b",
        activebackground="#00e6ac",
        relief="flat",
    )

    def on_push_click():
        url = url_var.get().strip()
        if not url:
            messagebox.showwarning("提示", "请先粘贴你的 GitHub 仓库地址！")
            return
        push_btn.config(state="disabled", text="正在推送中，请稍候...")

        def worker():
            ok = run_git_push(url, append_log)
            root.after(
                0,
                lambda: push_btn.config(
                    state="normal",
                    text="✅ 推送成功 (可再次点击重新推送)" if ok else "🚀 一键推送并开始云端编译 .ipa",
                ),
            )

        threading.Thread(target=worker, daemon=True).start()

    push_btn.config(command=on_push_click)
    push_btn.pack(pady=(0, 16), ipadx=24, ipady=8)

    root.mainloop()


if __name__ == "__main__":
    main()
