#!/usr/bin/env bash
# Live check of lab reading with your own anonymized results and your own key. The results stay in the folder you
# name; nothing is copied into the repository. Costs depend on provider and number of pages.
#
#   VETMED_EVAL_KEY=... VETMED_EVAL_MODEL=gemini-3.6-flash VETMED_EVAL_PROVIDER=gemini ./scripts/eval-labs.sh ~/Befunde-anonym
#
# In the folder: PDFs and/or photos (JPG). PDFs are rendered to page images with pdftoppm (poppler) and their text
# layer is read with pdftotext for the cross-check. Optional per result: NAME.expected.json with the correct values,
# e.g. [{"parameter":"Kreatinin","value":"1,9"}], typed by hand from the original. Results: apps/android/core/build/lab-eval.json
set -euo pipefail
: "${VETMED_EVAL_KEY:?Bitte VETMED_EVAL_KEY setzen}"
: "${VETMED_EVAL_MODEL:?Bitte VETMED_EVAL_MODEL setzen}"
source_dir="${1:?Bitte den Ordner mit den anonymisierten Befunden angeben}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
for file in "$source_dir"/*; do
  name="$(basename "${file%.*}")"
  lower="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"  # macOS ships bash 3.2 without ${var,,}
  case "$lower" in
    *.pdf)
      command -v pdftoppm >/dev/null || { echo "Für PDFs bitte poppler installieren (brew install poppler)."; exit 1; }
      pdftoppm -jpeg -jpegopt quality=85 -scale-to 2200 "$file" "$work/$name"
      for page in "$work/$name"-*.jpg; do
        target="$work/$name-$((10#$(basename "$page" .jpg | sed 's/.*-//'))).jpg"
        [ "$page" = "$target" ] || mv "$page" "$target"
      done
      pdftotext -layout "$file" "$work/$name.txt" 2>/dev/null || true ;;
    *.jpg|*.jpeg) cp "$file" "$work/$name-1.jpg" ;;
    *.expected.json) cp "$file" "$work/" ;;
  esac
done
cd "$(dirname "$0")/../apps/android"
VETMED_EVAL_LAB_DIR="$work" ./gradlew :core:test --tests 'de.tobwil.vetmed.core.LabLiveEval' --rerun -i | grep -E "^Laborbefunde:" || true
echo "Ergebnisse: $(pwd)/core/build/lab-eval.json (enthält gelesene Werte: nicht einchecken)"
