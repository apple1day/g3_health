import { mkdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const directory = fileURLToPath(new URL('../', import.meta.url));
await mkdir(fileURLToPath(new URL('../../artifacts/', import.meta.url)), { recursive: true });
const executable = process.platform === 'win32' ? 'evenhub.cmd' : 'evenhub';
const result = spawnSync(executable, ['pack', 'app.json', 'dist', '--sdk-ver', '0.0.16', '-o', '../artifacts/health-glance.ehpk'], { cwd: directory, stdio: 'inherit' });
if (result.error) { console.error('打包失败，请先执行 npm ci。'); process.exit(1); }
process.exit(result.status ?? 1);
