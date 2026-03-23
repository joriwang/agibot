#!/usr/bin/env bash
# =============================================================================
# Stage 2: AI-Powered Code Review via OpenCode
# Invokes OpenCode in non-interactive mode with the review agent.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULT_FILE="/tmp/review_result.json"
REVIEW_LOG="/tmp/review_output.log"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MODEL="${OPENCODE_MODEL:-openrouter/anthropic/claude-sonnet-4.6}"
MAX_ITERATIONS="${OPENCODE_MAX_ITERATIONS:-30}"

echo "=== AI Code Review ==="
echo "Model: ${MODEL}"
echo "Max iterations: ${MAX_ITERATIONS}"
echo ""

# ---------------------------------------------------------------------------
# Collect MR context
# ---------------------------------------------------------------------------
cd "$PROJECT_ROOT"

# Get diff
DIFF=$(git diff HEAD^1 2>/dev/null || echo "")
if [ -z "$DIFF" ]; then
  echo "[INFO] No diff detected. Skipping AI review."
  # Write a passing result
  cat > "$RESULT_FILE" << 'EOF'
{
  "summary": "No code changes detected — nothing to review.",
  "findings": [],
  "spec_update_needed": false,
  "spec_update_details": ""
}
EOF
  exit 0
fi

CHANGED_FILES=$(git diff --name-only HEAD^1 2>/dev/null || echo "")
echo "Changed files for review:"
echo "$CHANGED_FILES" | sed 's/^/  /'
echo ""

# ---------------------------------------------------------------------------
# Build the review prompt
# ---------------------------------------------------------------------------
# The review agent already knows its role (defined in .opencode/agents/review.md).
# We only need to tell it what to review.

REVIEW_PROMPT="Review the current merge request. The diff is between HEAD^1 and HEAD.

Changed files:
${CHANGED_FILES}

Instructions:
1. Run \`git diff HEAD^1\` to see the full diff.
2. Read the spec files that correspond to the changed modules.
3. Read \`spec/bugs.md\` for known bug patterns.
4. Perform the four-category review as defined in your agent instructions.
5. Write the JSON result to /tmp/review_result.json.

Focus your review on the changed files only. Do not review unchanged code."

# ---------------------------------------------------------------------------
# Run OpenCode review agent
# ---------------------------------------------------------------------------
echo "Running OpenCode review agent..."
echo ""

# Use opencode run with the review agent in non-interactive mode
opencode run \
  --agent review \
  --model "$(echo "$MODEL" | cut -d/ -f2-)" \
  "$REVIEW_PROMPT" \
  2>&1 | tee "$REVIEW_LOG" || true

echo ""
echo "OpenCode review completed."

# ---------------------------------------------------------------------------
# Validate result
# ---------------------------------------------------------------------------
if [ ! -f "$RESULT_FILE" ]; then
  echo "[WARN] OpenCode did not produce $RESULT_FILE. Creating fallback result."
  cat > "$RESULT_FILE" << 'EOF'
{
  "summary": "AI review agent did not produce structured output. Check review log for details.",
  "findings": [
    {
      "severity": "WARNING",
      "category": "code_quality",
      "file": "",
      "line": null,
      "message": "The AI review agent completed but did not write a result file. This may indicate a prompt issue or model error. Manual review recommended.",
      "spec_reference": "",
      "suggestion": "Check /tmp/review_output.log for the raw agent output."
    }
  ],
  "spec_update_needed": false,
  "spec_update_details": ""
}
EOF
fi

# Validate JSON
if ! python3 -c "import json; json.load(open('$RESULT_FILE'))" 2>/dev/null; then
  echo "[WARN] $RESULT_FILE is not valid JSON. Attempting extraction..."

  # Try to extract JSON from the file content (agent might have wrapped it)
  python3 -c "
import re, json, sys
content = open('$RESULT_FILE').read()
# Try to find a JSON object in the content
match = re.search(r'\{.*\}', content, re.DOTALL)
if match:
    try:
        obj = json.loads(match.group())
        json.dump(obj, open('$RESULT_FILE', 'w'), indent=2)
        print('[INFO] Extracted valid JSON from result file.')
        sys.exit(0)
    except json.JSONDecodeError:
        pass
print('[ERROR] Could not extract valid JSON.')
sys.exit(1)
" || {
    echo "[ERROR] Failed to parse review result. Creating error result."
    cat > "$RESULT_FILE" << 'EOF'
{
  "summary": "AI review produced malformed output. Manual review required.",
  "findings": [
    {
      "severity": "WARNING",
      "category": "code_quality",
      "file": "",
      "line": null,
      "message": "AI review output was not valid JSON. The review may have been incomplete.",
      "spec_reference": "",
      "suggestion": "Run the review manually or check the review log."
    }
  ],
  "spec_update_needed": false,
  "spec_update_details": ""
}
EOF
  }
fi

# ---------------------------------------------------------------------------
# Determine exit code based on findings
# ---------------------------------------------------------------------------
echo ""
echo "=== Review Result ==="
python3 -c "
import json, sys

with open('$RESULT_FILE') as f:
    result = json.load(f)

print(f\"Summary: {result.get('summary', 'N/A')}\")

findings = result.get('findings', [])
critical = [f for f in findings if f.get('severity') == 'CRITICAL']
warnings = [f for f in findings if f.get('severity') == 'WARNING']
infos = [f for f in findings if f.get('severity') == 'INFO']

print(f'Findings: {len(critical)} CRITICAL, {len(warnings)} WARNING, {len(infos)} INFO')

if result.get('spec_update_needed'):
    print(f\"Spec update needed: {result.get('spec_update_details', 'Yes')}\")

if critical:
    print()
    print('CRITICAL findings (will block merge):')
    for f in critical:
        loc = f.get('file', '')
        if f.get('line'):
            loc += f':{f[\"line\"]}'
        print(f'  ❌ [{f.get(\"category\", \"\")}] {loc}')
        print(f'     {f.get(\"message\", \"\")}')
    sys.exit(1)
else:
    print()
    print('No CRITICAL findings. Pipeline passes.')
    sys.exit(0)
"

EXIT_CODE=$?
exit $EXIT_CODE
