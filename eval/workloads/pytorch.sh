#!/bin/bash
# eval/workloads/pytorch.sh — PyTorch ResNet-18 inference workload for benchmarks
# Sourced by bench.sh. Implements the standard workload interface.

_PT_SCRIPT="$SCRIPT_DIR/workloads/pytorch_infer.py"
_PT_PID=""
_PT_WORK_DIR=""
_PT_READY_FILE=""
_PT_TRIGGER_FILE=""
_PT_RESULT_FILE=""

workload_name() {
    echo "pytorch"
}

workload_setup() {
    if ! python3 -c "import torch; import torchvision" 2>/dev/null; then
        log_error "torch/torchvision not installed (pip install torch torchvision)"
        return 1
    fi
    if [ ! -f "$_PT_SCRIPT" ]; then
        log_error "pytorch_infer.py not found at $_PT_SCRIPT"
        return 1
    fi
    return 0
}

workload_start() {
    local work_dir="$1"
    _PT_WORK_DIR="$work_dir"
    _PT_READY_FILE="$work_dir/pt_ready"
    _PT_TRIGGER_FILE="$work_dir/pt_trigger"
    _PT_RESULT_FILE="$work_dir/pt_result"

    rm -f "$_PT_READY_FILE" "$_PT_TRIGGER_FILE" "$_PT_RESULT_FILE"

    setsid python3 "$_PT_SCRIPT" \
        --ready-file "$_PT_READY_FILE" \
        --trigger-file "$_PT_TRIGGER_FILE" \
        --result-file "$_PT_RESULT_FILE" \
        > "$work_dir/workload.log" 2>&1 &
    _PT_PID=$!
    track_pid "$_PT_PID"
    WORKLOAD_PID="$_PT_PID"
}

workload_warmup() {
    # Wait for the ready file (model loaded + warm inference done)
    wait_for_file "$_PT_READY_FILE" 60
}

workload_profile() {
    local work_dir="$1"
    HOT_PAGES_FILE="$work_dir/hot_pages.bin"
    # Touch trigger to make the model do inference during profiling
    touch "$_PT_TRIGGER_FILE"
    sleep 1
    rm -f "$_PT_TRIGGER_FILE"

    python3 "$HOT_PAGES" --pid "$WORKLOAD_PID" --output "$HOT_PAGES_FILE" \
        --samples 3 --interval 1
}

workload_ttfr_probe() {
    local work_dir="$1"
    # TTFR = time from RESTORE_T_START until inference result appears after trigger
    rm -f "$_PT_RESULT_FILE" "$_PT_TRIGGER_FILE"

    # Send trigger
    touch "$_PT_TRIGGER_FILE"

    local deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -s "$_PT_RESULT_FILE" ]; then
            TTFR_MS=$(( $(time_ms) - RESTORE_T_START ))
            return 0
        fi
        sleep 0.01
    done
    log_error "TTFR probe timed out for PyTorch"
    TTFR_MS=-1
    return 1
}

workload_throughput() {
    # Run batch inference — 50 forward passes
    local batch_trigger="$_PT_WORK_DIR/pt_trigger_batch"
    local batch_result="$_PT_WORK_DIR/pt_result_batch"
    local batch_script="$_PT_WORK_DIR/pt_batch.py"

    # We can't reuse the checkpointed process for batch (it's single-shot trigger).
    # Instead, run a fresh inference batch and measure.
    rm -f "$batch_result"
    python3 -c "
import torch, torchvision.models as models, time
model = models.resnet18(weights=None)
model.eval()
x = torch.randn(1, 3, 224, 224)
N = 50
t0 = time.time()
for _ in range(N):
    with torch.no_grad():
        model(x)
elapsed = time.time() - t0
ops = int(N / elapsed) if elapsed > 0 else 0
with open('$batch_result', 'w') as f:
    f.write(str(ops))
" 2>/dev/null

    if [ -f "$batch_result" ]; then
        THROUGHPUT=$(cat "$batch_result" 2>/dev/null || echo "0")
    else
        THROUGHPUT=0
    fi
}

workload_cleanup() {
    if [ -n "$_PT_PID" ]; then
        kill "$_PT_PID" 2>/dev/null || true
        _PT_PID=""
    fi
}
