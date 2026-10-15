#!/bin/zsh
# IPRC1000 Adapter (macOS) 一键安装脚本
#
#   ./install.sh            安装到「应用程序」并检查环境
#   ./install.sh --no-blackhole   跳过 BlackHole 安装
#
# 只做三件事：①（可选）装 BlackHole 虚拟声卡 ② 把 App 复制到 /Applications ③ 跑环境自检
set -u

root=${0:A:h}
app_src="$root/IPRC1000 Adapter.app"
[[ -d "$app_src" ]] || app_src="$root/macos-app/dist/IPRC1000 Adapter.app"

echo "== IPRC1000 Adapter 安装 =="

# ① BlackHole（虚拟麦克风）
BLACKHOLE_URL="https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg"
if [[ "${1:-}" != "--no-blackhole" ]]; then
    if system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole"; then
        echo "[✓] 已检测到 BlackHole"
    elif command -v brew >/dev/null 2>&1; then
        echo "[i] 正在安装 BlackHole 2ch（需要管理员密码）…"
        brew install --cask blackhole-2ch || echo "[!] BlackHole 安装失败，可稍后手动安装"
    else
        # 没有 Homebrew：直接下官方 pkg 安装（会弹窗要密码）
        echo "[i] 未检测到 Homebrew，改用官方安装包…"
        pkg="$root/downloads/BlackHole2ch-0.7.1.pkg"
        mkdir -p "$root/downloads"
        if [[ ! -f "$pkg" ]]; then
            curl -sL --max-time 300 -o "$pkg" "$BLACKHOLE_URL" || true
        fi
        if [[ -f "$pkg" ]] && pkgutil --check-signature "$pkg" 2>/dev/null | grep -q "Existential Audio"; then
            echo "[i] 正在安装 BlackHole 2ch（会弹出窗口，请输入开机密码）…"
            osascript -e "do shell script \"/usr/sbin/installer -pkg '$pkg' -target /\" with administrator privileges" \
                || echo "[!] BlackHole 安装失败，可手动安装：$BLACKHOLE_URL"
            # 让 coreaudiod 重新加载 HAL 插件，否则系统看不到新设备
            echo "[i] 重启音频服务以加载虚拟声卡…"
            osascript -e 'do shell script "killall -9 coreaudiod" with administrator privileges' || true
            sleep 3
            system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole" \
                && echo "[✓] BlackHole 2ch 已就绪" \
                || echo "[!] 暂未识别到 BlackHole，可能需要在「音频 MIDI 设置」里确认或重启系统"
        else
            echo "[!] 安装包下载/校验失败；请手动安装：$BLACKHOLE_URL"
        fi
    fi
fi

# ② 复制 App
if [[ -d "$app_src" ]]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    LSREGISTER+="LaunchServices.framework/Support/lsregister"

    echo "[i] 清理历史遗留副本 …"
    # 早期版本把旧 App 挪到 /tmp 而不是删除，攒了一堆副本；
    # 它们**还会被系统注册**，于是 Launchpad / "打开方式"里会出现第二个 IPRC1000。
    for stale in /tmp/IPRC1000-old-*.app(N); do   # (N) = 无匹配时展开为空，不报错
        "$LSREGISTER" -u "$stale" 2>/dev/null
        rm -rf "$stale"
    done

    echo "[i] 复制到 /Applications …"
    if [[ -d "/Applications/IPRC1000 Adapter.app" ]]; then
        "$LSREGISTER" -u "/Applications/IPRC1000 Adapter.app" 2>/dev/null
        rm -rf "/Applications/IPRC1000 Adapter.app"
    fi
    cp -R "$app_src" "/Applications/IPRC1000 Adapter.app"
    # 显式校验：脚本没有 set -e，中途失败必须自己喊出来
    if [[ ! -x "/Applications/IPRC1000 Adapter.app/Contents/MacOS/IPRC1000Adapter" ]]; then
        echo "[!] 复制失败：/Applications 里没有可执行文件" >&2
        exit 1
    fi

    # ★ 关键：构建产物那份（macos-app/dist/…）必须从 LaunchServices 注销，
    #   否则它和 /Applications 里这份 bundle id 相同，系统会当成两个 App。
    "$LSREGISTER" -u "$app_src" 2>/dev/null
    # 顺便别让 Spotlight 索引构建目录
    touch "$(dirname "$app_src")/.metadata_never_index" "$(dirname "$app_src")/.noindex" 2>/dev/null

    echo "[✓] 已安装：/Applications/IPRC1000 Adapter.app"

    # ★ 装完必须把构建产物删掉：它和 /Applications 里那份 **bundle id 完全相同**，
    #   留在磁盘上就会被 Spotlight / Launchpad / 右键"打开方式"列出两个 IPRC1000。
    #   它只是构建中间产物，重新编译时 package-app.sh 会再生成。
    if [[ -d "$app_src" ]]; then
        rm -rf "$app_src"
        echo "[i] 已移除构建产物副本（避免出现两个 IPRC1000；重新编译会再生成）"
    fi

    xattr -dr com.apple.quarantine "/Applications/IPRC1000 Adapter.app" 2>/dev/null
    # 复制前注销过这个路径，装好后要重新登记一次，否则 Spotlight / "open -a" 会找不到它
    "$LSREGISTER" -f "/Applications/IPRC1000 Adapter.app" 2>/dev/null
elif [[ -d "/Applications/IPRC1000 Adapter.app" ]]; then
    # 没有构建产物但已装好 —— 直接沿用，不报错
    echo "[i] 没有构建产物，沿用已安装的 /Applications/IPRC1000 Adapter.app"
else
    echo "[!] 找不到 IPRC1000 Adapter.app（请先运行 macos-app/scripts/package-app.sh）"
    exit 1
fi

# ③ 自检
echo "[i] 运行内置自检 …"
"/Applications/IPRC1000 Adapter.app/Contents/MacOS/IPRC1000Adapter" --self-test

cat <<'EOF'

== 接下来（手动，一次即可）==
1. 配对遥控器：系统设置 → 蓝牙 → 连接 IPRC1000
2. 打开 App：open -a "IPRC1000 Adapter"
3. 授权：系统设置 → 隐私与安全性 → 打开「输入监控」和「辅助功能」
4. 语音验证（关键一步）：先按住遥控器麦克风键说话，再执行
     "/Applications/IPRC1000 Adapter.app/Contents/MacOS/IPRC1000Adapter" --voice-diag 30
5. 若语音可用：
     · 系统设置 → 声音 → 输入 → 选「BlackHole 2ch」
     · 系统设置 → 键盘 → 听写 → 打开并设自定义快捷键（如 ⌃⌥D）
     · App「按键映射」页把「麦克风」键映射为 ⌃⌥D
EOF
