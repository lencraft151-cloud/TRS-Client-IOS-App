<script setup lang="ts">
import { isTauri } from '@tauri-apps/api/core'
import { type CrashReport, crashReportKind, unseenReports } from '~/utils/crashReport'
// iOS: Neue Absturzberichte vom letzten Lauf zeigen – Teilen (iOS-Teilen-Menü) oder Kopieren. Alle Berichte liegen
// auch in der Dateien-App unter „TRS Launcher → Crash Reports“, selbst wenn die Oberfläche nie lädt.
const toasts = useToasts()
const reports = ref<CrashReport[]>([])
const index = ref(0)
const copied = ref(false)
const current = computed(() => reports.value[index.value] ?? null)

onMounted(async () => {
  if (!isTauri() || hostOs !== 'ios') return
  reports.value = unseenReports(await backend.crashReports.list().catch(() => []))
})

async function close() {
  const ids = reports.value.map((r) => r.id)
  reports.value = []
  index.value = 0
  await backend.crashReports.markSeen(ids).catch(() => {})
}

async function share() {
  if (current.value) await backend.crashReports.share(current.value.id).catch((e) => toasts.error(e))
}

async function copy() {
  if (!current.value) return
  try {
    await navigator.clipboard.writeText(current.value.text)
    copied.value = true
    setTimeout(() => (copied.value = false), 1500)
  } catch (e) {
    toasts.error(e)
  }
}

function step(delta: number) {
  index.value = (index.value + delta + reports.value.length) % reports.value.length
  copied.value = false
}
</script>

<template>
  <BaseDialog v-if="current" :title="t('crashReport.title')" wide @close="close">
    <p class="text-sm text-base-200">{{ t('crashReport.text') }}</p>
    <div class="mt-3 rounded-md border border-base-700 bg-base-950 p-3" data-testid="crash-report">
      <p class="text-sm font-medium text-base-50">{{ t(`crashReport.kind.${crashReportKind(current.kind)}`) }}</p>
      <p class="mt-0.5 truncate text-xs text-base-300 select-text">{{ current.title }}</p>
      <p v-if="current.time" class="text-xs text-base-400">{{ formatDate(current.time) }}</p>
      <pre class="mt-2 max-h-56 overflow-auto font-mono text-[11px] leading-snug whitespace-pre-wrap text-base-300 select-text">{{ current.text }}</pre>
    </div>
    <p class="mt-2 text-xs text-base-400">{{ t('crashReport.filesHint') }}</p>
    <div v-if="reports.length > 1" class="mt-3 flex items-center justify-center gap-3 text-xs text-base-400">
      <button class="btn-icon size-8" :aria-label="t('crashReport.previous')" @click="step(-1)">‹</button>
      <span>{{ t('crashReport.position', { n: index + 1, total: reports.length }) }}</span>
      <button class="btn-icon size-8" :aria-label="t('crashReport.next')" @click="step(1)">›</button>
    </div>
    <template #actions>
      <button class="btn btn-ghost" @click="copy">{{ copied ? t('common.status.copied') : t('common.actions.copy') }}</button>
      <button class="btn btn-ghost" data-testid="crash-report-share" @click="share">{{ t('crashReport.share') }}</button>
      <button class="btn btn-primary" @click="close">{{ t('common.actions.close') }}</button>
    </template>
  </BaseDialog>
</template>
