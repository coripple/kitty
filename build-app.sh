#!/usr/bin/env bash
# 打包成可以直接双击运行的 ditty.app：
#   - 自带 Python 运行时（不依赖 PYTHONHOME、uv 或终端）
#   - 修正所有二进制对 libpython 的引用，指向 app 内部
#   - 本机 ad-hoc 签名，Apple Silicon 上可直接运行
#
# 用法:
#   ./build-app.sh              # 生成 ./ditty.app
#   ./build-app.sh --install    # 生成并安装到 /Applications/ditty.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/ditty.app"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n 2,10p "$0"; exit 0 ;;
        *) echo "未知参数: $arg" >&2; exit 2 ;;
    esac
done

die() { printf '错误: %b\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[[ "$(uname)" == Darwin ]] || die "只能在 macOS 上打包"

# --- 找到构建用的 Python（与 run.sh 相同）---------------------------------
PYHOME="${PYTHONHOME:-}"
if [[ -z "$PYHOME" && -f "$ROOT/build/ditty-python-home" ]]; then
    PYHOME="$(cat "$ROOT/build/ditty-python-home")"
fi
if [[ -n "${DITTY_PYTHON:-}" ]]; then
    PY="$DITTY_PYTHON"
    PYHOME="$("$PY" -c 'import sys; print(sys.prefix)')"
elif [[ -n "$PYHOME" ]]; then
    PY="$PYHOME/bin/python3"
else
    die "找不到构建用的 Python。请先运行一次 ./run.sh，或设置 DITTY_PYTHON=/path/to/python3"
fi
[[ -x "$PY" ]] || die "Python 不可执行: $PY"
export PYTHONHOME="$PYHOME"
PYVER="$("$PY" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
LIBPYTHON="$PYHOME/lib/libpython$PYVER.dylib"
STDLIB="$PYHOME/lib/python$PYVER"
[[ -f "$LIBPYTHON" ]] || die "找不到 ${LIBPYTHON}（需要共享库形式的 Python，例如 uv 安装的 Python）"
[[ -d "$STDLIB" ]] || die "找不到 Python 标准库: $STDLIB"

# --- slangc（与 run.sh 相同）-------------------------------------------------
find_slangc() {
    if [[ -n "${SLANGC:-}" && -x "${SLANGC}" ]]; then echo "$SLANGC"; return; fi
    if command -v slangc >/dev/null 2>&1; then command -v slangc; return; fi
    for p in "$ROOT/dependencies/bin/slangc" "$ROOT/../dependencies/bin/slangc" "/tmp/slang/bin/slangc" "$HOME/.local/bin/slangc"; do
        if [[ -x "$p" ]]; then echo "$p"; return; fi
    done
    return 1
}
SLANGC="$(find_slangc)" || die "未找到 slangc。请设置 SLANGC=/path/to/slangc"
export SLANGC

cd "$ROOT"

# --- 1. 生成选项代码（定义改动后）---------------------------------------------
if [[ -f kitty/fast_data_types.so && kitty/options/definition.py -nt kitty/options/types.py ]]; then
    step "重新生成选项代码"
    "$PY" -OO -m gen config || echo "警告: 生成选项代码失败" >&2
fi

# --- 2. 构建 app 包 -----------------------------------------------------------
step "构建 ditty.app（Python ${PYVER}）"
DITTY_SKIP_DOCS=1 "$PY" setup.py kitty.app
[[ -x "$APP/Contents/MacOS/ditty" ]] || die "构建失败：没有生成 $APP/Contents/MacOS/ditty"

# --- 3. 嵌入 Python 运行时 ----------------------------------------------------
step "嵌入 Python 运行时"
# 布局与 kitty 官方安装包一致：动态库放 Frameworks，标准库放 Resources
# （codesign 不允许 Frameworks 里放普通目录）。内嵌的 quick-access app
# 通过符号链接共用这两个目录。
PYDEST="$APP/Contents/Resources/Python"
BUNDLED_LIBPYTHON="$APP/Contents/Frameworks/libpython$PYVER.dylib"
NEW_LIBPYTHON="@executable_path/../Frameworks/libpython$PYVER.dylib"
rm -rf "$PYDEST" "$APP/Contents/Frameworks/Python"
mkdir -p "$PYDEST/lib" "$APP/Contents/Frameworks"
cp "$LIBPYTHON" "$BUNDLED_LIBPYTHON"
chmod u+w "$BUNDLED_LIBPYTHON"
install_name_tool -id "$NEW_LIBPYTHON" "$BUNDLED_LIBPYTHON"
# 标准库：去掉测试、GUI 工具、pip 和第三方包，kitty 只用标准库
rsync -a \
    --exclude 'test/' --exclude 'tests/' --exclude 'idlelib/' --exclude 'tkinter/' \
    --exclude 'turtledemo/' --exclude 'ensurepip/' --exclude 'site-packages/' \
    --exclude 'config-*/' --exclude '__pycache__/' --exclude 'lib2to3/' \
    "$STDLIB/" "$PYDEST/lib/python$PYVER/"
mkdir -p "$PYDEST/lib/python$PYVER/site-packages"

# --- 4. 让所有二进制都使用 app 内的 libpython ---------------------------------
step "修正动态库引用"
is_macho() { file -b "$1" | grep -q 'Mach-O'; }
fixed=0
while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    [[ "$f" == "$BUNDLED_LIBPYTHON" ]] && continue
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        chmod u+w "$f"
        if [[ "$dep" == @rpath/* ]]; then
            # 通过 rpath 引用：去掉指向构建机 Python 的 rpath，加一条指向 app 内部的
            while IFS= read -r rp; do
                [[ "$rp" == "$PYHOME"* ]] && install_name_tool -delete_rpath "$rp" "$f"
            done < <(otool -l "$f" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
            install_name_tool -add_rpath "@executable_path/../Frameworks" "$f" 2>/dev/null || true
        elif [[ "$dep" != "$NEW_LIBPYTHON" ]]; then
            install_name_tool -change "$dep" "$NEW_LIBPYTHON" "$f"
        fi
        fixed=$((fixed + 1))
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep "libpython$PYVER" || true)
done < <(find "$APP" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)
echo "已修正 $fixed 处引用"

# 检查是否还有指向构建机 Python 的引用
left="$(find "$APP" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -exec sh -c 'file -b "$1" | grep -q Mach-O && otool -L "$1" | grep -F "'"$PYHOME"'" && echo "  in $1"' _ {} \; || true)"
[[ -z "$left" ]] || die "仍有二进制引用构建机上的 Python:\n$left"

# --- 5. 签名 ------------------------------------------------------------------
step "签名（ad-hoc）"
sign() { codesign --force --sign - --timestamp=none "$@"; }
# 由内而外：先签所有动态库、扩展模块和辅助程序，再签内嵌的 app，最后签整个 app
QAPP="$APP/Contents/ditty-quick-access.app"
MAIN_EXE="$APP/Contents/MacOS/ditty"
n=0
while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    [[ "$f" == "$MAIN_EXE" || "$f" == "$QAPP/Contents/MacOS/"* ]] && continue
    sign "$f" >/dev/null 2>&1 || die "签名失败: $f"
    n=$((n + 1))
done < <(find "$APP/Contents" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)
echo "已签名 $n 个二进制"
if [[ -d "$QAPP" ]]; then
    sign "$QAPP" || die "签名失败: $QAPP"
fi
sign "$APP" || die "签名失败: $APP"
codesign --verify --strict --deep "$APP" || die "签名校验失败"

# --- 6. 在干净环境里自检（不带 PYTHONHOME、PATH 等）--------------------------
step "自检：在没有任何环境变量的情况下启动"
if ! env -i HOME="$HOME" "$APP/Contents/MacOS/ditty" +runpy 'import sys, kitty.constants as c; print("ok", sys.version.split()[0], c.str_version)'; then
    die "app 内的 Python 无法独立启动"
fi

du -sh "$APP" | awk '{print "大小: " $1}'

if [[ "$INSTALL" == 1 ]]; then
    step "安装到 /Applications"
    rm -rf /Applications/ditty.app
    ditto "$APP" /Applications/ditty.app
    echo "已安装: /Applications/ditty.app"
fi

cat <<EOF

完成: $APP
双击即可运行，也可以拖到“应用程序”文件夹（或用 ./build-app.sh --install）。
项目、模板和配置仍然在 ~/.config/ditty。
EOF
