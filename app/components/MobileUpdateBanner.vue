<script setup lang="ts">
import { isTauri } from '@tauri-apps/api/core'
import type { MobileUpdateStatus } from '~/types'
import { MESSE } from '~/utils/messe'

// Android/iOS: Update-Hinweis aus dem Kanal `mobile`. Prüft kurz nach dem Start und danach alle paar Stunden.
// iOS installiert per Tipp über den OTA-Link (mit Profil signierte IPA) – iOS fragt nach und ersetzt die App.
// Android lädt die APK und öffnet den Installationsdialog. „Später“ blendet die Version für diese Sitzung aus.
const CHECK_INTERVAL_MS = 4 * 60 * 60 * 1000
const FIRST_CHECK_MS = 8000

const status = ref<MobileUpdateStatus | null>(null)
const busy = ref(false)
const message = ref('')
const hidden = ref<string | null>(null)
let timer: ReturnType<typeof setTimeout> | undefined

const visible = computed(() => !!status.value?.available && !!status.value.latest && hidden.value !== status.value.latest)
const canInstall = computed(() => hostOs === 'android' || !!status.value?.installUrl)

async function check() {
  try {
    status.value = await backend.mobileUpdateCheck()
  } catch {
    // Offline oder Kanal gerade leer (wird neu veröffentlicht) – später still erneut.
  }
  timer = setTimeout(check, CHECK_INTERVAL_MS)
}

async function install() {
  busy.value = true
  message.value = ''
  try {
    const outcome = await backend.mobileUpdateInstall()
    message.value = outcome.status === 'permissionRequired' ? t('mobileUpdate.permissionRequired') : hostOs === 'ios' ? t('mobileUpdate.iosStarted') : ''
  } catch (e) {
    message.value = errorMessage(e)
  } finally {
    busy.value = false
  }
}

onMounted(() => {
  if (!isTauri() || !isMobile || MESSE) return
  timer = setTimeout(check, FIRST_CHECK_MS)
})
onBeforeUnmount(() => clearTimeout(timer))
</script>

<template>
  <div v-if="visible && status" class="px-4 pt-3 pb-1" data-testid="mobile-update-banner">
    <div class="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-xl border border-redstone-600/60 bg-base-850/95 px-4 py-3 shadow-lg shadow-black/30 backdrop-blur-sm" role="status">
      <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-redstone-600/30 text-redstone-300">
        <svg viewBox="0 0 24 24" class="size-5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M20 12a8 8 0 1 1-2.34-5.66" />
          <path d="M20 4v5h-5" />
        </svg>
      </span>
      <div class="min-w-0 flex-1 text-sm">
        <p class="font-semibold text-base-50">{{ t('mobileUpdate.available', { version: status.latest ?? '' }) }}</p>
        <p class="text-xs text-base-300">
          {{ message || (canInstall ? t('mobileUpdate.installHint') : t('mobileUpdate.sideloadHint')) }}
        </p>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <button v-if="canInstall" class="btn btn-primary px-3 py-1.5 text-xs" :disabled="busy" data-testid="mobile-update-install" @click="install">
          {{ busy ? t('mobileUpdate.installing') : t('mobileUpdate.install') }}
        </button>
        <button class="btn btn-ghost px-3 py-1.5 text-xs" data-testid="mobile-update-later" @click="hidden = status.latest">{{ t('mobileUpdate.later') }}</button>
      </div>
    </div>
  </div>
</template>
