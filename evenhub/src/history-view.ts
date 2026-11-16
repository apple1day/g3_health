import './history.css';
import { fetchHistoryPage, fetchHistoryStatus } from './history-api';
import { HISTORY_KINDS, HISTORY_LABELS, validateHistoryFilter, type HistoryFilter, type HistoryKind, type HistoryPage, type HistoryRow, type HistorySource, type HistoryStatus } from './history';
import { historyContent, recordDate, recordLabel, recordValue } from './history-presentation';
import { normalizeOrigin } from './model';
import type { GlassContent } from './presentation';

/** Only static application copy enters this template. Server values use textContent. */
export const HISTORY_MARKUP = `
<section id="history-panel" class="history-panel" aria-labelledby="history-heading" hidden>
  <div class="section-heading"><div><p class="eyebrow">YOUR HEALTH ARCHIVE</p><h2 id="history-heading">已同步的历史记录</h2></div><span id="history-count">尚未读取</span></div>
  <p class="history-intro">按类型、来源和日期查找，点选一条记录即可在眼镜上查看。这里显示原始记录，不把多来源样本相加。</p>
  <form id="history-filter" class="history-filter">
    <div><label for="history-kind">记录类型</label><select id="history-kind"><option value="">全部类型</option>${HISTORY_KINDS.map(kind => `<option value="${kind}"${kind === 'sleep' ? ' selected' : ''}>${HISTORY_LABELS[kind]}</option>`).join('')}</select></div>
    <div><label for="history-source">历史记录来源</label><select id="history-source"><option value="">全部来源</option></select></div>
    <div><label for="history-from">历史开始日期</label><input id="history-from" type="date"></div>
    <div><label for="history-to">历史结束日期</label><input id="history-to" type="date"></div>
    <div class="history-filter-actions"><button id="history-refresh" class="secondary-button" type="submit">读取历史</button><button id="history-all-dates" class="text-button" type="button">全部日期</button></div>
  </form>
  <p class="history-date-note">日期按每条记录的开始时间及其时区筛选。睡眠分段不等于整夜总时长，卧床和清醒也可能出现在记录中。</p>
  <div id="history-status" class="history-status" role="status" aria-live="polite">填写服务地址后，可单独读取已同步的历史。</div>
  <p id="history-overview" class="history-overview" hidden></p>
  <div id="history-coverage" class="history-coverage" hidden></div>
  <div id="history-records" class="history-record-list" aria-label="历史记录列表"></div>
  <div class="history-pagination"><button id="history-newer" class="secondary-button" type="button" disabled>较新一页</button><span id="history-page">每页最多 50 条</span><button id="history-older" class="secondary-button" type="button" disabled>更早一页</button></div>
  <p class="history-help">没有看到旧记录？在 iPhone 的「历史 → 全部记录与同步」中开始或继续同步。OPPO 等来源须先实际共享到 Apple 健康，再上传到此服务。归档条数不代表全部历史已同步完成。</p>
</section>`;

type Options = { origin: () => string; onChange: () => void; onConnected: (origin: string) => void };
const element = <T extends HTMLElement = HTMLElement>(id: string): T => document.getElementById(id) as T;
const errorText = (error: unknown): string => error instanceof Error ? error.message : '历史读取未完成，请重试。';
const defaultFilter = (): HistoryFilter => ({ kind:'sleep', from:'', to:'', sourceID:'' });

export class HistoryView {
  private filter = defaultFilter();
  private page: HistoryPage | null = null;
  private status: HistoryStatus | null = null;
  private knownEpoch: string | null = null;
  private sources: HistorySource[] = [];
  private selectedID: number | null = null;
  private trail = [''];
  private index = 0;
  private demo = false;
  private busy = false;
  private cached = false;
  private error = '';
  private statusError = '';
  private generation = 0;
  private abort: AbortController | null = null;
  private origin = '';
  private paintedPage: HistoryPage | null | undefined;
  private paintedDemo: boolean | undefined;
  private paintedSources: HistorySource[] | null = null;
  private paintedSourceID: string | undefined;
  private readonly kind = element<HTMLSelectElement>('history-kind');
  private readonly source = element<HTMLSelectElement>('history-source');
  private readonly from = element<HTMLInputElement>('history-from');
  private readonly to = element<HTMLInputElement>('history-to');

  constructor(private readonly options: Options) {
    element<HTMLFormElement>('history-filter').addEventListener('submit', event => { event.preventDefault(); this.readFilters(); void this.refresh(); });
    for (const input of [this.kind, this.source]) input.addEventListener('change', () => { this.readFilters(); void this.refresh(); });
    // Invalidate old results as soon as a date is edited, before its change/submit event.
    for (const input of [this.from, this.to]) {
      input.addEventListener('input', () => this.readFilters());
      input.addEventListener('change', () => { this.readFilters(); void this.refresh(); });
    }
    element('history-all-dates').addEventListener('click', () => { this.from.value = ''; this.to.value = ''; this.readFilters(); void this.refresh(); });
    element('history-newer').addEventListener('click', () => { if (!this.busy && this.index > 0) void this.load(this.index - 1, this.trail); });
    element('history-older').addEventListener('click', () => {
      if (!this.busy && this.page?.nextCursor) void this.load(this.index + 1, [...this.trail.slice(0, this.index + 1), this.page.nextCursor]);
    });
    this.paint();
  }

  get content(): GlassContent {
    return historyContent(this.demo ? null : this.selected, {
      demo:this.demo, busy:this.busy, cached:this.cached, error:this.error || undefined,
      total:this.demo ? undefined : this.page?.total,
    });
  }
  get label(): string { return this.demo ? '演示数据' : this.page ? this.cached ? '缓存记录' : '真实记录' : '等待历史'; }
  get mode(): 'empty' | 'healthkit' | 'demo' { return this.demo ? 'demo' : this.page ? 'healthkit' : 'empty'; }
  private get selected(): HistoryRow | null { return this.page?.items.find(row => row.rowID === this.selectedID) ?? null; }

  activate(): void {
    if (!this.demo && !this.page && !this.busy && this.options.origin()) void this.refresh();
  }

  async refresh(): Promise<void> {
    if (this.demo) { this.changed(); return; }
    this.readFilters();
    await this.load(0, ['']);
  }

  reset(): void {
    this.cancel();
    this.clearData();
    this.filter = defaultFilter();
    this.kind.value = 'sleep'; this.source.value = ''; this.from.value = ''; this.to.value = '';
    this.origin = ''; this.knownEpoch = null;
    this.changed();
  }

  setDemo(value: boolean): void {
    if (this.demo === value) return;
    this.cancel();
    this.demo = value; this.knownEpoch = null;
    this.clearData();
    this.filter.sourceID = '';
    this.changed();
  }

  private cancel(): void {
    this.generation++;
    this.abort?.abort(); this.abort = null; this.busy = false;
  }

  private clearData(keepSources = false): void {
    this.page = null; this.selectedID = null; this.status = null;
    this.cached = false; this.error = ''; this.statusError = '';
    this.trail = ['']; this.index = 0;
    if (!keepSources) this.sources = [];
  }

  private readFilters(): void {
    const next: HistoryFilter = { kind:this.kind.value as HistoryKind | '', sourceID:this.source.value, from:this.from.value, to:this.to.value };
    if (next.kind === this.filter.kind && next.sourceID === this.filter.sourceID && next.from === this.filter.from && next.to === this.filter.to) return;
    const keepSources = next.kind === this.filter.kind && next.from === this.filter.from && next.to === this.filter.to;
    this.cancel(); this.clearData(keepSources); this.filter = next; this.changed();
  }

  private async load(index: number, trail: string[], restartedForEpoch = false): Promise<void> {
    if (this.demo) return;
    let origin: string;
    const filter = { ...this.filter, cursor:trail[index] };
    try { origin = normalizeOrigin(this.options.origin()); validateHistoryFilter(filter); }
    catch (error) { this.error = errorText(error); this.cached = Boolean(this.page); this.changed(); return; }
    // Defensive isolation if the host changes the address without firing an input event.
    if (this.origin && this.origin !== origin) {
      this.cancel(); this.clearData(); this.filter.sourceID = ''; this.source.value = '';
      this.origin = origin; this.knownEpoch = null; this.changed(); await this.refresh(); return;
    }
    this.cancel(); this.origin = origin; this.busy = true; this.error = ''; this.statusError = '';
    const generation = this.generation;
    const controller = new AbortController(); this.abort = controller;
    const timeout = window.setTimeout(() => controller.abort(), 15_000);
    this.changed();
    try {
      const [records, status] = await Promise.allSettled([
        fetchHistoryPage(origin, filter, controller.signal), fetchHistoryStatus(origin, controller.signal),
      ]);
      if (generation !== this.generation) return;
      if (status.status === 'fulfilled') {
        const epochChanged = this.knownEpoch !== null && this.knownEpoch !== status.value.epoch;
        this.knownEpoch = status.value.epoch;
        if (epochChanged) {
          // The list and status requests are not atomic. Discard even a first-page
          // response that may have crossed a reset, and never reuse its cursor.
          this.cancel(); this.clearData(); this.status = status.value;
          if (restartedForEpoch) {
            this.error = '历史在读取期间再次重置，请稍后重新读取。';
            this.changed(); return;
          }
          this.changed();
          await this.load(0, [''], true);
          return;
        }
        this.status = status.value;
      } else { this.status = null; this.statusError = '归档概览暂不可用，记录列表可单独读取。'; }
      if (records.status === 'rejected') throw records.reason;
      const result = records.value;
      // Older backends may ignore sourceID; never present their unfiltered rows as a selected source.
      if (filter.sourceID && result.items.some(row => row.sample.sourceID !== filter.sourceID)) {
        throw new Error('后台未正确筛选来源，请升级到 0.5.0 或更新版本后重试。');
      }
      this.page = result; this.sources = result.sources;
      this.selectedID = result.items.some(row => row.rowID === this.selectedID) ? this.selectedID : result.items[0]?.rowID ?? null;
      this.index = index; this.trail = trail.slice(0, index + 1); this.cached = false;
      this.options.onConnected(origin);
    } catch (error) {
      if (generation !== this.generation) return;
      this.error = errorText(error); this.cached = Boolean(this.page);
    } finally {
      window.clearTimeout(timeout);
      if (generation === this.generation) { this.abort = null; this.busy = false; this.changed(); }
    }
  }

  private changed(): void { this.paint(); this.options.onChange(); }

  private paint(): void {
    element('history-count').textContent = this.demo ? '演示模式' : this.page ? `${this.page.total.toLocaleString('zh-CN')} 条原始记录${this.cached ? ' · 缓存' : ''}` : '尚未读取';
    const message = element('history-status');
    message.dataset.kind = this.error ? 'error' : this.page ? 'success' : 'info';
    message.textContent = this.demo ? '演示模式不读取个人历史，请退出演示后连接。'
      : this.busy ? '正在读取历史记录…'
      : this.error ? this.error + (this.page ? ' 当前保留上次成功读取的本页记录（缓存）。' : '')
      : this.page ? this.page.items.length ? '已读取原始记录。点选一条可在眼镜查看。' : '尚无匹配记录。请核对筛选条件，或在 iPhone 同步全部历史。'
      : '填写服务地址后，可单独读取已同步的历史。';
    const overview = element('history-overview');
    overview.hidden = this.demo || (!this.status && !this.statusError);
    overview.textContent = this.status ? `服务共归档 ${this.status.count.toLocaleString('zh-CN')} 条原始记录${this.status.earliest && this.status.latest ? ` · 覆盖 ${recordDate(this.status.earliest, 'UTC')} — ${recordDate(this.status.latest, 'UTC')}（UTC）` : ''}` : this.statusError;
    for (const input of [this.kind, this.source, this.from, this.to]) input.disabled = this.demo;
    element<HTMLButtonElement>('history-refresh').disabled = this.busy || this.demo;
    element('history-refresh').textContent = this.busy ? '读取中…' : '读取历史';
    element<HTMLButtonElement>('history-all-dates').disabled = this.demo;
    this.paintSources(); this.paintCoverage(); this.paintRows();
    element<HTMLButtonElement>('history-newer').disabled = this.demo || this.busy || !this.page || this.index === 0;
    element<HTMLButtonElement>('history-older').disabled = this.demo || this.busy || !this.page?.nextCursor;
    element('history-page').textContent = this.page && !this.demo ? `第 ${this.index + 1} 页 · 本页 ${this.page.items.length} 条` : '每页最多 50 条';
  }

  private paintSources(): void {
    if (this.paintedSources === this.sources && this.paintedSourceID === this.filter.sourceID) return;
    this.paintedSources = this.sources; this.paintedSourceID = this.filter.sourceID;
    const all = document.createElement('option'); all.value = ''; all.textContent = '全部来源';
    const options = this.sources.map(source => {
      const option = document.createElement('option'); option.value = source.sourceID;
      const duplicateName = this.sources.some(other => other.sourceID !== source.sourceID && other.sourceName === source.sourceName);
      option.textContent = `${source.sourceName} · ${source.count.toLocaleString('zh-CN')} 条${duplicateName ? `（${source.sourceID}）` : ''}`;
      return option;
    });
    if (this.filter.sourceID && !this.sources.some(source => source.sourceID === this.filter.sourceID)) {
      const selected = document.createElement('option'); selected.value = this.filter.sourceID; selected.textContent = '当前来源（此范围无记录）'; options.push(selected);
    }
    this.source.replaceChildren(all, ...options); this.source.value = this.filter.sourceID;
  }

  private paintCoverage(): void {
    const coverage = element('history-coverage');
    coverage.hidden = this.demo || !this.page;
    if (coverage.hidden) { coverage.replaceChildren(); return; }
    const sources = this.filter.sourceID ? this.sources.filter(source => source.sourceID === this.filter.sourceID) : this.sources;
    const note = document.createElement('p');
    note.textContent = this.sources.length ? '来源覆盖整个类型 / 日期筛选范围，条数不是睡眠夜数。覆盖时间统一按 UTC 显示。' : this.page!.total > 0 ? '后台未提供来源统计。可浏览原始记录；来源筛选和覆盖范围需要 0.5.0 或更新后台。' : '此筛选范围暂无来源记录。';
    const entries = sources.map(source => {
      const line = document.createElement('p');
      line.textContent = `${source.sourceName} · ${source.count.toLocaleString('zh-CN')} 条原始记录 · ${recordDate(source.earliest, 'UTC')} — ${recordDate(source.latest, 'UTC')}`;
      return line;
    });
    coverage.replaceChildren(note, ...entries);
  }

  private paintRows(): void {
    const list = element('history-records');
    if (this.paintedPage !== this.page || this.paintedDemo !== this.demo) {
      this.paintedPage = this.page; this.paintedDemo = this.demo;
      const buttons = this.demo ? [] : (this.page?.items ?? []).map(row => {
        const button = document.createElement('button'); button.type = 'button'; button.className = 'history-record'; button.dataset.rowId = String(row.rowID);
        const value = document.createElement('strong'); value.textContent = `${recordLabel(row.sample)} · ${recordValue(row.sample)}`;
        const dates = document.createElement('span'); dates.textContent = `${recordDate(row.sample.startedAt, row.sample.timeZone)} — ${recordDate(row.sample.endedAt, row.sample.timeZone)}`;
        const source = document.createElement('span'); source.textContent = `${row.sample.sourceName} · ${row.sample.timeZone}${row.sample.device ? ` · ${row.sample.device}` : ''}`;
        button.append(value, dates, source);
        button.addEventListener('click', () => { this.selectedID = row.rowID; this.changed(); });
        return button;
      });
      list.replaceChildren(...buttons);
    }
    for (const button of list.querySelectorAll<HTMLButtonElement>('button[data-row-id]')) {
      button.setAttribute('aria-pressed', String(Number(button.dataset.rowId) === this.selectedID));
    }
  }
}
