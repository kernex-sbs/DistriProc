#!/usr/bin/env python3
"""PyTorch ResNet-18 inference workload for DistriProc benchmarks.

Lifecycle:
  1. Load ResNet-18 model (CPU, random weights)
  2. Write ready file to signal warmup complete
  3. Wait for trigger file to appear
  4. Run inference, write result to result file
  5. If --batch mode, loop N times and report throughput

Usage:
    python3 pytorch_infer.py --ready-file /tmp/ready --trigger-file /tmp/trigger \
        --result-file /tmp/result [--batch N]
"""

import argparse
import os
import signal
import sys
import time


def main():
    parser = argparse.ArgumentParser(description="PyTorch ResNet-18 inference workload")
    parser.add_argument("--ready-file", required=True, help="File written when model is loaded")
    parser.add_argument("--trigger-file", required=True, help="File to watch for inference trigger")
    parser.add_argument("--result-file", required=True, help="File to write inference result")
    parser.add_argument("--batch", type=int, default=0,
                        help="If > 0, run N inferences after trigger and report throughput")
    args = parser.parse_args()

    # Graceful shutdown
    def handle_signal(signum, frame):
        sys.exit(0)
    signal.signal(signal.SIGTERM, handle_signal)

    # Import torch here so checkpoint captures it in memory
    import torch
    import torchvision.models as models

    # Load model
    model = models.resnet18(weights=None)
    model.eval()

    # Create a sample input tensor
    dummy_input = torch.randn(1, 3, 224, 224)

    # Warm the model with one forward pass
    with torch.no_grad():
        _ = model(dummy_input)

    # Signal ready
    with open(args.ready_file, "w") as f:
        f.write(str(os.getpid()))
    print(f"Ready (PID {os.getpid()})", flush=True)

    # Wait for trigger
    while not os.path.exists(args.trigger_file):
        time.sleep(0.01)

    # Run inference
    if args.batch > 0:
        # Batch mode: run N inferences, measure throughput
        t_start = time.time()
        for _ in range(args.batch):
            with torch.no_grad():
                output = model(dummy_input)
        elapsed = time.time() - t_start
        infer_per_sec = args.batch / elapsed if elapsed > 0 else 0

        with open(args.result_file, "w") as f:
            f.write(f"{infer_per_sec:.2f}")
        print(f"Batch done: {args.batch} inferences in {elapsed:.3f}s = {infer_per_sec:.2f} inf/s",
              flush=True)
    else:
        # Single inference
        with torch.no_grad():
            output = model(dummy_input)
        pred = output.argmax(dim=1).item()

        with open(args.result_file, "w") as f:
            f.write(str(pred))
        print(f"Inference done: class={pred}", flush=True)

    # Keep running so CRIU can checkpoint us / keep process alive
    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
