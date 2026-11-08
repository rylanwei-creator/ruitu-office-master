from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess
import os

project = Path(__file__).resolve().parent.parent
q = Path(os.environ.get("RUITU_BUILD_ROOT", str(project / ".build")))
root = q / "checkouts/mlx-swift/Source/Cmlx/mlx"
kernel = root / "mlx/backend/metal/kernels"
output = q / "metal"
output.mkdir(exist_ok=True)
# Same base kernels selected by upstream MLX kernels/CMakeLists.txt.
names = ["arg_reduce", "conv", "gemv", "layer_norm", "random", "rms_norm", "rope", "scaled_dot_product_attention", "steel/attn/kernels/steel_attention"]
# Optional fast-sync fence requires Metal 3.2/macOS 15. Upstream default is
# MLX_METAL_FAST_SYNCH=0; keep SharedEvent synchronization for macOS 14.
def compile_kernel(name):
    air = output / (name.replace("/", "_") + ".air")
    if air.exists() and air.stat().st_mtime >= (kernel / (name + ".metal")).stat().st_mtime:
        return str(air)
    subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-fmodules-cache-path=" + str(output / "modules"), "-x", "metal", "-fno-fast-math", "-Wno-c++17-extensions", "-Wno-c++20-extensions", "-mmacosx-version-min=14.0", "-I", str(root), "-c", str(kernel / (name + ".metal")), "-o", str(air)], check=True)
    print("Metal compiled", name, flush=True)
    return str(air)
files = list(ThreadPoolExecutor(max_workers=2).map(compile_kernel, names))
library = output / "mlx.metallib"
if not library.exists() or any(Path(f).stat().st_mtime > library.stat().st_mtime for f in files):
    subprocess.run(["xcrun", "-sdk", "macosx", "metallib", *files, "-o", str(library)], check=True)
print("Metal library ready", flush=True)
