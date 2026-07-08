#!/bin/bash
#
# Headless retrieval-quality eval for the RAG pipeline — no Xcode project or
# simulator needed. Compiles the app's actual retrieval sources together with
# the shared golden-set evaluator into a macOS CLI binary and runs it.
#
#   scripts/retrieval-eval.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftData's @Model macro plugin ships with Xcode's toolchain, not the Command
# Line Tools — target Xcode when the active developer dir can't expand it.
if [[ "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

APP="CH4_AI_Banking_app/CH4_AI_Banking_app"
TESTS="CH4_AI_Banking_app/CH4_AI_Banking_appTests"
OUT="$(mktemp -d)/retrieval-eval"

xcrun swiftc -O \
  "$APP/Models/LocalDocument.swift" \
  "$APP/Models/RawDocument.swift" \
  "$APP/RagComponents/VectorMath.swift" \
  "$APP/RagComponents/BM25Search.swift" \
  "$APP/RagComponents/ContextualEmbedder.swift" \
  "$APP/RagComponents/HybridRetriever.swift" \
  "$APP/RagComponents/IngestionTools.swift" \
  "$TESTS/RetrievalEvaluator.swift" \
  scripts/retrieval-eval/main.swift \
  -o "$OUT"

exec "$OUT" "$@"
