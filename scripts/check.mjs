import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cli = path.join(root, '_build/js/debug/build/cmd/main/main.js');
if (!fs.existsSync(cli)) throw new Error('build first: moon build --target js');
const cases = JSON.parse(fs.readFileSync(path.join(root, 'tests/cases.json'), 'utf8'));
let passed = 0;
for (const test of cases) {
  const result = spawnSync(process.execPath, [cli, '-'],
    {input: JSON.stringify(test.request), encoding: 'utf8', timeout: 30000});
  if (test.error) {
    assert.equal(result.status, 1, test.name + ': wanted exit 1, got ' + result.status);
    const parsed = JSON.parse(result.stdout);
    assert.equal(typeof parsed.error, 'string', test.name + ': no error string');
  } else {
    assert.equal(result.status, 0, test.name + ': ' + result.stdout + result.stderr);
    const report = JSON.parse(result.stdout);
    for (const [key, expected] of Object.entries(test.expected)) {
      let actual = report;
      for (const part of key.split('/')) {
        actual = actual[Number.isInteger(Number(part)) && /^\d+$/.test(part) ? Number(part) : part];
      }
      assert.deepEqual(actual, expected, test.name + ': ' + key);
    }
  }
  passed++;
}
// Every shipped example is executed and compared to its pinned answer, so an
// example cannot quietly stop being true.
const exampleDir = path.join(root, 'examples');
for (const file of fs.readdirSync(exampleDir).filter((f) => f.endsWith('.json'))) {
  const request = JSON.parse(fs.readFileSync(path.join(exampleDir, file), 'utf8'));
  const expected = JSON.parse(fs.readFileSync(
    path.join(exampleDir, 'expected', file.replace('.json', '.expected.json')), 'utf8'));
  const result = spawnSync(process.execPath, [cli, '-'],
    {input: JSON.stringify(request), encoding: 'utf8', timeout: 30000});
  assert.equal(result.status, 0, file + ': ' + result.stdout + result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), expected, file + ' changed its answer');
  passed++;
}
console.log('CLI fixture cases passed:', passed);
