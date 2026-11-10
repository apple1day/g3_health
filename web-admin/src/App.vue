<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import Trend from './Trend.vue';
import { request } from './api.mjs';
import { available, dailySeries, day, lastDays, minutes, move, number, percent, statusLabel, time } from './model.mjs';
const busy = ref(false), error = ref('');
const tab = ref('overview'), overview = ref(null), history = ref({ items: [], total: 0, page: 1, pageSize: 20 }), days = ref([]), detail = ref(null);
const filters = ref(lastDays()), applied = ref({ ...filters.value });
let controller, generation = 0;
const latest = computed(() => overview.value?.latest?.snapshot);
const currentDay = computed(() => latest.value?.day === day());
const age = computed(() => latest.value ? Math.max(0, (Date.now() - Date.parse(latest.value.generatedAt)) / 3600000) : 0);
const latestMove = computed(() => move(latest.value?.activity));
const stepSeries = computed(() => dailySeries(days.value, applied.value.from, applied.value.to, s => s.activity.status === 'ok' ? s.activity.steps : null));
const sleepSeries = computed(() => dailySeries(days.value, applied.value.from, applied.value.to, s => s.sleep.status === 'ok' ? s.sleep.totalMinutes : null));
const sleepStages = computed(() => latest.value ? [
 { label: '核心', value: latest.value.sleep.coreMinutes, color: '#6ea5d9' },
 { label: '深度', value: latest.value.sleep.deepMinutes, color: '#585ca8' },
 { label: 'REM', value: latest.value.sleep.remMinutes, color: '#aa91ce' },
 { label: '未分类', value: latest.value.sleep.unspecifiedMinutes, color: '#bfc8d5' },
] : []);
function validatedRange() {
 const { from, to } = filters.value;
 if (!from || !to || from > to || !Number.isFinite(Date.parse(from)) || !Number.isFinite(Date.parse(to)) || Date.parse(to) - Date.parse(from) > 365 * 86400000) {
  throw new Error('请选择有效的起止日期，范围不超过 366 天。');
 }
 return { from, to };
}
async function refresh(page = 1) {
 let range;
 try { range = validatedRange(); } catch (e) { error.value = e.message; return; }
 const g = ++generation; controller?.abort(); controller = new AbortController(); busy.value = true; error.value = '';
 const query = new URLSearchParams({ ...range, page: String(page), pageSize: '20' });
 try {
  const [o, h, d] = await Promise.all([
   request('/api/admin/overview', controller.signal),
   request(`/api/admin/snapshots?${query}`, controller.signal),
   request(`/api/admin/days?${query}`, controller.signal),
  ]);
  if (g !== generation) return;
  overview.value = o; history.value = h; days.value = d.items; applied.value = range; detail.value = null;
 } catch (e) { if (e.name !== 'AbortError' && g === generation) { error.value = e.message; } }
 finally { if (g === generation) busy.value = false; }
}
function preset(n) { filters.value = lastDays(n); refresh(); }
function chooseTab(value) { tab.value = value; }
onMounted(() => { void refresh(); });
onBeforeUnmount(() => { generation++; controller?.abort(); });
</script>
<template>
 <div class="app-layout">
  <aside class="sidebar">
   <div class="brand"><span class="brand-mark">＋</span><span>健康速览<small>HEALTH GLANCE</small></span></div>
   <span class="nav-caption">个人数据空间</span>
   <nav aria-label="主导航">
    <button :class="{ active: tab === 'overview' }" @click="chooseTab('overview')"><span>◫</span> 数据总览</button>
    <button :class="{ active: tab === 'history' }" @click="chooseTab('history')"><span>◷</span> 上传历史</button>
    <button :class="{ active: tab === 'guide' }" @click="chooseTab('guide')"><span>ⓘ</span> 接入说明</button>
   </nav>
   <div class="sidebar-bottom"><span class="dot"></span> Gin + MySQL <p>免登录 · 可信局域网专用</p></div>
  </aside>
  <main>
   <header class="page-header"><div><span class="eyebrow">HEALTH DATA / {{ tab === 'overview' ? 'OVERVIEW' : tab === 'history' ? 'HISTORY' : 'CONNECTION' }}</span><h1>{{ { overview: '健康数据总览', history: '上传历史', guide: '接入与同步说明' }[tab] }}</h1><p class="subtle">{{ tab === 'overview' ? '所有指标来自已上传的 HealthKit 摘要，不是实时测量。' : tab === 'history' ? '保留每次有效上传，重复重试不会产生新记录。' : '仅需服务地址，健康数据由 iPhone 主动同步。' }}</p></div><button class="secondary" :disabled="busy" @click="refresh(history.page)">{{ busy ? '刷新中…' : '↻ 刷新数据' }}</button></header>
   <div class="notice local-mode-notice" role="note">局域网免登录模式：能访问此服务的人均可查看、上传或删除健康数据。请勿开放公网访问。</div>
   <div v-if="error" class="error banner" role="alert">{{ error }}<span>页面可能保留上一次查询的结果，请核对时间。</span></div>
   <div v-if="tab !== 'guide'" class="filter-bar"><div class="date-controls"><label>日期范围 <input aria-label="开始日期" type="date" v-model="filters.from" /></label><span>—</span><input aria-label="结束日期" type="date" v-model="filters.to" /><button class="small-button" :disabled="busy" @click="refresh()">查询</button><button class="text-button" :disabled="busy" @click="preset(7)">近 7 天</button><button class="text-button" :disabled="busy" @click="preset(30)">近 30 天</button></div><span class="filter-note">按 iPhone 本地日期筛选 · 时间显示为浏览器本地时区</span></div>
   <template v-if="tab === 'overview'">
    <div class="summary-strip"><span><i class="dot"></i> 已保存 <strong>{{ number(overview?.snapshotCount) }}</strong> 份摘要</span><span><strong>{{ number(overview?.dayCount) }}</strong> 个日期有上传</span><span>最新接收 {{ time(overview?.latest?.receivedAt) }}</span></div>
    <section v-if="!latest" class="panel empty-state"><span class="empty-symbol">↥</span><h2>等待第一份健康摘要</h2><p>在 iPhone 的「设置与同步」中仅填写服务地址，<br>保存后回到首页，手动上传一次真实数据。</p><button class="secondary" @click="tab = 'guide'">查看接入说明</button></section>
    <template v-else>
     <div class="section-heading"><h2>最近一份摘要 <span>{{ latest.day }}</span></h2><span class="tag" :class="{ warning: !currentDay || age > 6 }">{{ !currentDay ? '非今日数据' : age > 6 ? '超过 6 小时未更新' : '已上传记录' }}</span></div>
     <p class="subtle sample-time">手机生成 {{ time(latest.generatedAt) }} · 手机时区 {{ latest.timeZone }} · 下方卡片不受历史日期筛选影响</p>
     <div class="metric-grid">
      <article class="metric sleep"><span class="metric-label"><span class="metric-icon">☾</span> 睡眠总时长</span><strong>{{ minutes(latest.sleep.totalMinutes) }}</strong><span class="subtle">{{ statusLabel(latest.sleep.status) }} · 不含清醒时段</span></article>
      <article class="metric"><span class="metric-label"><span class="metric-icon">↟</span> 当日步数</span><strong>{{ number(latest.activity.steps) }} <small>步</small></strong><span class="subtle">{{ latest.day }} · {{ number(available(latest.activity.distanceMeters) ? latest.activity.distanceMeters / 1000 : null, 2) }} 公里</span></article>
      <article class="metric energy"><span class="metric-label"><span class="metric-icon">ϟ</span> 活动能量</span><strong>{{ number(latest.activity.activeEnergyKcal) }} <small>千卡</small></strong><span class="subtle">{{ statusLabel(latest.activity.status) }} · 已有累计记录</span></article>
      <article class="metric heart"><span class="metric-label"><span class="metric-icon">♡</span> 最近心率</span><strong>{{ number(latest.heartRate.bpm) }} <small>次/分</small></strong><span class="subtle">测量于 {{ time(latest.heartRate.measuredAt) }}</span></article>
     </div>
     <div class="two-columns">
      <section class="panel"><div class="panel-head"><h3>睡眠结构</h3><span class="tag">{{ statusLabel(latest.sleep.status) }}</span></div><p class="subtle">{{ time(latest.sleep.startedAt) }} — {{ time(latest.sleep.endedAt) }}</p><div class="sleep-bar" aria-label="睡眠分期时长"><span v-for="stage in sleepStages" :key="stage.label" :style="{ background: stage.color, flexGrow: stage.value ?? 0 }"></span></div><div class="stage-grid"><div v-for="stage in sleepStages" :key="stage.label"><span class="stage-label"><i :style="{ background: stage.color }"></i>{{ stage.label }}</span><strong>{{ number(stage.value) }}<small> 分</small></strong></div></div><p class="panel-foot">清醒 {{ number(latest.sleep.awakeMinutes) }} 分钟 · 来源：{{ latest.sleep.sourceName || '暂无可读取来源' }}</p></section>
      <section class="panel"><div class="panel-head"><h3>活动目标</h3><span class="tag">系统目标</span></div><div v-for="ring in [latestMove, { label: '锻炼', value: latest.activity.exerciseMinutes, goal: latest.activity.exerciseGoalMinutes, unit: '分钟' }, { label: '站立达标', value: latest.activity.standHours, goal: latest.activity.standGoalHours, unit: '小时段' }]" :key="ring.label" class="ring-row"><div><span>{{ ring.label }}</span><strong>{{ number(ring.value) }} <small>/ {{ number(ring.goal) }} {{ ring.unit }}</small></strong></div><div class="progress"><span :style="{ width: `${percent(ring.value, ring.goal) ?? 0}%` }"></span></div><small v-if="percent(ring.value, ring.goal) === null" class="subtle">暂无可计算的目标完成度</small></div></section>
     </div>
     <section class="panel workout"><div><span class="eyebrow">LATEST COMPLETED WORKOUT</span><h3>{{ latest.workout.kind || '暂无可读取的运动' }}</h3><p class="subtle">{{ time(latest.workout.startedAt) }} · 最近一次已完成运动，不一定发生在今天</p></div><div class="workout-metrics"><span><strong>{{ minutes(available(latest.workout.durationSeconds) ? latest.workout.durationSeconds / 60 : null) }}</strong><small>持续时间</small></span><span><strong>{{ number(available(latest.workout.distanceMeters) ? latest.workout.distanceMeters / 1000 : null, 2) }} km</strong><small>运动距离</small></span><span><strong>{{ number(latest.workout.activeEnergyKcal) }} kcal</strong><small>活动能量</small></span></div></section>
     <div v-if="latest.warnings.length" class="notice"><strong>同步提示</strong><p v-for="(w, i) in latest.warnings" :key="i">{{ w }}</p></div>
    </template>
    <div class="section-heading"><h2>按天趋势</h2><span class="subtle">{{ applied.from }} 至 {{ applied.to }} · 不累加重复上传</span></div>
    <div class="two-columns"><Trend title="步数变化" unit="步" :series="stepSeries" /><Trend title="睡眠时长" unit="分钟" :series="sleepSeries" tone="purple" /></div>
    <section class="panel compact-table"><div class="panel-head"><h3>每日最后一份记录</h3><span class="subtle">无上传或无权限的指标显示「—」</span></div><div class="table-scroll"><table><thead><tr><th>手机日期</th><th>步数</th><th>睡眠</th><th>活动能量</th><th>生成时间</th></tr></thead><tbody><tr v-for="r in days" :key="r.id"><td>{{ r.snapshot.day }}</td><td>{{ number(r.snapshot.activity.steps) }}</td><td>{{ minutes(r.snapshot.sleep.totalMinutes) }}</td><td>{{ number(r.snapshot.activity.activeEnergyKcal) }} kcal</td><td>{{ time(r.snapshot.generatedAt) }}</td></tr><tr v-if="!days.length"><td colspan="5" class="table-empty">日期范围内暂无摘要</td></tr></tbody></table></div></section>
   </template>
   <template v-else-if="tab === 'history'">
    <section class="panel history-panel"><div class="panel-head"><h3>上传记录 <span class="tag">{{ number(history.total) }} 条</span></h3><span class="subtle">第 {{ history.page }} 页</span></div><div class="table-scroll"><table><thead><tr><th>日期 / 手机时区</th><th>手机生成时间</th><th>服务接收时间</th><th>步数</th><th>睡眠</th><th>详情</th></tr></thead><tbody><tr v-for="r in history.items" :key="r.id"><td>{{ r.snapshot.day }}<small class="cell-subtle">{{ r.snapshot.timeZone }}</small></td><td>{{ time(r.snapshot.generatedAt) }}</td><td>{{ time(r.receivedAt) }}</td><td>{{ number(r.snapshot.activity.steps) }}</td><td>{{ minutes(r.snapshot.sleep.totalMinutes) }}</td><td><button class="text-button" @click="detail = r">查看</button></td></tr><tr v-if="!history.items.length"><td colspan="6" class="table-empty">这个日期范围没有上传记录。</td></tr></tbody></table></div><div class="pagination"><span>每页 {{ history.pageSize }} 条</span><button class="secondary" :disabled="busy || history.page <= 1" @click="refresh(history.page-1)">上一页</button><button class="secondary" :disabled="busy || history.page * history.pageSize >= history.total" @click="refresh(history.page+1)">下一页</button></div></section>
   </template>
   <template v-else>
    <section class="panel guide"><h2>只填地址，即可同步</h2><div class="guide-step"><b>01</b><div><h3>iPhone 保存服务地址</h3><p>填写 Mac 的局域网地址，例如 <code>http://192.168.19.152:8787</code>。不需要 Token、账号或密码。</p><p>保存后回首页读取并上传真实摘要；保存配置本身不会上传健康数据。</p></div></div><div class="guide-step"><b>02</b><div><h3>眼镜连接同一服务</h3><p>Even 插件也只填写相同地址。网络白名单与 CORS 仍需允许插件访问。</p></div></div><div class="guide-step"><b>03</b><div><h3>后台直接查看</h3><p>打开 /admin/ 自动加载总览，刷新页面无需重新登录。此版本没有身份验证，仅适合可信局域网；后续账号密码功能尚未实现。</p></div></div></section>
    <section class="notice"><h3>数据范围与隐私</h3><p>这是单用户个人数据库，不是多用户医疗系统。只保存 iPhone 上传的摘要，不会主动从苹果服务器抓取数据；无法补齐未上传日期或所有逐条心率/运动原始记录。</p><p>按天图表取当天最后一份摘要，多个上传的步数、能量和睡眠时长不会相加。睡眠按原有跨夜口径，可能包含小睡；无数据不等于零。</p><p>iPhone 的删除服务器数据操作会删除 MySQL 中全部摘要历史。不要将免登录服务暴露公网；HTTPS 不会增加身份认证。请使用受限数据库账号并保护备份。</p></section>
   </template>
   <footer class="page-footer">健康速览 / PERSONAL HEALTH DATA <span>仅展示已有记录，不提供医学诊断。</span></footer>
  </main>
  <div v-if="detail" class="dialog-backdrop" @click.self="detail = null" @keydown.esc="detail = null"><section class="detail-dialog" role="dialog" aria-modal="true" aria-labelledby="detail-title" tabindex="-1"><div class="panel-head"><h2 id="detail-title">摘要详情 #{{ detail.id }}</h2><button class="secondary" @click="detail = null">关闭</button></div><p class="subtle">接收于 {{ time(detail.receivedAt) }} · 不含访问令牌</p><pre>{{ JSON.stringify(detail.snapshot, null, 2) }}</pre></section></div>
 </div>
</template>
