#!/bin/sh
set -eu

# Keep local hooks and CI on the same reviewed Gitleaks release. The archive is
# verified before extraction to make a compromised download fail closed.
version="8.29.1"
repo_root=$(git rev-parse --show-toplevel)
install_root="${GITLEAKS_INSTALL_DIR:-$repo_root/.cache/gitleaks/v$version}"
os=$(uname -s)
case "$os" in
  MINGW*|MSYS*|CYGWIN*) binary="$install_root/gitleaks.exe" ;;
  *) binary="$install_root/gitleaks" ;;
esac

if [ ! -x "$binary" ]; then
  arch=$(uname -m)

  case "$os:$arch" in
    Darwin:x86_64) asset="gitleaks_${version}_darwin_x64.tar.gz"; checksum="2cd739c684bf3f543f4f37774075c276e40a72bb16c4c5bb9dfd27bf4a4465a7"; archive_kind="tar" ;;
    Darwin:arm64) asset="gitleaks_${version}_darwin_arm64.tar.gz"; checksum="69836c841d7e648fb30ff4846f8c3587855c5754ed02b8510caaf6008f65d177"; archive_kind="tar" ;;
    Linux:x86_64) asset="gitleaks_${version}_linux_x64.tar.gz"; checksum="e4eb209d04e20339d77122a3bdf9cd41351255cfb27ebcb75e85325e04f88924"; archive_kind="tar" ;;
    Linux:aarch64|Linux:arm64) asset="gitleaks_${version}_linux_arm64.tar.gz"; checksum="691f826ce7c1c564c9c02d0f9025e8e70803e3816707a4be6224408a06a81eaa"; archive_kind="tar" ;;
    MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
      asset="gitleaks_${version}_windows_x64.zip"
      checksum="e4b7d556f0cddbe23d10d8fac2ab0f29f68f019091c6599ffbeaa8a4fb71ac78"
      archive_kind="zip"
      ;;
    *)
      echo "Unsupported platform for the pinned Gitleaks binary: $os $arch" >&2
      echo "Install Gitleaks v$version manually or use macOS/Linux arm64/x64 or Windows x64." >&2
      exit 1
      ;;
  esac

  command -v curl >/dev/null 2>&1 || { echo "curl is required to install Gitleaks." >&2; exit 1; }
  if [ "$archive_kind" = "tar" ]; then
    command -v tar >/dev/null 2>&1 || { echo "tar is required to install Gitleaks." >&2; exit 1; }
  else
    command -v unzip >/dev/null 2>&1 || { echo "unzip is required to install Gitleaks." >&2; exit 1; }
  fi

  mkdir -p "$install_root"
  archive=$(mktemp)
  trap 'rm -f "$archive"' EXIT HUP INT TERM
  url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/${asset}"

  echo "Installing verified Gitleaks v$version..." >&2
  curl --fail --silent --show-error --location "$url" --output "$archive"
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
  else
    echo "sha256sum or shasum is required to verify Gitleaks." >&2
    exit 1
  fi
  if [ "$actual" != "$checksum" ]; then
    echo "Gitleaks checksum verification failed." >&2
    exit 1
  fi

  if [ "$archive_kind" = "tar" ]; then
    tar -xzf "$archive" -C "$install_root" gitleaks
  else
    unzip -q "$archive" gitleaks.exe -d "$install_root"
  fi
  chmod 0755 "$binary"
fi

cd "$repo_root"
exec "$binary" "$@"
