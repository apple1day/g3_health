export type SectionStatus = 'ok' | 'empty' | 'error';
type NullableNumber = number | null;
export interface Snapshot {
  schemaVersion: 1; dataMode: 'healthkit' | 'demo'; generatedAt: string; day: string;
  timeZone: string; sourcePolicy: 'healthKit';
  sleep: { status: SectionStatus; startedAt: string | null; endedAt: string | null;
    totalMinutes: NullableNumber; coreMinutes: NullableNumber; deepMinutes: NullableNumber;
    remMinutes: NullableNumber; unspecifiedMinutes: NullableNumber; awakeMinutes: NullableNumber; sourceName: string | null; };
  activity: { status: SectionStatus; steps: NullableNumber; distanceMeters: NullableNumber;
    activeEnergyKcal: NullableNumber; exerciseMinutes: NullableNumber; standHours: NullableNumber;
    activeEnergyGoalKcal: NullableNumber; exerciseGoalMinutes: NullableNumber; standGoalHours: NullableNumber;
    moveMode: 'energy' | 'time' | 'unknown'; moveMinutes: NullableNumber; moveGoalMinutes: NullableNumber; };
  heartRate: { status: SectionStatus; bpm: NullableNumber; measuredAt: string | null; };
  workout: { status: SectionStatus; kind: string | null; startedAt: string | null; endedAt: string | null;
    durationSeconds: NullableNumber; distanceMeters: NullableNumber; activeEnergyKcal: NullableNumber; };
  warnings: string[];
}
export interface Envelope { snapshot: Snapshot; receivedAt: string; }
const fail = (): never => { throw new Error('数据格式不符合快照 v1，请检查 iPhone App 与服务版本。'); };
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return fail();
  return value as Record<string, unknown>;
}
function enumeration<T extends string>(value: unknown, choices: readonly T[]): T {
  return typeof value === 'string' && choices.includes(value as T) ? value as T : fail();
}
function text(value: unknown, max = 160): string | null {
  if (value == null) return null;
  if (typeof value !== 'string' || value.length > max) return fail();
  return value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '');
}
function number(value: unknown): number | null {
  if (value == null) return null;
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e10 ? value : fail();
}
function validDay(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return false;
  const year=Number(match[1]), month=Number(match[2]), day=Number(match[3]);
  if (year<1 || month<1 || month>12 || day<1) return false;
  const leap=year%4===0 && (year%100!==0 || year%400===0);
  const days=[31,leap?29:28,31,30,31,30,31,31,30,31,30,31];
  return day<=days[month-1];
}
function date(value: unknown, required = false): string | null {
  if (value == null && !required) return null;
  if (typeof value !== 'string' || value.length > 40) return fail();
  const match=/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match || !validDay(match[1]) || Number(match[2])>23 || Number(match[3])>59 || Number(match[4])>59 || !Number.isFinite(Date.parse(value))) return fail();
  if(match[5]!=='Z' && (Number(match[5].slice(1,3))>23 || Number(match[5].slice(4))>59)) return fail();
  return value;
}
const sectionStatus = (value: unknown) => enumeration(value, ['ok', 'empty', 'error'] as const);
export function parseSnapshot(input: unknown): Snapshot {
  const obj = object(input); if (obj.schemaVersion !== 1 || obj.sourcePolicy !== 'healthKit') return fail();
  const sleep = object(obj.sleep), a = object(obj.activity), hr = object(obj.heartRate), w = object(obj.workout);
  const zone = text(obj.timeZone, 100); if (!zone) return fail();
  try { new Intl.DateTimeFormat('en', { timeZone: zone }); } catch { return fail(); }
  const day = text(obj.day, 10);
  if (!day || !validDay(day)) return fail();
  if (!Array.isArray(obj.warnings) || obj.warnings.length > 30) return fail();
  const result: Snapshot = {
    schemaVersion: 1, sourcePolicy: 'healthKit', dataMode: enumeration(obj.dataMode, ['healthkit','demo'] as const),
    generatedAt: date(obj.generatedAt, true)!, day, timeZone: zone,
    sleep: { status: sectionStatus(sleep.status), startedAt: date(sleep.startedAt), endedAt: date(sleep.endedAt),
      totalMinutes: number(sleep.totalMinutes), coreMinutes: number(sleep.coreMinutes), deepMinutes: number(sleep.deepMinutes),
      remMinutes: number(sleep.remMinutes), unspecifiedMinutes: number(sleep.unspecifiedMinutes), awakeMinutes: number(sleep.awakeMinutes), sourceName: text(sleep.sourceName) },
    activity: { status: sectionStatus(a.status), steps: number(a.steps), distanceMeters: number(a.distanceMeters),
      activeEnergyKcal: number(a.activeEnergyKcal), exerciseMinutes: number(a.exerciseMinutes), standHours: number(a.standHours),
      activeEnergyGoalKcal: number(a.activeEnergyGoalKcal), exerciseGoalMinutes: number(a.exerciseGoalMinutes), standGoalHours: number(a.standGoalHours),
      moveMode: enumeration(a.moveMode, ['energy','time','unknown'] as const), moveMinutes: number(a.moveMinutes), moveGoalMinutes: number(a.moveGoalMinutes) },
    heartRate: { status: sectionStatus(hr.status), bpm: number(hr.bpm), measuredAt: date(hr.measuredAt) },
    workout: { status: sectionStatus(w.status), kind: text(w.kind, 160), startedAt: date(w.startedAt), endedAt: date(w.endedAt),
      durationSeconds: number(w.durationSeconds), distanceMeters: number(w.distanceMeters), activeEnergyKcal: number(w.activeEnergyKcal) },
    warnings: obj.warnings.map(item => text(item, 600) ?? fail()),
  };
  const parts=new Intl.DateTimeFormat('en-CA',{timeZone:result.timeZone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(result.generatedAt));
  const datePart=(type:string)=>parts.find(part=>part.type===type)?.value;
  if (`${datePart('year')}-${datePart('month')}-${datePart('day')}`!==result.day) return fail();
  if (result.heartRate.bpm !== null && (result.heartRate.bpm <= 0 || !result.heartRate.measuredAt)) return fail();
  for (const section of [result.sleep, result.workout]) {
    if (section.startedAt && section.endedAt && Date.parse(section.endedAt) < Date.parse(section.startedAt)) return fail();
  }
  return result;
}
export function parseEnvelope(input: unknown): Envelope {
  const obj = object(input); const snapshot = parseSnapshot(obj.snapshot);
  if (snapshot.dataMode !== 'healthkit') throw new Error('服务返回了演示数据，已拒绝当作真实健康数据展示。');
  return { snapshot, receivedAt: date(obj.receivedAt, true)! };
}
export function normalizeOrigin(raw: string): string {
  let url: URL;
  try { url = new URL(raw.trim()); } catch { throw new Error('请输入完整服务地址，例如 https://health.example.com。'); }
  const host = url.hostname.toLowerCase();
  const octets = host.split('.').map(part => /^\d+$/.test(part) ? Number(part) : NaN);
  const ipv4 = octets.length === 4 && octets.every(part => Number.isInteger(part) && part >= 0 && part <= 255);
  const privateIP = ipv4 && (octets[0] === 127 || octets[0] === 10 || (octets[0] === 192 && octets[1] === 168) || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31));
  const local = host === 'localhost' || host === '[::1]' || host.endsWith('.local') || privateIP;
  if (url.username || url.password || url.hash || url.search || (url.pathname !== '/' && url.pathname !== '') || !['http:','https:'].includes(url.protocol) || (url.protocol === 'http:' && !local)) {
    throw new Error('请填写不带路径和密钥的 HTTPS 服务地址；HTTP 仅用于本机或局域网测试。');
  }
  return url.origin;
}
