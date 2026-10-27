#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
dependency_tree="$(cargo tree \
  --locked \
  --manifest-path "$repo_root/crates/yanyu-core/Cargo.toml" \
  --all-features \
  --target all \
  --edges normal,build \
  --prefix none \
  --format '{p}')"

tauri_packages="$(printf '%s\n' "$dependency_tree" | grep -E '^(tauri|tauri-[^ ]+) v' || true)"
if [[ -n "$tauri_packages" ]]; then
  printf 'yanyu-core must not depend on Tauri:\n%s\n' "$tauri_packages" >&2
  exit 1
fi

network_client_packages="$(printf '%s\n' "$dependency_tree" | grep -E '^(reqwest|hyper|hyper-util|ureq|curl|curl-sys|isahc|surf|awc|attohttpc|tungstenite|tokio-tungstenite) v' || true)"
if [[ -n "$network_client_packages" ]]; then
  printf 'yanyu-core must not depend on outbound HTTP or WebSocket clients:\n%s\n' "$network_client_packages" >&2
  exit 1
fi

raw_network_api_references="$(find "$repo_root/crates/yanyu-core/src" -type f -name '*.rs' -exec grep -nHE 'std::net::|tokio::net::|TcpStream|TcpListener|UdpSocket' {} + || true)"
if [[ -n "$raw_network_api_references" ]]; then
  printf 'yanyu-core must not open network sockets directly:\n%s\n' "$raw_network_api_references" >&2
  exit 1
fi

printf 'yanyu-core has no Tauri runtime, network-client dependencies, or direct socket APIs across enabled features and targets.\n'
