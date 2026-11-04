"""Malformed-input sweep: every bad request is answered, never crashed."""
import json, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / '_build/js/debug/build/cmd/main/main.js'

CASES = [
    ('unknown operation', {'operation': 'nope'}),
    ('limit missing events', {'operation': 'limit'}),
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
    ('backoff attempts fractional', {'operation': 'backoff', 'base_ms': 100,
      'attempts': 2.5}),
    ('backoff seed negative', {'operation': 'backoff', 'base_ms': 100,
      'attempts': 3, 'seed': -1}),
    ('state negative at', {'operation': 'state', 'algorithm': 'token_bucket',
      'rate': 1, 'burst': 1, 'at': -1}),
    ('state missing rate', {'operation': 'state', 'algorithm': 'token_bucket',
      'burst': 1, 'at': 1}),
    ('state unknown field', {'operation': 'state', 'algorithm': 'token_bucket',
      'rate': 1, 'burst': 1, 'at': 1, 'wat': 1}),
    ('state leaky_bucket not supported', {'operation': 'state',
      'algorithm': 'leaky_bucket', 'rate': 1, 'burst': 1, 'at': 1}),
    ('bulk count zero', {'operation': 'bulk', 'rate': 1, 'burst': 5,
      'at': 0, 'weight': 1, 'count': 0}),
    ('bulk overweight', {'operation': 'bulk', 'rate': 1, 'burst': 1,
      'at': 0, 'weight': 2, 'count': 1}),
    ('bulk non-token-bucket', {'operation': 'bulk', 'algorithm': 'gcra',
      'rate': 1, 'burst': 5, 'at': 0, 'count': 1}),
    ('bulk unknown field', {'operation': 'bulk', 'rate': 1, 'burst': 5,
      'at': 0, 'weight': 1, 'count': 1, 'wat': 1}),
    ('bulk count over limit', {'operation': 'bulk', 'rate': 1, 'burst': 5,
      'at': 0, 'weight': 1, 'count': 1001}),
    ('leaky_bucket unknown kind', {'operation': 'limit', 'algorithm': 'leaky_bucket',
      'rate': 1, 'burst': 1, 'events': [{'id': 'a', 'client': 'a', 'at': 1,
        'input': {'type': 'flood'}}]}),
    ('leaky_bucket overweight', {'operation': 'limit', 'algorithm': 'leaky_bucket',
      'rate': 1, 'burst': 1, 'events': [{'at': 0, 'weight': 2}]}),
    ('operation wrong type', {'operation': 42}),
    ('events empty', {'operation': 'limit', 'rate': 1, 'burst': 1, 'events': []}),
    ('unknown request field', {'operation': 'limit', 'wat': 1, 'events': []}),
    ('event unknown field', {'operation': 'limit', 'rate': 1, 'burst': 1,
      'events': [{'at': 0, 'wat': 1}]}),
    ('sw counter slices one', {'operation': 'limit', 'algorithm': 'sliding_window_counter',
      'limit': 2, 'window_seconds': 1, 'slices': 1, 'events': [{'at': 0}]}),
    ('sw counter slices fractional', {'operation': 'limit', 'algorithm': 'sliding_window_counter',
      'limit': 2, 'window_seconds': 1, 'slices': 2.5, 'events': [{'at': 0}]}),
    ('sw counter slices over bound', {'operation': 'limit', 'algorithm': 'sliding_window_counter',
      'limit': 2, 'window_seconds': 1, 'slices': 1001, 'events': [{'at': 0}]}),
    ('sw counter overweight', {'operation': 'limit', 'algorithm': 'sliding_window_counter',
      'limit': 2, 'window_seconds': 1, 'slices': 4,
      'events': [{'at': 0, 'weight': 3}]}),
    ('compose limiters missing', {'operation': 'compose',
      'events': [{'at': 0}]}),
    ('compose limiters not array', {'operation': 'compose',
      'limiters': 'nope', 'events': [{'at': 0}]}),
    ('compose limiters empty', {'operation': 'compose', 'limiters': [],
      'events': [{'at': 0}]}),
    ('compose limiters too many', {'operation': 'compose',
      'limiters': [{'algorithm': 'token_bucket', 'rate': 1, 'burst': 1}] * 9,
      'events': [{'at': 0}]}),
    ('compose limiter spec missing rate', {'operation': 'compose',
      'limiters': [{'algorithm': 'token_bucket', 'burst': 1}],
      'events': [{'at': 0}]}),
    ('compose weight over window limit', {'operation': 'compose',
      'limiters': [{'algorithm': 'fixed_window', 'limit': 2, 'window_seconds': 1}],
      'events': [{'at': 0, 'weight': 3}]}),
    ('compose unknown field in spec', {'operation': 'compose',
      'limiters': [{'algorithm': 'fixed_window', 'limit': 2,
        'window_seconds': 1, 'wat': 1}],
      'events': [{'at': 0}]}),
    ('compose spec not object', {'operation': 'compose',
      'limiters': [7], 'events': [{'at': 0}]}),
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
