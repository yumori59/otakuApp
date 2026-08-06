import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';

/**
 * 中-5 の再発防止。
 * `ConfigService.get('X')` / `process.env.X` で読む環境変数が
 * ローカル開発の docker-compose.yml (`api.environment`) に無いと
 * `make up` 直後に auth / shares が 500 になる。
 * 実装側で変数を増やしたらこのテストが落ちる。
 */

const SRC_DIR = resolve(__dirname, '..');
const REPO_ROOT = resolve(__dirname, '..', '..', '..', '..');
const COMPOSE_PATH = join(REPO_ROOT, 'docker-compose.yml');

/** compose では扱わない（実行環境が与える / 任意）変数。 */
const NOT_REQUIRED_IN_COMPOSE = new Set(['NODE_ENV']);

function collectSourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) return collectSourceFiles(full);
    if (!full.endsWith('.ts') || full.endsWith('.spec.ts')) return [];
    return [full];
  });
}

function collectEnvKeys(): string[] {
  const patterns = [
    /\bconfig(?:Service)?\.get(?:<[^>]*>)?\(\s*'([A-Z][A-Z0-9_]*)'/g,
    /\bprocess\.env\.([A-Z][A-Z0-9_]*)/g,
    /\bprocess\.env\[\s*'([A-Z][A-Z0-9_]*)'/g,
  ];
  const keys = new Set<string>();
  for (const file of collectSourceFiles(SRC_DIR)) {
    const source = readFileSync(file, 'utf8');
    for (const pattern of patterns) {
      for (const match of source.matchAll(pattern)) keys.add(match[1]);
    }
  }
  return [...keys].filter((key) => !NOT_REQUIRED_IN_COMPOSE.has(key)).sort();
}

/** `services.api.environment:` ブロックのキー名だけを拾う（値は見ない）。 */
function composeApiEnvKeys(): string[] {
  const lines = readFileSync(COMPOSE_PATH, 'utf8').split('\n');
  const apiIndex = lines.findIndex((line) => /^ {2}api:\s*$/.test(line));
  expect(apiIndex).toBeGreaterThan(-1);

  const offset = lines
    .slice(apiIndex + 1)
    .findIndex((line) => /^ {4}environment:\s*$/.test(line));
  expect(offset).toBeGreaterThan(-1);
  const start = apiIndex + 1 + offset;

  const keys: string[] = [];
  for (const line of lines.slice(start + 1)) {
    if (!/^ {6}\S/.test(line)) break;
    const match = /^ {6}([A-Z][A-Z0-9_]*):/.exec(line);
    if (match) keys.push(match[1]);
  }
  return keys.sort();
}

describe('環境変数の docker-compose 追従', () => {
  it('中-5 src が読む環境変数はすべて docker-compose.yml の api.environment にある', () => {
    const declared = new Set(composeApiEnvKeys());
    const missing = collectEnvKeys().filter((key) => !declared.has(key));

    expect(missing).toEqual([]);
  });

  it('中-5 docker-compose.yml に src が読まない環境変数を残さない', () => {
    const used = new Set([...collectEnvKeys(), 'DATABASE_URL', 'NODE_ENV']);
    const stale = composeApiEnvKeys().filter((key) => !used.has(key));

    expect(stale).toEqual([]);
  });
});
