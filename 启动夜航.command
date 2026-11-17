#!/bin/zsh
setopt NULL_GLOB

runtime_dir="${0:A:h}/夜航运行包"
cache_dir="$HOME/Library/Caches/Nightflight"
node_version=22.23.5

usable_node() {
  [[ -n "$1" && -x "$1" ]] &&
    "$1" --input-type=module -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 && !!import.meta.dirname ? 0 : 1)' >/dev/null 2>&1
}

install_node() {
  local arch checksum archive stage url
  if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]]; then
    arch=arm64
    checksum=d0c68c321161bb2c6483efea9a343010dea8e5e7f60d73c6a7eba140016d662f
  else
    arch=x64
    checksum=d68bf234a07781141dfca61ae4461c24560f70bd53223d76a41529eb02e8554e
  fi
  archive="node-v$node_version-darwin-$arch"
  url="https://nodejs.org/dist/v$node_version/$archive.tar.xz"

  (
    /bin/mkdir -p -- "$cache_dir" || exit 1
    stage="$(/usr/bin/mktemp -d "$cache_dir/node.XXXXXXXX")" || exit 1
    trap '/bin/rm -rf -- "$stage"' EXIT
    print '正在下载 Node.js，首次配置需要联网……'
    /usr/bin/curl --fail --location --retry 1 --connect-timeout 10 --max-time 600 \
      --speed-limit 1024 --speed-time 30 --progress-bar --output "$stage/node.tar.xz" "$url" || exit 1
    print -r -- "$checksum  $stage/node.tar.xz" | /usr/bin/shasum -a 256 -c - || exit 1
    /usr/bin/tar -xf "$stage/node.tar.xz" -C "$stage" "$archive/bin/node" || exit 1
    usable_node "$stage/$archive/bin/node" || exit 1
    /bin/mv -f -- "$stage/$archive/bin/node" "$cache_dir/node"
  )
}

start_nightflight() {
  if [[ ! -r "$runtime_dir/launch.mjs" ]]; then
    print -u2 '找不到夜航运行包。请完整解压，并保留启动文件和夜航运行包的相对位置。'
    return 1
  fi

  local candidate node_bin
  for candidate in "$(command -v node)" /opt/homebrew/bin/node /usr/local/bin/node \
    "$HOME/.volta/bin/node" "$HOME"/.nvm/versions/node/*/bin/node "$cache_dir/node"; do
    if usable_node "$candidate"; then
      node_bin="$candidate"
      break
    fi
  done
  if [[ -z "$node_bin" ]]; then
    if ! install_node; then
      print -u2 'Node.js 自动配置失败。请检查网络和用户目录的写入权限后重试。'
      return 1
    fi
    node_bin="$cache_dir/node"
  fi
  NIGHTFLIGHT_CACHE="$cache_dir" "$node_bin" "$runtime_dir/launch.mjs"
}

start_nightflight
result=$?
if (( result != 0 && result != 130 )); then
  if [[ -r "$runtime_dir/夜航模拟器.html" ]]; then
    print '正在打开离线版，可使用键盘或实体手柄。'
    /usr/bin/open "$runtime_dir/夜航模拟器.html"
  fi
  [[ -t 0 ]] && read 'reply?按回车关闭终端'
fi
exit "$result"
