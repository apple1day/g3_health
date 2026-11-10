<script setup>
import { computed } from 'vue';
import { available, number, sparkPaths } from './model.mjs';
const props = defineProps({ title: String, unit: String, series: Array, tone: { default: 'green' } });
const values = computed(() => props.series.map(p => p.value));
const paths = computed(() => sparkPaths(values.value));
const known = computed(() => values.value.filter(available));
</script>
<template>
 <section class="panel trend" :class="tone">
  <div class="panel-head"><h3>{{ title }}</h3><span class="tag">{{ known.length }} 天有记录</span></div>
  <p class="subtle">{{ unit }} · 每天最后一份摘要</p>
  <div class="chart" v-if="known.length">
   <span class="chart-max">{{ number(Math.max(...known), 1) }}</span>
   <svg viewBox="0 0 560 140" role="img" :aria-label="`${title}趋势，缺失数据不按零统计`">
    <path d="M8 35 H552 M8 80 H552 M8 132 H552" class="grid-line" />
    <path v-for="(p, index) in paths" :key="index" :d="p" class="trend-line" />
    <circle v-for="(v, index) in values" :key="`dot-${index}`" v-show="available(v)" :cx="8+index*544/Math.max(values.length-1,1)" :cy="132-(v ?? 0)/Math.max(1,...known)*124" r="3.5" class="trend-dot" />
   </svg>
   <div class="chart-labels"><span>{{ series[0]?.day }}</span><span>{{ series.at(-1)?.day }}</span></div>
  </div>
  <div v-else class="chart-empty">这个日期范围还没有可用记录</div>
 </section>
</template>
