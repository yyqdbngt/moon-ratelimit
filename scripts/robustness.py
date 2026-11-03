"""Malformed-input sweep: every bad request is answered, never crashed."""
import json, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / '_build/js/debug/build/cmd/main/main.js'

CASES = [
    ('unknown operation', {'operation': 'nope'}),
    ('limit missing events', {'operation': 'limit'}),
    ('limit wrong algorithm', {'operation': 'limit', 'algorithm': 'leaky_bucket',
      'rate': 1, 'events': [{'at': 0}]}),
    ('rate zero', {'operation': 'limit', 'algorithm': 'token_bucket',
      'rate': 0, 'burst': 1, 'events': [{'at': 0}]}),
    ('burst negative', {'operation': 'limit', 'algorithm': 'token_bucket',
      'rate': 1, 'burst': -1, 'events': [{'at': 0}]}),
    ('events not array', {'operation': 'limit', 'events': 'nope'}),
    ('event negative at', {'operation': 'limit', 'rate': 1, 'burst': 1,
      'events': [{'at': -1}]}),
    ('events not sorted', {'operation': 'limit', 'rate': 1, 'burst': 1,
      'events': [{'at': 2}, {'at': 1}]}),
    ('weight zero', {'operation': 'limit', 'rate': 1, 'burst': 1,
      'events': [{'at': 0, 'weight': 0}]}),
    ('weight over burst', {'operation': 'limit', 'rate': 1, 'burst': 1,
      'events': [{'at': 0, 'weight': 2}]}),
    ('window weight fractional', {'operation': 'limit', 'algorithm': 'fixed_window',
      'limit': 2, 'window_seconds': 1, 'events': [{'at': 0, 'weight': 0.5}]}),
    ('backoff base zero', {'operation': 'backoff', 'base_ms': 0, 'attempts': 3}),
    ('backoff multiplier one', {'operation': 'backoff', 'base_ms': 100,
      'multiplier': 1, 'attempts': 3}),
    ('backoff jitter unknown', {'operation': 'backoff', 'base_ms': 100,
      'attempts': 3, 'jitter': 'smooth'}),
    ('backoff attempts zero', {'operation': 'backoff', 'base_ms': 100, 'attempts': 0}),
    ('state negative at', {'operation': 'state', 'algorithm': 'token_bucket',
      'rate': 1, 'burst': 1, 'at': -1}),
    ('state missing rate', {'operation': 'state', 'algorithm': 'token_bucket',
      'burst': 1, 'at': 1}),
    ('bulk count zero', {'operation': 'bulk', 'rate': 1, 'burst': 5,
      'at': 0, 'weight': 1, 'count': 0}),
    ('bulk overweight', {'operation': 'bulk', 'rate': 1, 'burst': 1,
      'at': 0, 'weight': 2, 'count': 1}),
    ('bulk non-token-bucket', {'operation': 'bulk', 'algorithm': 'gcra',
      'rate': 1, 'burst': 5, 'at': 0, 'count': 1}),
    ('unknown request field', {'operation': 'limit', 'wat': 1, 'events': []}),
    ('event unknown field', {'operation': 'limit', 'rate': 1, 'burst': 1,
      'events': [{'at': 0, 'wat': 1}]}),
]

failures = []
for label, request in CASES:
    result = subprocess.run(
        ['node', str(CLI), '-'],
        input=json.dumps(request), capture_output=True, text=True,
        encoding='utf-8', timeout=20)
    if result.returncode != 1:
        failures.append(label + ': exit ' + str(result.returncode))
        continue
    try:
        parsed = json.loads(result.stdout)
    except Exception:
        failures.append(label + ': stdout is not one JSON object')
        continue
    if not isinstance(parsed, dict) or not isinstance(parsed.get('error'), str):
        failures.append(label + ': no error string')
    if result.stderr.strip():
        failures.append(label + ': wrote to stderr')

print(f'Robustness: {len(CASES)} malformed requests all answered with '
    + 'one error object and exit 1')
if failures:
    for failure in failures:
        print('  ' + failure)
    sys.exit(1)
