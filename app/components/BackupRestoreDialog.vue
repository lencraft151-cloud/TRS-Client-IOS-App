<script setup lang="ts">
import { isTauri } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { backupTime, restoreRequest } from '~/utils/backup'
// iOS: Sicherung wiederherstellen – aus Einstellungen → Sicherung oder über „Öffnen in TRS Launcher“ (.trsbackup aus
// der Dateien-App, iCloud Drive, AirDrop). Nach dem Einspielen lädt die Oberfläche neu.
const tasks = useTasksStore()
const toasts = useToasts()
const games = useGamesStore()
const RESTORED_FLAG = 'trs-backup-restored'
const request = restoreRequest
const instances = computed(() => request.value?.manifest?.instances ?? [])
const running = computed(() => games.runningCount > 0)

let unlisten: (() => void) | null = null
onMounted(async () => {
  if (!isTauri() || hostOs !== 'ios') return
  try {
    if (sessionStorage.getItem(RESTORED_FLAG)) {
      sessionStorage.removeItem(RESTORED_FLAG)
      toasts.ok(t('backup.restored'))
    }
  } catch {
    // Ohne sessionStorage eben ohne Meldung.
  }
  const takeOpened = async () => {
    const entry = await backend.backup.takeOpened().catch(() => null)
    if (entry) request.value = entry
  }
  unlisten = await listen('open-backup-file', () => void takeOpened())
  await takeOpened()
})
onBeforeUnmount(() => unlisten?.())

async function restore() {
  const entry = request.value
  request.value = null
  if (!entry) return
  const result = await tasks.run(
    {
      key: taskKey('launcher-restore'),
      kind: 'import',
      title: t('backup.restoreTaskTitle'),
      stage: entry.downloaded ? t('backup.restoring') : t('backup.downloading'),
      cancellable: true,
      notify: false,
    },
    (ctx) => backend.backup.restore(entry.path, (p) => ctx.progress(p, t('backup.restoring')), ctx.taskId),
  )
  if (!result.ok) return
  try {
    sessionStorage.setItem(RESTORED_FLAG, '1')
  } catch {
    toasts.ok(t('backup.restored'))
  }
  // Einstellungen, Instanzen, Skins und Steuerung frisch laden.
  window.location.reload()
}
</script>

<template>
  <BaseDialog v-if="request" :title="t('backup.restoreTitle')" @close="request = null">
    <p class="text-sm text-base-200">{{ t('backup.restoreText') }}</p>
    <div class="mt-3 rounded-md border border-base-700 bg-base-950 p-3 text-sm" data-testid="backup-restore">
      <p class="font-medium text-base-50">{{ formatDate(backupTime(request)) || request.fileName }}</p>
      <p v-if="request.manifest" class="text-xs text-base-400">
        {{ t('backup.fromVersion', { version: request.manifest.appVersion }) }}
        <template v-if="request.manifest.device"> · {{ request.manifest.device }}</template>
      </p>
      <ul v-if="instances.length" class="mt-2 max-h-40 list-inside list-disc overflow-auto text-xs text-base-300">
        <li v-for="i in instances" :key="i.id">{{ i.name }} <span class="text-base-500">({{ i.gameVersion }})</span></li>
      </ul>
      <p v-else-if="request.manifest" class="mt-2 text-xs text-base-400">{{ t('backup.noInstances') }}</p>
      <p v-if="!request.downloaded" class="mt-2 text-xs text-base-400">{{ t('backup.notDownloaded') }}</p>
    </div>
    <p v-if="running" class="mt-2 text-xs text-warn" role="alert">{{ t('errors.backup.gameRunning') }}</p>
    <template #actions>
      <button class="btn btn-ghost" @click="request = null">{{ t('common.actions.cancel') }}</button>
      <button class="btn btn-danger" :disabled="running" data-testid="backup-restore-confirm" @click="restore">{{ t('backup.restore') }}</button>
    </template>
  </BaseDialog>
</template>
