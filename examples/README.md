# One request per capability

Each file is a complete request; run it with:

```sh
node _build/js/debug/build/cmd/main/main.js examples/<name>.json
```

| File | What it shows |
|---|---|
| `token-bucket.json` | a burst admitted, an over-burst denial with the exact retry moment |
| `gcra.json` | the same schedule answered by GCRA, verdict for verdict |
| `windows.json` | the fixed-window boundary burst the sliding window refuses |
| `backoff.json` | a seeded jitter table that reproduces from its seed |
| `leaky-bucket.json` | the queue-side dual filling and draining |
| `bulk.json` | batch admission |
| `state.json` | free capacity |
