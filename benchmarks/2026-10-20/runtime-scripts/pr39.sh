set -euo pipefail
archive=$(mktemp)
curl -fsSL --retry 3 https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz -o "$archive"
echo "958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f  $archive" | sha256sum -c -
mkdir -p /opt/zig-0.15.2
tar -xJf "$archive" -C /opt/zig-0.15.2 --strip-components=1
rm "$archive"
/opt/zig-0.15.2/zig version
