<script setup>
import { computed, onMounted, onBeforeUnmount, ref } from 'vue';
import { request } from './api.mjs';
import { number, time } from './model.mjs';
import { historyQuery, historyScope } from './history-query.mjs';
const kinds = { sleep: '睡眠阶段', workout: '运动记录', activitySummary: '每日活动三环', steps: '步数样本', distance: '距离样本', activeEnergy: '活动能量', exercise: '锻炼时间', heartRate: '心率样本' };
const kind = ref('sleep'), from = ref(''), to = ref(''), rows = ref([]), status = ref(null), total = ref(0), next = ref(''), busy = ref(false), error = ref(''), detail = ref(null);
const sourceID = ref(''), sources = ref([]), sourceScope = ref('');
const visibleSources = computed(() => sourceScope.value === historyScope({ kind: kind.value, from: from.value, to: to.value }) ? sources.value : []);
const selectedSource = computed(() => visibleSources.value.find(s => s.sourceID === sourceID.value));
let controller, generation = 0, applied = '';
async function load(more = false) {
 const filters = { kind: kind.value, from: from.value, to: to.value, sourceID: sourceID.value };
 const scope = historyScope(filters);
 if (more && (busy.value || !next.value || applied !== scope)) return;
 if (from.value && to.value && from.value > to.value) { error.value = '开始日期不能晚于结束日期。'; return; }
 const g = ++generation; controller?.abort(); controller = new AbortController(); busy.value = true; error.value = ''; detail.value = null;
 const cursor = more ? next.value : '';
 if (!more) { rows.value = []; next.value = ''; total.value = 0; }
 try {
  const q = historyQuery(filters, cursor);
  const [s, p] = await Promise.all([request('/api/admin/records/status', controller.signal), request(`/api/admin/records?${q}`, controller.signal)]);
  if (g !== generation) return;
  status.value = s; rows.value = more ? [...rows.value, ...p.items] : p.items; total.value = p.total; next.value = p.nextCursor; sources.value = p.sources || []; sourceScope.value = historyScope({ ...filters, sourceID: '' }); applied = scope;
 } catch (e) { if (e.name !== 'AbortError' && g === generation) error.value = e.message; }
 finally { if (g === generation) busy.value = false; }
}
function allDates() { from.value = ''; to.value = ''; load(); }
function allSources() { sourceID.value = ''; load(); }
function display(s) {
 if (s.kind === 'activitySummary') return `活动 ${number(s.metrics.activeEnergyKcal)} kcal / 锻炼 ${number(s.metrics.exerciseMinutes)} 分 / 站立 ${number(s.metrics.standHours)} 小时段`;
 return `${number(s.value, 2)} ${{ min: '分钟', s: '秒', count: '步', m: '米', kcal: '千卡', bpm: '次/分' }[s.unit] || s.unit}`;
}
onMounted(() => load());
onBeforeUnmount(() => { generation++; controller?.abort(); });
</script>
<template>
 <section aria-label="HealthKit 全量历史" class="records-view">
  <div class="section-heading"><div><h2>HealthKit 历史归档</h2><p class="subtle">这里是原始记录，不是旧版的“当天摘要上传历史”。默认查询所有已同步日期。</p></div><button class="secondary" :disabled="busy" @click="load()">刷新历史</button></div>
  <div class="summary-strip"><span>已归档 <strong data-testid="record-count">{{ number(status?.count) }}</strong> 条</span><span>最早记录 {{ time(status?.earliest) }}</span><span>最新记录 {{ time(status?.latest) }}</span></div>
  <div class="notice"><p>在 iPhone 首页点击「历史」→「全部记录与同步」→「开始 / 继续同步全部历史」。首次可读取当前授权范围内的全部历史，以后按新增和删除记录同步。后台不能主动读取 Apple 健康。</p><p>OPPO 健康等 App 先将记录共享到苹果健康，再由健康速览读取并同步。来源列表只反映已归档的实际记录；没有某个来源不代表该 App 或云端没有历史数据。</p><p>睡眠列表含卧床、清醒和各阶段；步数等可能来自手机、手表或第三方。<strong>不能直接累加原始样本作为每日总量。</strong>本机每日睡眠总时长及去重活动可在手机「本机按日查看」中查询；旧总览趋势仍表示已上传的每日摘要。</p></div>
  <div class="filter-bar"><div class="date-controls">
   <label>类型 <select aria-label="历史记录类型" v-model="kind" @change="load()"><option v-for="(label, key) in kinds" :value="key" :key="key">{{ label }}</option></select></label>
   <label>来源 <select aria-label="历史记录来源" v-model="sourceID" @change="load()">
    <option value="">全部来源</option>
    <option v-if="sourceID && !selectedSource" :value="sourceID">{{ sourceID }}（已选来源）</option>
    <option v-for="source in visibleSources" :key="source.sourceID" :value="source.sourceID">{{ source.sourceName }} · {{ number(source.count) }} 条 · {{ source.sourceID }}</option>
   </select></label>
   <label>开始 <input aria-label="历史开始日期" type="date" v-model="from" /></label>
   <label>结束 <input aria-label="历史结束日期" type="date" v-model="to" /></label>
   <button class="small-button" :disabled="busy" @click="load()">筛选记录</button>
   <button class="text-button" :disabled="busy" @click="allDates">全部日期</button>
   <button v-if="sourceID" class="text-button" :disabled="busy" @click="allSources">全部来源</button>
  </div></div>
  <div v-if="selectedSource && !busy && !error" class="source-summary" aria-label="所选来源覆盖范围">
   <strong>{{ selectedSource.sourceName }}</strong><code>{{ selectedSource.sourceID }}</code>
   <span>当前类型和日期范围内 {{ number(selectedSource.count) }} 条原始记录</span>
   <span>{{ time(selectedSource.earliest) }} — {{ time(selectedSource.latest) }}</span>
  </div>
  <p class="subtle">按样本开始日期筛选（优先记录时区，缺失时采用导入时手机时区）。时间显示为浏览器本地时区。</p>
  <div v-if="error" class="error banner" role="alert">{{ error }}</div>
  <section class="panel compact-table">
   <div class="panel-head"><h3>{{ kinds[kind] }} <span class="tag">{{ number(total) }} 条</span></h3><span class="subtle">已显示 {{ rows.length }} 条</span></div>
   <div class="table-scroll"><table><thead><tr><th>记录开始</th><th>结束</th><th>分类 / 数值</th><th>来源 / 时区</th><th>详情</th></tr></thead>
    <tbody><tr v-for="row in rows" :key="row.rowID"><td>{{ time(row.sample.startedAt) }}</td><td>{{ time(row.sample.endedAt) }}</td><td>{{ row.sample.label }}<small class="cell-subtle">{{ display(row.sample) }}</small></td><td>{{ row.sample.sourceName }}<small class="cell-subtle">{{ row.sample.device }} · {{ row.sample.timeZone }}</small></td><td><button class="text-button" @click="detail = row">记录详情</button></td></tr>
    <tr v-if="!rows.length"><td colspan="5" class="table-empty">{{ busy ? '正在读取历史…' : '尚无匹配的历史记录。请先在 iPhone 同步全部历史，并核对健康读取权限。' }}</td></tr></tbody>
   </table></div>
   <div class="pagination"><span>分批显示，每页 50 条，不限制总记录数。</span><button v-if="next" class="secondary" :disabled="busy" @click="load(true)">{{ busy ? '正在加载…' : '加载更早记录' }}</button></div>
  </section>
  <div v-if="detail" class="dialog-backdrop" @click.self="detail = null" @keydown.esc="detail = null"><section class="detail-dialog" role="dialog" aria-modal="true" aria-label="历史记录详情"><div class="panel-head"><h2>历史记录详情</h2><button class="secondary" @click="detail = null">关闭</button></div><p>服务器接收于 {{ time(detail.receivedAt) }}</p><pre>{{ JSON.stringify(detail.sample, null, 2) }}</pre></section></div>
 </section>
</template>
<style scoped>
select { background: white; border: 1px solid #d7dfdf; border-radius: 8px; padding: 8px; font: inherit; max-width: 100%; min-width: 0; }
.records-view { min-width: 0; }
.records-view .section-heading { align-items: flex-start; flex-wrap: wrap; gap: 16px; }
.records-view .notice { margin-bottom: 18px; }
.records-view .date-controls { flex-wrap: wrap; }
.records-view .date-controls label { min-width: 0; max-width: 100%; }
.source-summary { display: flex; flex-wrap: wrap; gap: 8px 16px; padding: 14px; margin: 0 0 12px; border: 1px solid #d7dfdf; border-radius: 10px; font-size: 14px; }
.source-summary code { overflow-wrap: anywhere; }
</style>
