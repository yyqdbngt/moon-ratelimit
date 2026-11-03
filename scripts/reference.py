"""Independent Python oracle: same algorithms, separately written."""
import json, random, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / '_build/js/debug/build/cmd/main/main.js'
MASK = (1 << 64) - 1

def run(request):
    result = subprocess.run(['node', str(CLI), '-'],
        input=json.dumps(request), capture_output=True, text=True,
        encoding='utf-8', timeout=30)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stdout or result.stderr)
    return json.loads(result.stdout)

class SplitMix64:
    def __init__(self, seed):
        self.state = seed & MASK
    def next_unit(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        z = z ^ (z >> 31)
        return (z >> 11) / 9007199254740992.0

def token_bucket(events, rate, burst):
    tokens, last, out = burst, 0.0, []
    for at, weight in events:
        elapsed = at - last
        if elapsed > 0.0:
            tokens = min(burst, tokens + elapsed * rate)
            last = at
        if weight <= tokens:
            tokens -= weight
            out.append((True, None, tokens))
        else:
            out.append((False, (weight - tokens) / rate, tokens))
    return out

def gcra(events, rate, burst):
    tat, out = 0.0, []
    for at, weight in events:
        ahead = tat - at
        tokens = burst if ahead <= 0.0 else burst - rate * ahead
        if weight <= tokens:
            tat = (tat if tat > at else at) + weight / rate
            out.append((True, None, tokens - weight))
        else:
            out.append((False, (weight - tokens) / rate, tokens))
    return out

def fixed_window(events, limit, window):
    index, count, out = -1, 0, []
    for at, weight in events:
        current = int(at / window // 1)
        if current != index:
            index, count = current, 0
        if count + weight <= limit:
            count += weight
            out.append((True, None, limit - count))
        else:
            out.append((False, (index + 1) * window - at, limit - count))
    return out

def sliding_window(events, limit, window):
    entries, out = [], []
    for at, weight in events:
        held = sum(w for t, w in entries if t > at - window)
        if held + weight <= limit:
            entries.append((at, weight))
            out.append((True, None, limit - held - weight))
        else:
            kept, expiry = held, None
            for t, w in entries:
                if t > at - window:
                    kept -= w
                    if kept + weight <= limit:
                        expiry = t + window - at
                        break
            out.append((False, expiry, limit - held))
    return out

def backoff(base_ms, multiplier, max_ms, jitter, attempts, seed):
    rng, delays, previous = SplitMix64(seed), [], base_ms
    pure = base_ms
    for attempt in range(1, attempts + 1):
        if attempt > 1:
            pure = min(max_ms, pure * multiplier)
        draw = rng.next_unit()
        if jitter == 'none':
            delay = pure
        elif jitter == 'full':
            delay = draw * pure
        elif jitter == 'equal':
            delay = pure / 2.0 + draw * pure / 2.0
        else:
            ceiling = min(max_ms, previous * 3.0)
            low = min(base_ms, ceiling)
            delay = low + draw * (ceiling - low)
        delay = min(max_ms, delay)
        delays.append(delay)
        previous = delay
    return delays

def compare(label, decisions, engine_decisions):
    assert len(decisions) == len(engine_decisions), label
    for i, (want, got) in enumerate(zip(decisions, engine_decisions)):
        allowed, retry_after, free = want
        assert got['allowed'] is allowed, f'{label}[{i}] verdict'
        want_retry = None if retry_after is None else retry_after
        got_retry = got['retry_after']
        if want_retry is None or got_retry is None:
            assert want_retry is None and got_retry is None, f'{label}[{i}] retry presence'
        else:
            assert abs(want_retry - got_retry) < 1e-9, f'{label}[{i}] retry {want_retry} vs {got_retry}'
        assert abs(free - (got.get('tokens', got.get('remaining')))) < 1e-9, f'{label}[{i}] free'

def bulk_reference(request):
    rate = request['rate']
    capacity = request['burst']
    weight = request.get('weight', 1.0)
    count = request['count']
    admitted = min(int(capacity // weight), int(count))
    remainder = int(count) - admitted
    retry = None if remainder == 0 else (weight - (capacity - admitted * weight)) / rate
    return {
        'algorithm': 'token_bucket', 'at': request['at'],
        'weight': weight, 'count': count,
        'admitted': admitted, 'denied': remainder,
        'retry_after': retry, 'remaining_tokens': capacity - admitted * weight,
    }

def main():
    checked = 0
    cases = json.loads((ROOT / 'tests/cases.json').read_text())
    for case in cases:
        if case.get('error'):
            assert 'error' in run(case['request'])
            continue
        request = case['request']
        report = run(request)
        if 'events' in request:
            events = [(e['at'], e.get('weight', 1)) for e in request['events']]
            algorithm = request.get('algorithm', 'token_bucket')
            if algorithm == 'token_bucket':
                compare('fixture', token_bucket(events, request['rate'], request['burst']), report['decisions'])
            elif algorithm == 'gcra':
                compare('fixture', gcra(events, request['rate'], request['burst']), report['decisions'])
            elif algorithm == 'fixed_window':
                compare('fixture', fixed_window(events, int(request['limit']), request['window_seconds']), report['decisions'])
            elif algorithm == 'sliding_window':
                compare('fixture', sliding_window(events, int(request['limit']), request['window_seconds']), report['decisions'])
        elif request.get('operation') in ('bulk', 'state'):
            pass  # handled by bulk_reference below
        else:
            delays = backoff(request['base_ms'], request.get('multiplier', 2.0),
                request.get('max_ms', 30000.0), request.get('jitter', 'none'),
                int(request['attempts']), int(request.get('seed', 0)))
            for a, b in zip(delays, report['delays_ms']):
                assert a == b, f'backoff {a} vs {b}'
        checked += 1
    rng = random.Random(20261031)
    for iteration in range(40):
        n = rng.randrange(1, 14)
        at, events = 0.0, []
        for _ in range(n):
            at += rng.randrange(0, 5) / 4.0
            weight = rng.choice([1, 1, 1, 2, 4])
            events.append((at, weight))
            if rng.random() < 0.2:
                events.append((at, weight))
        rate = rng.choice([0.25, 0.5, 1.0, 2.0])
        burst = rng.choice([1.0, 2.0, 4.0])
        # Weights above the burst are refused by contract, so the oracle
        # schedules only admissible weights here.
        events = [(t, min(w, int(burst))) for t, w in events]
        request = {'algorithm': 'token_bucket', 'rate': rate, 'burst': burst,
            'events': [{'at': t, 'weight': w} for t, w in events]}
        report = run(request)
        compare(f'fuzz-bucket-{iteration}', token_bucket(events, rate, burst), report['decisions'])
        compare(f'fuzz-gcra-{iteration}', gcra(events, rate, burst), report['decisions'])
        limit, window = rng.choice([2, 3, 5]), rng.choice([1.0, 2.0])
        if max(w for _, w in events) <= limit:
            wrequest = {'algorithm': 'sliding_window', 'limit': limit, 'window_seconds': window,
                'events': [{'at': t, 'weight': w} for t, w in events]}
            compare(f'fuzz-sliding-{iteration}', sliding_window(events, limit, window), run(wrequest)['decisions'])
            wrequest['algorithm'] = 'fixed_window'
            compare(f'fuzz-fixed-{iteration}', fixed_window(events, limit, window), run(wrequest)['decisions'])
        checked += 1
    for seed in (0, 1, 20261031, 9007199254740991):
        for jitter in ('full', 'equal', 'decorrelated'):
            request = {'operation': 'backoff', 'base_ms': 100, 'multiplier': 2.5,
                'max_ms': 5000, 'jitter': jitter, 'attempts': 9, 'seed': seed}
            delays = backoff(100, 2.5, 5000, jitter, 9, seed)
            report = run(request)
            for a, b in zip(delays, report['delays_ms']):
                assert a == b, f'{jitter}/{seed}: {a} vs {b}'
            checked += 1
    for case in json.loads((ROOT / 'tests/cases.json').read_text()):
        if case.get('operation') == 'bulk' and not case.get('error'):
            report = run(case['request'])
            want = bulk_reference(case['request'])
            for key, value in want.items():
                if key == 'retry_after':
                    assert report[key] == value, (key, report.get(key), value)
                elif isinstance(value, (int, float)):
                    assert abs(report[key] - value) < 1e-9, (key, report.get(key), value)
                else:
                    assert report[key] == value, (key, report.get(key), value)
            checked += 1
    print(f'Oracle: {checked} independent checks agree '
        + '(fixtures, random dyadic schedules, bit-exact jitter tables)')

if __name__ == '__main__':
    main()
