#!/usr/bin/env bash
set -euo pipefail

# Configuration
## general information
PROJECT=tmux
HARNESS=input-fuzzer
ENGINE=libfuzzer
REBUILD=false
## libfuzzer settings
RUNTIME=60 # 4 hours in seconds
FLAGS="\
  -max_total_time=$RUNTIME \
  -timeout=25 \
  -print_final_stats=1 \
  -artifact_prefix=./crashes"

# -jobs=$(nproc) \
# -workers=0

## corpus settings
ROOT=$(pwd)

# OSS Fuzz directory
OSS_FUZZ_DIR=$ROOT/forks/oss-fuzz

# ---- reset to default build.sh file ----
# FIXME: Uncomment for final submission
# git reset --hard HEAD

# 1) Build OSS-Fuzz image and fuzzers with coverage instrumentation
cd "$OSS_FUZZ_DIR"
if [ "$REBUILD" = true ]; then
  rm -rf "$OSS_FUZZ_DIR/build" || true
  python3 infra/helper.py build_image "$PROJECT" --pull
  python3 infra/helper.py build_fuzzers --sanitizer coverage "$PROJECT"
fi

# 2) Ensure crashes directory exists
CORPUS_RELPATH="build/work/$PROJECT/fuzzing_corpus"
CORPUS_DIR="$OSS_FUZZ_DIR/$CORPUS_RELPATH"
mkdir -p "$CORPUS_DIR"
mkdir -p "$CORPUS_DIR/crashes"

# 3) Run the fuzzer for RUNTIME
cd "$OSS_FUZZ_DIR"
python3 infra/helper.py run_fuzzer \
  --engine "$ENGINE" "$PROJECT" \
  --corpus-dir "$CORPUS_RELPATH" \
  "$HARNESS" -- "$FLAGS"

# --- wait until all docker containers are stopped ---
for i in {1..60}; do
  sleep 1
  # if no containers are running, break the loop
  if [[ -z "$(docker ps -q)" ]]; then
    break
  fi
  echo "Waiting for containers to stop... ($i seconds elapsed)"
done

# 4) Zip and store the corpus in `experiments/{timestamp}_w_corpus`
ts=$(date +%Y%m%d_%H%M%S)
mkdir -p "$ROOT/experiments"
cp -r "$CORPUS_DIR" "$ROOT/experiments/${ts}_w_corpus"
(cd "$ROOT/experiments" && zip -qr "${ts}_w_corpus.zip" "${ts}_w_corpus")

# 5) Generate HTML coverage report
cd "$OSS_FUZZ_DIR"
python3 infra/helper.py coverage \
  "$PROJECT" \
  --corpus-dir "$CORPUS_RELPATH" \
  --fuzz-target "$HARNESS" &

# --- wait for the coverage report to be generated ---
TIMEOUT=300 # total wait time in seconds (300s = 5 minutes)
GLOBAL_REPORT_DIR="$OSS_FUZZ_DIR/build/out/$PROJECT/report"
sleep 10
echo "Waiting for coverage report to be generated..."
for ((i = 0; i < TIMEOUT; i += 1)); do
  # if the report directory exists, break the loop
  if [[ -d "$GLOBAL_REPORT_DIR" ]]; then
    break
  fi
  echo "Waiting... ($i seconds elapsed)"
done

# 6) Stop any remaining Docker containers
docker stop "$(docker ps -q)" || true

# 7) Copy results to submission directory
DEST=$ROOT/submission/part_1/${ts}_coverage_w_corpus
mkdir -p "$DEST"
cp -r "$GLOBAL_REPORT_DIR" "$DEST/"

echo "✅ Done: coverage WITH corpus in $DEST"
