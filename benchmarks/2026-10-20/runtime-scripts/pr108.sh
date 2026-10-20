set -euo pipefail
dotnet --list-sdks
dotnet --list-sdks | grep -q "^10.0.401 "
mkdir -p /etc/dotnet
printf '%s\n' /usr/local/share/dotnet > /etc/dotnet/install_location_arm64
