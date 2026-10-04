#!/bin/sh
# Package a portable zenz-server build (cmake -DZENZ_PORTABLE=ON) as a release
# archive with its license notices.
#
# usage: scripts/dist.sh BUILD_DIR OUT_DIR
#
# Writes OUT_DIR/zenz-server-vVERSION-linux-ARCH.tar.gz and a sha256sum-style
# .sha256 file next to it. The archive holds zenz-server, LICENSE, and
# THIRD-PARTY-NOTICES at its top level.
set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 BUILD_DIR OUT_DIR" >&2
    exit 2
fi
build_dir=$1
out_dir=$2
root=$(cd "$(dirname "$0")/.." && pwd)
llama=$root/third_party/llama.cpp
server=$build_dir/zenz-server

version=$("$server" --version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
if [ -z "$version" ]; then
    echo "error: $server --version did not report a version" >&2
    exit 1
fi
case $(uname -m) in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

# A portable binary needs only the C library at run time.
needed=$(objdump -p "$server" | awk '$1 == "NEEDED" { print $2 }')
for lib in $needed; do
    case $lib in
        libc.so.* | libm.so.* | libdl.so.* | libpthread.so.* | librt.so.* | ld-linux*) ;;
        *) echo "error: $server needs $lib; build with -DZENZ_PORTABLE=ON" >&2; exit 1 ;;
    esac
done

name=zenz-server-v$version-linux-$arch
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

cp "$server" "$stage/zenz-server"
strip "$stage/zenz-server"
cp "$root/LICENSE" "$stage/LICENSE"

# Every MIT notice for code compiled into zenz-server.
notice() {
    printf '%s\n%s\n\n' "$1" "------------------------------------------------------------"
    cat
    printf '\n\n'
}
{
    notice "llama.cpp and ggml (https://github.com/azooKey/llama.cpp)" <"$llama/LICENSE"
    notice "JSON for Modern C++ (https://github.com/nlohmann/json)" \
        <"$llama/licenses/LICENSE-jsonhpp"
    # The notice is the leading comment block of sgemm.cpp.
    sed -n '/^$/q; s|^// \{0,1\}||p' "$llama/ggml/src/ggml-cpu/llamafile/sgemm.cpp" |
        notice "llamafile sgemm (https://github.com/Mozilla-Ocho/llamafile)"
    # ggml-cpu/ops.cpp cites this MIT code without the full text.
    sed -e 's/^Copyright .*/Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng/' \
        "$llama/LICENSE" |
        notice "YaRN (https://github.com/jquesnelle/yarn)"
} >"$stage/THIRD-PARTY-NOTICES"

mkdir -p "$out_dir"
tar -czf "$out_dir/$name.tar.gz" --owner=0 --group=0 --numeric-owner -C "$stage" zenz-server LICENSE THIRD-PARTY-NOTICES
(cd "$out_dir" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
echo "$out_dir/$name.tar.gz"
