#!/usr/bin/env bash
# Live check of medication answers with your own OpenAI key. Synthetic questions only; costs a few cents per run
# (plus web search fees for the "on" mode). Results: apps/android/core/build/medication-eval.json
#
#   VETMED_EVAL_OPENAI_KEY=sk-... VETMED_EVAL_MODEL=gpt-5.5 ./scripts/eval-medication.sh
#   VETMED_EVAL_MODES=off ...   # only without source search
set -euo pipefail
: "${VETMED_EVAL_OPENAI_KEY:?Bitte VETMED_EVAL_OPENAI_KEY setzen}"
: "${VETMED_EVAL_MODEL:?Bitte VETMED_EVAL_MODEL setzen, z. B. gpt-5.5}"
cd "$(dirname "$0")/../apps/android"
./gradlew :core:test --tests 'de.tobwil.vetmed.core.MedicationLiveEval' --rerun
echo "Ergebnisse: $(pwd)/core/build/medication-eval.json"
