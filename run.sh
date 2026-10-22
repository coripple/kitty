#!/usr/bin/env bash
# Build (if needed) and launch ditty.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$ROOT/kitty/launcher/ditty"
PYHOME_FILE="$ROOT/build/ditty-python-home"
LOG="${TMPDIR:-/tmp}/ditty-run.log"

FOREGROUND=0
FORCE_BUILD=0
NO_BUILD=0
PASSTHROUGH=()

usage() {
    cat <<EOF
用法: ./run.sh [选项] [ditty 参数...]

选项:
  -f, --foreground   在前台运行，日志直接输出到终端
  -b, --build        强制重新构建
  -B, --no-build     不检查、不构建，直接运行现有程序
  -h, --help         显示帮助

示例:
  ./run.sh
  ./run.sh --foreground
  ./run.sh --build -o font_size=14
  ./run.sh -- --title "my ditty"
EOF
}

while (($#)); do
    case "$1" in
        -f|--foreground) FOREGROUND=1; shift ;;
        -b|--build) FORCE_BUILD=1; shift ;;
        -B|--no-build) NO_BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; PASSTHROUGH+=("$@"); break ;;
        *) PASSTHROUGH+=("$1"); shift ;;
    esac
done

die() { echo "错误: $*" >&2; exit 1; }

find_python() {
    if [[ -n "${DITTY_PYTHON:-}" ]]; then
        [[ -x "$DITTY_PYTHON" ]] || die "DITTY_PYTHON 不可执行: $DITTY_PYTHON"
        echo "$DITTY_PYTHON"
        return
    fi
    # Prefer 3.13 because that is the ABI of the compiled extension in this tree.
    for c in python3.13 python3.14 python3.12 python3; do
        local p
        p="$(command -v "$c" 2>/dev/null || true)"
        [[ -n "$p" ]] || continue
        if "$p" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 12) else 1)' 2>/dev/null; then
            echo "$p"
            return
        fi
    done
    if command -v uv >/dev/null 2>&1; then
        local p
        p="$(uv python find 3.13 2>/dev/null || true)"
        if [[ -n "$p" && -x "$p" ]]; then
            echo "$p"
            return
        fi
        echo "未找到 Python 3.13，正在通过 uv 安装..." >&2
        uv python install 3.13 >/dev/null
        p="$(uv python find 3.13)"
        echo "$p"
        return
    fi
    return 1
}

find_slangc() {
    if [[ -n "${SLANGC:-}" && -x "${SLANGC}" ]]; then echo "$SLANGC"; return; fi
    if command -v slangc >/dev/null 2>&1; then command -v slangc; return; fi
    for p in \
        "$ROOT/dependencies/bin/slangc" \
        "$ROOT/../dependencies/bin/slangc" \
        "/tmp/slang/bin/slangc" \
        "$HOME/.local/bin/slangc"; do
        if [[ -x "$p" ]]; then echo "$p"; return; fi
    done
    return 1
}

needs_build=0
if [[ "$NO_BUILD" == 1 ]]; then
    needs_build=0
elif [[ "$FORCE_BUILD" == 1 || ! -x "$LAUNCHER" ]]; then
    needs_build=1
elif find "$ROOT/kitty" "$ROOT/glfw" "$ROOT/gen" "$ROOT/setup.py" -type f \
        \( -name '*.py' -o -name '*.c' -o -name '*.h' -o -name '*.m' \) \
        -newer "$LAUNCHER" -print -quit 2>/dev/null | grep -q .; then
    needs_build=1
fi

PYHOME=""
if [[ "$needs_build" == 1 ]]; then
    PY="$(find_python)" || die "未找到 Python >= 3.12，可设置 DITTY_PYTHON=/path/to/python3"
    PYHOME="$("$PY" -c 'import sys; print(sys.prefix)')"
    SLANGC_BIN="$(find_slangc || true)"
    [[ -n "$SLANGC_BIN" ]] || die "未找到 slangc。请设置 SLANGC=/path/to/slangc 或安装 shader-slang。"

    if [[ ! -f "$ROOT/fonts/SymbolsNerdFontMono-Regular.ttf" ]]; then
        echo "下载构建所需的 Symbols Nerd Font..."
        mkdir -p "$ROOT/fonts"
        curl -L --fail -o "$ROOT/fonts/SymbolsNerdFontMono-Regular.ttf.tmp" \
            https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf
        mv "$ROOT/fonts/SymbolsNerdFontMono-Regular.ttf.tmp" "$ROOT/fonts/SymbolsNerdFontMono-Regular.ttf"
    fi

    # 选项定义（含默认快捷键）改过后需要重新生成 kitty/options/*.py 和 to-c-generated.h。
    # 生成脚本依赖已有的 fast_data_types.so，所以首次构建时跳过。
    if [[ -f "$ROOT/kitty/fast_data_types.so" && "$ROOT/kitty/options/definition.py" -nt "$ROOT/kitty/options/types.py" ]]; then
        echo "重新生成选项代码..."
        # 上游通过 `kitty +launch` 以优化模式运行生成器（生成器里的 assert 依赖这一点），
        # 这里直接用构建用的 Python 加 -OO，避免 launcher 链接的 Python 与 PYTHONHOME 不一致。
        (cd "$ROOT" && PYTHONHOME="$PYHOME" "$PY" -OO -m gen config) \
            || echo "警告: 生成选项代码失败，默认快捷键可能未更新" >&2
    fi

    echo "构建 ditty..."
    if ! (cd "$ROOT" && PYTHONHOME="$PYHOME" SLANGC="$SLANGC_BIN" "$PY" setup.py build); then
        cat >&2 <<EOF
构建失败。
常见依赖（macOS）:
  brew install xxhash simde harfbuzz freetype fontconfig libpng
Slang 编译器可通过设置 SLANGC 指定。
EOF
        exit 1
    fi
    mkdir -p "$ROOT/build"
    printf '%s\n' "$PYHOME" >"$PYHOME_FILE"
elif [[ "$NO_BUILD" == 0 && -f "$PYHOME_FILE" ]]; then
    PYHOME="$(cat "$PYHOME_FILE")"
fi

if [[ -z "$PYHOME" ]]; then
    if [[ -n "${PYTHONHOME:-}" ]]; then
        PYHOME="$PYTHONHOME"
    else
        PY="$(find_python)" || die "未找到 Python >= 3.12，可设置 DITTY_PYTHON=/path/to/python3"
        PYHOME="$("$PY" -c 'import sys; print(sys.prefix)')"
    fi
fi

[[ -x "$LAUNCHER" ]] || die "找不到 $LAUNCHER，请去掉 --no-build 后重试"

if [[ "$FOREGROUND" == 1 ]]; then
    exec env PYTHONHOME="$PYHOME" "$LAUNCHER" "${PASSTHROUGH[@]}"
fi

nohup env PYTHONHOME="$PYHOME" "$LAUNCHER" "${PASSTHROUGH[@]}" >"$LOG" 2>&1 &
pid=$!
sleep 1
if kill -0 "$pid" 2>/dev/null; then
    echo "ditty 已启动 (pid $pid)"
    echo "日志: $LOG"
else
    echo "ditty 启动失败:" >&2
    cat "$LOG" >&2 || true
    exit 1
fi
