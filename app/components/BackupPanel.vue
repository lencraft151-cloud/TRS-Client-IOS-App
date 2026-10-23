<script setup lang="ts">
import { isTauri } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { type BackupEntry, type BackupOverview, backupInstances, backupTime, restoreRequest } from '~/utils/backup'
// Einstellungen → Sicherung (iOS): jetzt sichern, täglich automatisch, Liste mit Wiederherstellen/Teilen/Löschen.
// Wiederherstellen läuft über den Dialog in der Layout-Komponente (BackupRestoreDialog) – derselbe wie beim Öffnen
// einer .trsbackup-Datei aus der Dateien-App.
const auto = defineModel<boolean>('auto', { required: true })
const tasks = useTasksStore()
const toasts = useToasts()
const overview = ref<BackupOverview | null>(null)
const failed = ref(false)
const toDelete = ref<BackupEntry | null>(null)
const TASK_KEY = taskKey('launcher-backup')
const creating = computed(() => tasks.get(TASK_KEY)?.status === 'running')

async function load() {
  try {
    overview.value = await backend.backup.overview()
    failed.value = false
  } catch (e) {
    failed.value = true
    toasts.error(e)
  }
}

let unlisten: (() => void) | null = null
onMounted(async () => {
  await load()
  if (isTauri()) unlisten = await listen('backup-changed', () => void load())
})
onBeforeUnmount(() => unlisten?.())

async function create() {
  const result = await tasks.run(
    {
      key: TASK_KEY,
      kind: 'export',
      title: t('backup.taskTitle'),
      stage: t('backup.creating'),
      cancellable: true,
      doneText: t('backup.created'),
    },
    (ctx) => backend.backup.create((p) => ctx.progress(p), ctx.taskId),
  )
  if (result.ok) await load()
}

async function share(entry: BackupEntry) {
  await backend.backup.share(entry.path).catch((e) => toasts.error(e))
}

async function confirmDelete() {
  const entry = toDelete.value
  toDelete.value = null
  if (!entry) return
  try {
    await backend.backup.remove(entry.path)
    toasts.ok(t('backup.deleted'))
    await load()
  } catch (e) {
    toasts.error(e)
  }
}

const placeText = computed(() => (overview.value?.places.icloud ? t('backup.placeIcloud') : t('backup.placeLocal')))
const lastAutomatic = computed(() =>
  overview.value?.lastAutomatic ? t('backup.lastAutomatic', { time: formatRelative(overview.value.lastAutomatic, true) }) : '',
)
</script>

<template>
  <div data-testid="backup-panel">
    <h3 class="section-heading">{{ t('backup.title') }}</h3>
    <p class="mb-3 text-sm text-base-300">{{ placeText }}</p>
    <p v-if="overview && !overview.places.icloud" class="mb-3 text-xs text-base-400">{{ t('backup.icloudHint') }}</p>

    <SettingRow
      :title="t('backup.createTitle')"
      :description="overview ? t('backup.createDescription', { size: formatBytes(overview.estimate) }) : t('backup.createDescriptionEmpty')"
    >
      <button class="btn btn-primary" :disabled="creating || failed" data-testid="backup-create" @click="create">
        {{ creating ? t('backup.creating') : t('backup.create') }}
      </button>
    </SettingRow>
    <SettingRow :title="t('backup.autoTitle')" :description="[t('backup.autoDescription'), lastAutomatic].filter(Boolean).join(' ')">
      <ToggleSwitch v-model="auto" :label="t('backup.autoTitle')" data-testid="backup-auto" />
    </SettingRow>

    <h3 class="section-heading mt-6">{{ t('backup.listTitle') }}</h3>
    <div v-if="!overview && !failed" class="skeleton h-20" />
    <p v-else-if="overview && overview.backups.length === 0" class="text-sm text-base-400">{{ t('backup.empty') }}</p>
    <ul v-else-if="overview" class="flex flex-col gap-2">
      <li
        v-for="entry in overview.backups"
        :key="entry.path"
        class="flex items-center gap-3 rounded-xl border border-base-800 bg-base-850 p-3 mobile:flex-col mobile:items-stretch"
      >
        <div class="min-w-0 flex-1">
          <p class="flex flex-wrap items-center gap-1.5 text-sm font-medium text-base-50">
            {{ formatDate(backupTime(entry)) || entry.fileName }}
            <span class="badge" :class="entry.icloud ? 'bg-sky-400/15 text-sky-300' : 'bg-base-800 text-base-300'">
              {{ entry.icloud ? t('backup.icloud') : t('backup.local') }}
            </span>
            <span v-if="entry.manifest?.automatic" class="badge bg-base-800 text-base-300">{{ t('backup.automatic') }}</span>
          </p>
          <p v-if="entry.manifest" class="mt-0.5 truncate text-xs text-base-400">
            <template v-if="entry.manifest.instances.length">
              {{ backupInstances(entry).names.join(', ') }}
              <template v-if="backupInstances(entry).more"> {{ t('backup.more', { n: backupInstances(entry).more }) }}</template>
            </template>
            <template v-else>{{ t('backup.noInstances') }}</template>
            · {{ formatBytes(entry.size) }}
            <template v-if="entry.manifest.device"> · {{ entry.manifest.device }}</template>
          </p>
          <p v-else-if="!entry.downloaded" class="mt-0.5 text-xs text-base-400">{{ t('backup.notDownloaded') }}</p>
          <p v-else class="mt-0.5 text-xs text-warn">{{ t('backup.unreadable') }}</p>
        </div>
        <div class="flex shrink-0 gap-1.5">
          <button class="btn btn-ghost" :disabled="entry.downloaded && !entry.manifest" @click="restoreRequest = entry">{{ t('backup.restore') }}</button>
          <button class="btn btn-ghost" @click="share(entry)">{{ t('backup.share') }}</button>
          <button class="btn-icon size-9" :title="t('common.actions.delete')" :aria-label="t('common.actions.delete')" @click="toDelete = entry">
            <svg viewBox="0 0 24 24" class="size-4" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3" /></svg>
          </button>
        </div>
      </li>
    </ul>

    <BaseDialog v-if="toDelete" :title="t('backup.deleteTitle')" @close="toDelete = null">
      <p class="text-sm text-base-200">{{ t('backup.deleteText', { time: formatDate(backupTime(toDelete)) || toDelete.fileName }) }}</p>
      <template #actions>
        <button class="btn btn-ghost" @click="toDelete = null">{{ t('common.actions.cancel') }}</button>
        <button class="btn btn-danger" @click="confirmDelete">{{ t('common.actions.delete') }}</button>
      </template>
    </BaseDialog>
  </div>
</template>

<style scoped>
@reference "~/assets/css/main.css";

.section-heading {
  @apply mb-2 text-base font-semibold text-base-50;
}
</style>
