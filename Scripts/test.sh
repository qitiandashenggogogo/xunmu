#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# Hydrate project inputs before the compiler records their timestamps.
python3 - <<'PYINPUTS'
from pathlib import Path
Path('Package.swift').read_bytes()
for root in ('Sources', 'Tests'):
    for path in Path(root).rglob('*'):
        if path.is_file():
            path.read_bytes()
PYINPUTS
developer_dir="$(xcode-select -p)"
framework_dir="$developer_dir/Library/Developer/Frameworks"
if [[ ! -d "$framework_dir/Testing.framework" ]]; then
  framework_dir="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi
scratch_dir="${MACEVERYTHING_TEST_SCRATCH_DIR:-$HOME/Library/Caches/MacEverything/TestBuild}"
test_args=(--disable-xctest --enable-swift-testing --scratch-path "$scratch_dir")
if [[ -d "$framework_dir/Testing.framework" ]]; then
  test_args+=(-Xswiftc -F -Xswiftc "$framework_dir" -Xlinker -F -Xlinker "$framework_dir" -Xlinker -rpath -Xlinker "$framework_dir")
fi
interop_dir="$developer_dir/Library/Developer/usr/lib"
if [[ -f "$interop_dir/lib_TestingInterop.dylib" ]]; then
  test_args+=(-Xlinker -rpath -Xlinker "$interop_dir")
fi
swift test "${test_args[@]}" "$@"
