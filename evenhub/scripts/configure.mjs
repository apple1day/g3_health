import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const args = process.argv.slice(2);
const offset = args.indexOf('--api-url');
if (offset === -1 || !args[offset + 1]) {
  console.error('用法：npm run configure -- --api-url https://health.example.com');
  process.exit(1);
}
let url;
try { url = new URL(args[offset + 1]); } catch {
  console.error('需要完整的 HTTPS 服务地址；本地测试可用局域网 HTTP 地址。');
  process.exit(1);
}
const host = url.hostname.toLowerCase();
const allowLocalHTTP = args.includes('--allow-local-http');
const octets = host.split('.').map(part => /^\d+$/.test(part) ? Number(part) : NaN);
  const ipv4 = octets.length === 4 && octets.every(part => Number.isInteger(part) && part >= 0 && part <= 255);
  const privateIP = ipv4 && (octets[0] === 127 || octets[0] === 10 || (octets[0] === 192 && octets[1] === 168) || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31));
  const local = host === 'localhost' || host === '[::1]' || host.endsWith('.local') || privateIP;
if (url.username || url.password || url.search || url.hash || (url.pathname !== '/' && url.pathname !== '') || !['http:', 'https:'].includes(url.protocol) || (url.protocol === 'http:' && (!local || !allowLocalHTTP))) {
  console.error('只接受无凭据、无路径、无参数的 HTTPS origin；HTTP 仅限本机或内网，并需显式加 --allow-local-http。');
  process.exit(1);
}
const manifestPath = fileURLToPath(new URL('../app.json', import.meta.url));
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
manifest.permissions.find(permission => permission.name === 'network').whitelist = [url.origin];
await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
console.log(`已将 network.whitelist 设置为 ${url.origin}`);
console.log('请重新 build、pack；手机配置页填写相同服务地址与只读密钥。');
