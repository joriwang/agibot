#!/usr/bin/env bash
# =============================================================================
# Stage 1: Spec Sync Check
# Deterministic rule checks — fails pipeline if spec is out of sync with code.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration: source path → spec file mapping
# ---------------------------------------------------------------------------
declare -A MODULE_SPEC_MAP=(
  ["src/module/control_module"]="spec/module_control_module.md"
  ["src/module/dcu_driver_module"]="spec/module_dcu_driver_module.md"
  ["src/module/joy_stick_module"]="spec/module_joy_stick_module.md"
  ["src/module/sim_module"]="spec/module_sim_module.md"
)

PROTOCOL_SPEC_DIR="spec"
PROTOCOL_SRC_DIR="src/protocols"

# Files exempt from spec sync requirement
EXEMPT_PATTERNS=(
  "*_test.cc"
  "*_test.cpp"
  "*.md"
)

ERRORS=()
WARNINGS=()

# ---------------------------------------------------------------------------
# Helper: check if a file matches any exempt pattern
# ---------------------------------------------------------------------------
is_exempt() {
  local file="$1"
  for pattern in "${EXEMPT_PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$file" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# Get changed files in this MR
# ---------------------------------------------------------------------------
echo "=== Spec Sync Check ==="
echo ""

# Use MR diff if available, otherwise compare with main
if [ -n "${MR_TARGET_BRANCH:-}" ] && [ -n "${MR_SOURCE_BRANCH:-}" ]; then
  CHANGED_FILES=$(git diff --name-only "${MR_TARGET_BRANCH}...${MR_SOURCE_BRANCH}" 2>/dev/null || git diff --name-only origin/main...HEAD)
else
  CHANGED_FILES=$(git diff --name-only origin/main...HEAD)
fi

if [ -z "$CHANGED_FILES" ]; then
  echo "No changed files detected. Skipping checks."
  exit 0
fi

echo "Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  /'
echo ""

# ---------------------------------------------------------------------------
# Check: MR description for [spec-exempt] tag
# ---------------------------------------------------------------------------
MR_DESCRIPTION="${CI_MERGE_REQUEST_DESCRIPTION:-}"
if echo "$MR_DESCRIPTION" | grep -qi '\[spec-exempt\]'; then
  echo "[INFO] MR description contains [spec-exempt] tag. Skipping spec sync checks."
  echo "       Reason should be documented in MR description."
  exit 0
fi

# ---------------------------------------------------------------------------
# Check 1: Module code changed → corresponding spec must also change
# ---------------------------------------------------------------------------
echo "--- Check 1: Module spec sync ---"

for module_path in "${!MODULE_SPEC_MAP[@]}"; do
  spec_file="${MODULE_SPEC_MAP[$module_path]}"

  # Find changed files under this module (excluding exemptions)
  module_changes=()
  while IFS= read -r file; do
    if [[ "$file" == ${module_path}/* ]] && ! is_exempt "$file"; then
      module_changes+=("$file")
    fi
  done <<< "$CHANGED_FILES"

  if [ ${#module_changes[@]} -gt 0 ]; then
    # Check if spec file is also in changed list
    if echo "$CHANGED_FILES" | grep -q "^${spec_file}$"; then
      echo "  [PASS] ${module_path}/ changed → ${spec_file} also updated"
    else
      ERRORS+=("Module '${module_path}/' has code changes but '${spec_file}' was not updated. Changed files: ${module_changes[*]}")
      echo "  [FAIL] ${module_path}/ changed → ${spec_file} NOT updated"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Check 2: Protocol source changed → any protocol spec must change
# ---------------------------------------------------------------------------
echo ""
echo "--- Check 2: Protocol spec sync ---"

protocol_changes=()
while IFS= read -r file; do
  if [[ "$file" == ${PROTOCOL_SRC_DIR}/* ]] && ! is_exempt "$file"; then
    protocol_changes+=("$file")
  fi
done <<< "$CHANGED_FILES"

if [ ${#protocol_changes[@]} -gt 0 ]; then
  # Check if any protocol spec was updated
  if echo "$CHANGED_FILES" | grep -q "^${PROTOCOL_SPEC_DIR}/protocol_"; then
    echo "  [PASS] Protocol sources changed → protocol spec(s) also updated"
  else
    ERRORS+=("Protocol sources changed (${protocol_changes[*]}) but no protocol spec (spec/protocol_*.md) was updated.")
    echo "  [FAIL] Protocol sources changed → NO protocol spec updated"
  fi
else
  echo "  [SKIP] No protocol source changes"
fi

# ---------------------------------------------------------------------------
# Check 3: Spec version field updated when spec changes
# ---------------------------------------------------------------------------
echo ""
echo "--- Check 3: Spec version field check ---"

while IFS= read -r file; do
  if [[ "$file" == spec/*.md ]]; then
    # Check if '对应代码 commit' line was modified in the diff
    if git diff "${MR_TARGET_BRANCH:-origin/main}...${MR_SOURCE_BRANCH:-HEAD}" -- "$file" 2>/dev/null | grep -q '对应代码 commit'; then
      echo "  [PASS] ${file}: version commit field updated"
    else
      WARNINGS+=("${file} was modified but '对应代码 commit' field was not updated.")
      echo "  [WARN] ${file}: '对应代码 commit' field not updated"
    fi
  fi
done <<< "$CHANGED_FILES"

# ---------------------------------------------------------------------------
# Check 4: Code formatting (clang-format)
# ---------------------------------------------------------------------------
echo ""
echo "--- Check 4: Code format check ---"

if command -v clang-format &> /dev/null; then
  FORMAT_ERRORS=0
  while IFS= read -r file; do
    if [[ "$file" == *.cc || "$file" == *.cpp || "$file" == *.h || "$file" == *.hpp ]]; then
      if [ -f "$file" ]; then
        if ! clang-format --dry-run --Werror "$file" 2>/dev/null; then
          FORMAT_ERRORS=$((FORMAT_ERRORS + 1))
          ERRORS+=("${file}: code formatting does not match .clang-format")
          echo "  [FAIL] ${file}: format mismatch"
        fi
      fi
    fi
  done <<< "$CHANGED_FILES"

  if [ "$FORMAT_ERRORS" -eq 0 ]; then
    echo "  [PASS] All changed source files properly formatted"
  fi
else
  echo "  [SKIP] clang-format not available"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""
  echo "WARNINGS (${#WARNINGS[@]}):"
  for w in "${WARNINGS[@]}"; do
    echo "  ⚠️  $w"
  done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "ERRORS (${#ERRORS[@]}):"
  for e in "${ERRORS[@]}"; do
    echo "  ❌ $e"
  done
  echo ""
  echo "=== FAILED ==="
  echo "Fix the above errors, or add [spec-exempt] to MR description with justification."
  exit 1
fi

echo ""
echo "=== PASSED ==="
exit 0
