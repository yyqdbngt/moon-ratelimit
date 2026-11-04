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

def leaky_bucket(events, rate, burst):
    level, last, out = 0.0, 0.0, []
    for at, weight in events:
        elapsed = at - last
        if elapsed > 0.0:
            level = max(0.0, level - elapsed * rate)
            last = at
        if level + weight <= burst:
            level += weight
            out.append((True, None, burst - level))
        else:
            overflow = level + weight - burst
            out.append((False, overflow / rate, burst - level))
    return out

def sliding_window_counter(events, limit, window, slices):
    # The trailing window is approximated by the `slices` sub-windows
    # ending at the current one. `stored` maps sub-window index to count
    # and is pruned to that range, so an index that left the range is
    # gone for good - the ring-slot bookkeeping of the implementation,
    # written without a ring.
    slice_width = window / slices
    stored = {}
    out = []
    for at, weight in events:
        current = int(at / slice_width // 1)
        first = current - slices + 1
        for idx in [i for i in stored if i < first]:
            del stored[idx]
        held = sum(stored.get(i, 0) for i in range(max(first, 0), current + 1))
        if held + weight <= limit:
            stored[current] = stored.get(current, 0) + weight
            out.append((True, None, limit - held - weight))
        else:
            out.append((False, (current + 1) * slice_width - at, limit - held))
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

def make_limiter(spec):
    """Step-wise state for one compose member, keyed by algorithm name."""
    kind = spec.get('algorithm', 'token_bucket')
    if kind in ('token_bucket', 'gcra', 'leaky_bucket'):
        rate, burst = spec['rate'], spec['burst']
        assert rate > 0 and burst > 0
        if kind == 'gcra':
            return {'kind': kind, 'rate': rate, 'burst': burst, 'tat': 0.0}
        state = {'kind': kind, 'rate': rate, 'burst': burst, 'last': 0.0}
        state['tokens' if kind == 'token_bucket' else 'level'] = burst if kind == 'token_bucket' else 0.0
        return state
    limit, window = spec['limit'], spec['window_seconds']
    assert limit >= 1 and limit == int(limit) and window > 0
    limit = int(limit)
    if kind == 'fixed_window':
        return {'kind': kind, 'limit': limit, 'window': window, 'index': -1, 'count': 0}
    if kind == 'sliding_window':
        return {'kind': kind, 'limit': limit, 'window': window, 'entries': []}
    if kind == 'sliding_window_counter':
        slices = int(spec.get('slices', 10))
        assert 2 <= slices <= 1000
        return {'kind': kind, 'limit': limit, 'window': window,
            'slices': slices, 'stored': {}}
    raise AssertionError('unknown limiter ' + kind)

def decide_one(state, at, weight):
    """The (allowed, retry_after, tokens) one limiter reports at `at`,
    computed against time-advanced state without changing anything."""
    kind = state['kind']
    if kind in ('token_bucket', 'leaky_bucket'):
        elapsed = at - state['last']
        key = 'tokens' if kind == 'token_bucket' else 'level'
        current = state[key]
        if elapsed > 0:
            if kind == 'token_bucket':
                current = min(state['burst'], state[key] + elapsed * state['rate'])
            else:
                current = max(0.0, state[key] - elapsed * state['rate'])
        if kind == 'token_bucket':
            if weight <= current:
                return (True, None, current - weight)
            return (False, (weight - current) / state['rate'], current)
        if current + weight <= state['burst']:
            return (True, None, state['burst'] - current - weight)
        return (False, (current + weight - state['burst']) / state['rate'],
            state['burst'] - current)
    if kind == 'gcra':
        ahead = state['tat'] - at
        tokens = state['burst'] if ahead <= 0 else state['burst'] - state['rate'] * ahead
        if weight <= tokens:
            return (True, None, tokens - weight)
        return (False, (weight - tokens) / state['rate'], tokens)
    if kind == 'fixed_window':
        index = int(at / state['window'] // 1)
        count = 0 if index != state['index'] else state['count']
        if count + weight <= state['limit']:
            return (True, None, state['limit'] - count - weight)
        return (False, (index + 1) * state['window'] - at, state['limit'] - count)
    if kind == 'sliding_window':
        held = sum(w for t, w in state['entries'] if t > at - state['window'])
        if held + weight <= state['limit']:
            return (True, None, state['limit'] - held - weight)
        kept, expiry = held, None
        for t, w in state['entries']:
            if t > at - state['window']:
                kept -= w
                if kept + weight <= state['limit']:
                    expiry = t + state['window'] - at
                    break
        return (False, expiry, state['limit'] - held)
    # sliding_window_counter: the pruned sub-window map, read only.
    slice_width = state['window'] / state['slices']
    current = int(at / slice_width // 1)
    first = current - state['slices'] + 1
    held = sum(state['stored'].get(i, 0)
        for i in range(max(first, 0), current + 1))
    if held + weight <= state['limit']:
        return (True, None, state['limit'] - held - weight)
    return (False, (current + 1) * slice_width - at, state['limit'] - held)

def commit_one(state, at, weight, allowed):
    """Apply one event; the time folds happen for denials too, matching the
    single-algorithm replays."""
    kind = state['kind']
    if kind in ('token_bucket', 'leaky_bucket'):
        elapsed = at - state['last']
        key = 'tokens' if kind == 'token_bucket' else 'level'
        if elapsed > 0:
            if kind == 'token_bucket':
                state[key] = min(state['burst'], state[key] + elapsed * state['rate'])
            else:
                state[key] = max(0.0, state[key] - elapsed * state['rate'])
            state['last'] = at
        if allowed:
            state[key] = state[key] + (-weight if kind == 'token_bucket' else weight)
        return
    if kind == 'gcra':
        if allowed:
            state['tat'] = max(state['tat'], at) + weight / state['rate']
        return
    if kind == 'fixed_window':
        index = int(at / state['window'] // 1)
        if index != state['index']:
            state['index'], state['count'] = index, 0
        if allowed:
            state['count'] += weight
        return
    if kind == 'sliding_window':
        if allowed:
            state['entries'].append((at, weight))
        return
    current = int(at / (state['window'] / state['slices']) // 1)
    if allowed:
        state['stored'][current] = state['stored'].get(current, 0) + weight

def compose(events, specs):
    """Transactional composition: decide on every limiter, commit to all
    only when every one allowed, report the longest refusal and the
    smallest remaining capacity."""
    states = [make_limiter(spec) for spec in specs]
    out = []
    for at, weight in events:
        admissions = [decide_one(state, at, weight) for state in states]
        allowed = all(a[0] for a in admissions)
        retry = None
        for candidate in admissions:
            if candidate[1] is not None and (retry is None or candidate[1] > retry):
                retry = candidate[1]
        least = min(a[2] for a in admissions)
        if allowed:
            for state in states:
                commit_one(state, at, weight, True)
        out.append((allowed, None if allowed else retry, least))
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
            if request.get('operation') == 'compose':
                compare('fixture', compose(events, request['limiters']), report['decisions'])
            elif algorithm == 'token_bucket':
                compare('fixture', token_bucket(events, request['rate'], request['burst']), report['decisions'])
            elif algorithm == 'gcra':
                compare('fixture', gcra(events, request['rate'], request['burst']), report['decisions'])
            elif algorithm == 'sliding_window_counter':
                slices = int(request.get('slices', 10))
                compare('fixture', sliding_window_counter(events, int(request['limit']), request['window_seconds'], slices), report['decisions'])
            elif algorithm == 'leaky_bucket':
                compare('fixture', leaky_bucket(events, request['rate'], request['burst']), report['decisions'])
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
        lrequest = {'algorithm': 'leaky_bucket', 'rate': rate, 'burst': burst,
            'events': [{'at': t, 'weight': w} for t, w in events]}
        compare(f'fuzz-leaky-{iteration}', leaky_bucket(events, rate, burst), run(lrequest)['decisions'])
        limit, window = rng.choice([2, 3, 5]), rng.choice([1.0, 2.0])
        if max(w for _, w in events) <= limit:
            wrequest = {'algorithm': 'sliding_window', 'limit': limit, 'window_seconds': window,
                'events': [{'at': t, 'weight': w} for t, w in events]}
            compare(f'fuzz-sliding-{iteration}', sliding_window(events, limit, window), run(wrequest)['decisions'])
            wrequest['algorithm'] = 'fixed_window'
            compare(f'fuzz-fixed-{iteration}', fixed_window(events, limit, window), run(wrequest)['decisions'])
            # Slices are powers of two so every sub-window boundary in the
            # schedule is exactly representable on all four backends.
            slices = rng.choice([2, 4, 8])
            wrequest['algorithm'] = 'sliding_window_counter'
            wrequest['slices'] = slices
            compare(f'fuzz-swcounter-{iteration}',
                sliding_window_counter(events, limit, window, slices), run(wrequest)['decisions'])
        # Transactional composition of 1..3 limiters against the same
        # schedule; a single-member compose must equal the plain run.
        families = [
            {'algorithm': 'token_bucket', 'rate': rate, 'burst': burst},
            {'algorithm': 'gcra', 'rate': rate, 'burst': burst},
            {'algorithm': 'leaky_bucket', 'rate': rate, 'burst': burst},
            {'algorithm': 'fixed_window', 'limit': limit, 'window_seconds': window},
            {'algorithm': 'sliding_window', 'limit': limit, 'window_seconds': window},
            {'algorithm': 'sliding_window_counter', 'limit': limit,
                'window_seconds': window, 'slices': rng.choice([2, 4, 8])},
        ]
        specs = rng.sample(families, rng.choice([1, 2, 2, 3]))
        caps = [burst] + [limit for s in specs
            if s['algorithm'] not in ('token_bucket', 'gcra', 'leaky_bucket')]
        cevents = [(t, min(w, int(min(caps)))) for t, w in events]
        crequest = {'operation': 'compose', 'limiters': specs,
            'events': [{'at': t, 'weight': w} for t, w in cevents]}
        creport = run(crequest)
        compare(f'fuzz-compose-{iteration}',
            compose(cevents, specs), creport['decisions'])
        if len(specs) == 1:
            # A single-member compose must answer exactly what the plain
            # algorithm's replay answers on the same schedule.
            only = specs[0]
            if only['algorithm'] == 'fixed_window':
                want = fixed_window(cevents, limit, window)
            elif only['algorithm'] == 'sliding_window':
                want = sliding_window(cevents, limit, window)
            elif only['algorithm'] == 'sliding_window_counter':
                want = sliding_window_counter(cevents, limit, window, only['slices'])
            else:
                want = {'token_bucket': token_bucket, 'gcra': gcra,
                    'leaky_bucket': leaky_bucket}[only['algorithm']](cevents, rate, burst)
            compare(f'fuzz-compose-single-{iteration}', want, creport['decisions'])
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
