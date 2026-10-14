"""Export the demo's MSMT17 OSNet-AIN x1.0 checkpoint to dynamic-batch ONNX.

Install torch==2.6.0 (CPU), numpy==2.2.3, onnx==1.17.0 and
onnxruntime==1.20.1 in an isolated Python environment before running.
"""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import urllib.request

import numpy as np
import onnx
import onnxruntime as ort
import torch


ARCHITECTURE_REVISION = "f8cd150fdf77e8d9e1ed143b7f308c2c609ded50"
ARCHITECTURE_SHA256 = "a43b495866a4b1645cd134a30c3011592e8c6826ba4781955a135588cf46cd25"
CHECKPOINT_REVISION = "a5c5cc037c24235cda3b21085b93ad77c9616224"
CHECKPOINT_SHA256 = "8a07e8da38946f7cee37f4561617bf8b6d2fe8f3a4027852893ea092e46d919f"
CHECKPOINT_NAME = (
    "osnet_ain_x1_0_msmt17_256x128_amsgrad_ep50_lr0.0015_coslr_b64_fb10_"
    "softmax_labsmth_flip_jitter.pth"
)


def fetch(url: str, path: Path, sha256: str) -> None:
    if not path.exists():
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != sha256:
            raise ValueError(f"Checksum mismatch for {path.name}")
        path.write_bytes(data)
    if hashlib.sha256(path.read_bytes()).hexdigest() != sha256:
        raise ValueError(f"Checksum mismatch for {path.name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    directory = parser.parse_args().output_dir
    directory.mkdir(parents=True, exist_ok=True)
    architecture = directory / "osnet_ain.py"
    checkpoint = directory / "osnet_ain_x1_0_msmt17.pth"
    fetch(
        "https://raw.githubusercontent.com/KaiyangZhou/deep-person-reid/"
        f"{ARCHITECTURE_REVISION}/torchreid/models/osnet_ain.py",
        architecture,
        ARCHITECTURE_SHA256,
    )
    fetch(
        "https://huggingface.co/kaiyangzhou/osnet/resolve/"
        f"{CHECKPOINT_REVISION}/{CHECKPOINT_NAME}",
        checkpoint,
        CHECKPOINT_SHA256,
    )
    spec = importlib.util.spec_from_file_location("osnet_ain", architecture)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    torch.set_num_threads(2)
    torch.manual_seed(42)
    model = module.osnet_ain_x1_0(num_classes=1000, pretrained=False)
    state = torch.load(checkpoint, map_location="cpu", weights_only=True)
    if "state_dict" in state:
        state = state["state_dict"]
    state = {key.removeprefix("module."): value for key, value in state.items()}
    state = {key: value for key, value in state.items() if not key.startswith("classifier.")}
    missing, unexpected = model.load_state_dict(state, strict=False)
    if unexpected or any(not key.startswith("classifier.") for key in missing):
        raise ValueError(f"Backbone mismatch: {missing}, {unexpected}")
    model.eval().requires_grad_(False)
    output = directory / "osnet_ain_x1_0_msmt17.onnx"
    torch.onnx.export(
        model,
        torch.randn(1, 3, 256, 128),
        output,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
        opset_version=17,
        # Preserve checkpoint tensors; host-side folding changes file checksums.
        do_constant_folding=False,
        dynamo=False,
    )
    onnx.checker.check_model(onnx.load(output))
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    session = ort.InferenceSession(str(output), options, providers=["CPUExecutionProvider"])
    max_error = 0.0
    for count in (1, 3, 16, 17):
        sample = torch.randn(count, 3, 256, 128)
        with torch.no_grad():
            expected = model(sample).numpy()
        actual = session.run(None, {"input": sample.numpy()})[0]
        if actual.shape != (count, 512) or not np.isfinite(actual).all():
            raise ValueError(f"Invalid output for batch {count}")
        error = float(np.abs(actual - expected).max())
        if error > 1e-4:
            raise ValueError(f"PyTorch/ONNX parity failed: {error}")
        max_error = max(max_error, error)
    manifest = {
        "model": "osnet-ain-x1.0-msmt17-v1",
        "file": output.name,
        "size": output.stat().st_size,
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "architectureRevision": ARCHITECTURE_REVISION,
        "checkpointRevision": CHECKPOINT_REVISION,
        "checkpointSHA256": CHECKPOINT_SHA256,
        "maxParityError": max_error,
    }
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
