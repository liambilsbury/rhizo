#!/bin/bash
# run the cli and broker test suites
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit

CLI_TEST=src/install/tests/test-cli.sh
BROKER_TEST=src/services/broker/tests/test_broker.py

# run the cli and broker test suites
run_suites() {
  local cli="$1" broker="$2" fails=0

  if [[ ! -f "$cli" ]]; then
    echo "no $cli" >&2
    return 1
  fi
  if [[ ! -f "$broker" ]]; then
    echo "no $broker" >&2
    return 1
  fi

  echo "--- $cli ---"
  if ! bash "$cli"; then
    echo "FAIL: $cli exited non-zero" >&2
    fails=1
  fi

  echo "--- $broker ---"
  if ! python3 "$broker"; then
    echo "FAIL: $broker exited non-zero" >&2
    fails=1
  fi

  return "$fails"
}

# run run_suites on synthetic test scripts
selftest() {
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  cat > "$tmp/test-cli.sh" <<'EOF'
#!/bin/bash
echo "FAIL synthetic"
echo "1 checks failed"
exit 1
EOF
  cat > "$tmp/test_broker.py" <<'EOF'
print("0 checks failed")
EOF
  if run_suites "$tmp/test-cli.sh" "$tmp/test_broker.py" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a broken cli test suite did not fail the wrapper" >&2
    return 1
  fi

  cat > "$tmp/test-cli.sh" <<'EOF'
#!/bin/bash
echo "0 checks failed"
exit 0
EOF
  cat > "$tmp/test_broker.py" <<'EOF'
import sys
print("FAIL synthetic")
sys.exit(1)
EOF
  if run_suites "$tmp/test-cli.sh" "$tmp/test_broker.py" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a broken broker test suite did not fail the wrapper" >&2
    return 1
  fi

  if ! run_suites "$CLI_TEST" "$BROKER_TEST" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: the real test-cli.sh/test_broker.py do not pass" >&2
    return 1
  fi

  echo "selftest ok: a broken suite fails the wrapper, the real suites pass"
  return 0
}

if [[ "${1:-}" == --selftest ]]; then
  selftest
else
  run_suites "$CLI_TEST" "$BROKER_TEST"
fi
