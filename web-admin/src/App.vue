<script setup>
import { computed, onBeforeUnmount, ref } from 'vue';
import Trend from './Trend.vue';
import { request } from './api.mjs';
import { available, dailySeries, day, lastDays, minutes, move, number, percent, statusLabel, time } from './model.mjs';
const token = ref(''), draftToken = ref(''), authenticated = ref(false), busy = ref(false), error = ref('');
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
function logout() {
 generation++; controller?.abort(); token.value = ''; draftToken.value = ''; authenticated.value = false;
 overview.value = null; history.value = { items: [], total: 0, page: 1, pageSize: 20 }; days.value = []; detail.value = null; busy.value = false;
}
async function login() {
 const t = draftToken.value.trim();
 if (t.length < 32) { error.value = '请粘贴完整的管理令牌（ADMIN_TOKEN，至少 32 位）。'; return; }
 const g = ++generation; controller?.abort(); controller = new AbortController(); busy.value = true; error.value = '';
 try { await request('/api/admin/me', t, controller.signal); if (g !== generation) return;
  token.value = t; draftToken.value = ''; authenticated.value = true; await refresh();
 } catch (e) { if (e.name !== 'AbortError' && g === generation) error.value = e.message; }
 finally { if (g === generation) busy.value = false; }
}
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
   request('/api/admin/overview', token.value, controller.signal),
   request(`/api/admin/snapshots?${query}`, token.value, controller.signal),
   request(`/api/admin/days?${query}`, token.value, controller.signal),
  ]);
  if (g !== generation) return;
  overview.value = o; history.value = h; days.value = d.items; applied.value = range; detail.value = null;
 } catch (e) { if (e.name !== 'AbortError' && g === generation) { if (e.status === 401) logout(); error.value = e.message; } }
 finally { if (g === generation) busy.value = false; }
}
function preset(n) { filters.value = lastDays(n); refresh(); }
function chooseTab(value) { tab.value = value; }
onBeforeUnmount(() => { generation++; controller?.abort(); });
</script>
<template>
 <div v-if="!authenticated" class="login-page">
  <section class="login-story">
   <div class="brand"><span class="brand-mark">＋</span><span>健康速览 <small>HEALTH GLANCE</small></span></div>
   <div class="login-copy"><span class="eyebrow">YOUR HEALTH, IN ONE PLACE</span><h1>每一天的记录，<br>看得更清楚。</h1><p>从 iPhone 到个人数据库。<br>睡眠、活动与运动摘要，在这里安心查看。</p></div>
   <div class="login-foot"><span class="dot"></span> 单用户私有部署 · 只读管理后台</div>
  </section>
  <section class="login-form-wrap"><form class="login-form" @submit.prevent="login">
   <span class="eyebrow">WELCOME BACK</span><h2>登录数据后台</h2><p class="subtle">使用服务端生成的独立管理令牌。</p>
   <label for="admin-token">管理令牌 <span>ADMIN_TOKEN</span></label>
   <input id="admin-token" v-model="draftToken" type="password" autocomplete="off" placeholder="粘贴完整的管理令牌" spellcheck="false" required :disabled="busy" />
   <p v-if="error" class="error" role="alert">{{ error }}</p>
   <button class="primary login-button" :disabled="busy">{{ busy ? '正在验证…' : '进入管理后台 →' }}</button>
   <div class="login-help"><strong>在哪里获取令牌？</strong><p>在项目根目录运行：</p><code>bash copy-token.sh admin</code><p>然后粘贴到上方。这里不是 iPhone 的上传令牌。</p></div>
   <p class="privacy-note">令牌仅保存在当前页面内存，刷新或退出后需要重新登录。请勿分享令牌或包含健康数据的截图。</p>
  </form></section>
 </div>
 <div v-else class="app-layout">
  <aside class="sidebar">
   <div class="brand"><span class="brand-mark">＋</span><span>健康速览<small>HEALTH GLANCE</small></span></div>
   <span class="nav-caption">个人数据空间</span>
   <nav aria-label="主导航">
    <button :class="{ active: tab === 'overview' }" @click="chooseTab('overview')"><span>◫</span> 数据总览</button>
    <button :class="{ active: tab === 'history' }" @click="chooseTab('history')"><span>◷</span> 上传历史</button>
    <button :class="{ active: tab === 'guide' }" @click="chooseTab('guide')"><span>ⓘ</span> 接入说明</button>
   </nav>
   <div class="sidebar-bottom"><span class="dot"></span> Gin + MySQL <p>只读管理 · 本机私有配置</p><button class="logout" @click="logout">退出登录 ↗</button></div>
  </aside>
  <main>
   <header class="page-header"><div><span class="eyebrow">HEALTH DATA / {{ tab === 'overview' ? 'OVERVIEW' : tab === 'history' ? 'HISTORY' : 'CONNECTION' }}</span><h1>{{ { overview: '健康数据总览', history: '上传历史', guide: '接入与同步说明' }[tab] }}</h1><p class="subtle">{{ tab === 'overview' ? '所有指标来自已上传的 HealthKit 摘要，不是实时测量。' : tab === 'history' ? '保留每次有效上传，重复重试不会产生新记录。' : '三种令牌各司其职，健康数据由 iPhone 主动同步。' }}</p></div><button class="secondary" :disabled="busy" @click="refresh(history.page)">{{ busy ? '刷新中…' : '↻ 刷新数据' }}</button></header>
   <div v-if="error" class="error banner" role="alert">{{ error }}<span>页面可能保留上一次查询的结果，请核对时间。</span></div>
   <div v-if="tab !== 'guide'" class="filter-bar"><div class="date-controls"><label>日期范围 <input aria-label="开始日期" type="date" v-model="filters.from" /></label><span>—</span><input aria-label="结束日期" type="date" v-model="filters.to" /><button class="small-button" :disabled="busy" @click="refresh()">查询</button><button class="text-button" :disabled="busy" @click="preset(7)">近 7 天</button><button class="text-button" :disabled="busy" @click="preset(30)">近 30 天</button></div><span class="filter-note">按 iPhone 本地日期筛选 · 时间显示为浏览器本地时区</span></div>
   <template v-if="tab === 'overview'">
    <div class="summary-strip"><span><i class="dot"></i> 已保存 <strong>{{ number(overview?.snapshotCount) }}</strong> 份摘要</span><span><strong>{{ number(overview?.dayCount) }}</strong> 个日期有上传</span><span>最新接收 {{ time(overview?.latest?.receivedAt) }}</span></div>
    <section v-if="!latest" class="panel empty-state"><span class="empty-symbol">↥</span><h2>等待第一份健康摘要</h2><p>在 iPhone 的「设置与同步」中填入服务地址和 UPLOAD_TOKEN，<br>保存后回到首页，手动上传一次真实数据。</p><button class="secondary" @click="tab = 'guide'">查看接入说明</button></section>
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
    <section class="panel guide"><h2>先连接，再同步</h2><div class="guide-step"><b>01</b><div><h3>iPhone 使用上传令牌</h3><p>服务地址填写 Mac 的局域网地址，例如 <code>http://192.168.19.152:8787</code>，令牌填写 <code>UPLOAD_TOKEN</code> 的实际值。不要填写字段名称本身，也不要填 READ_TOKEN。</p><code>bash copy-token.sh upload</code><p>保存配置后，回首页读取并上传真实摘要；仅保存配置不会产生健康记录。</p></div></div><div class="guide-step"><b>02</b><div><h3>眼镜使用读取令牌</h3><p>Even 插件填写相同服务地址，以及 READ_TOKEN 的实际值。开发网络白名单与 CORS 都需要允许插件请求。</p><code>bash copy-token.sh read</code></div></div><div class="guide-step"><b>03</b><div><h3>后台只读查看</h3><p>后台使用独立 ADMIN_TOKEN，只读查看摘要与历史。令牌不存入浏览器持久存储，页面刷新后请重新登录。这里不会展示或修改其他令牌。</p></div></div></section>
    <section class="notice"><h3>数据范围与隐私</h3><p>这是单用户个人数据库，不是多用户医疗系统。只保存 iPhone 上传的摘要，不会主动从苹果服务器抓取数据；无法补齐未上传日期或所有逐条心率/运动原始记录。</p><p>按天图表取当天最后一份摘要，多个上传的步数、能量和睡眠时长不会相加。睡眠按原有跨夜口径，可能包含小睡；无数据不等于零。</p><p>iPhone 的删除服务器数据操作会删除 MySQL 中全部摘要历史。长期使用请配置 HTTPS、独立受限数据库账号及加密备份；HTTP 仅用于可信局域网测试。</p></section>
   </template>
   <footer class="page-footer">健康速览 / PERSONAL HEALTH DATA <span>仅展示已有记录，不提供医学诊断。</span></footer>
  </main>
  <div v-if="detail" class="dialog-backdrop" @click.self="detail = null" @keydown.esc="detail = null"><section class="detail-dialog" role="dialog" aria-modal="true" aria-labelledby="detail-title" tabindex="-1"><div class="panel-head"><h2 id="detail-title">摘要详情 #{{ detail.id }}</h2><button class="secondary" @click="detail = null">关闭</button></div><p class="subtle">接收于 {{ time(detail.receivedAt) }} · 不含访问令牌</p><pre>{{ JSON.stringify(detail.snapshot, null, 2) }}</pre></section></div>
 </div>
</template>
