<script setup lang="ts">
import { isTauri } from '@tauri-apps/api/core'
import type { MobileUpdateStatus } from '~/types'
import { MESSE } from '~/utils/messe'
import { shouldAutoInstall, shouldRecheckOnResume } from '~/utils/mobileUpdate'

// Android/iOS: Update-Hinweis aus dem Kanal `mobile`. Prüft kurz nach dem Start, alle paar Stunden und wenn die App
// nach einer Pause wieder nach vorn kommt. iOS installiert über den OTA-Link (mit Profil signierte IPA) von selbst:
// Ist eine neue Version da und läuft gerade nichts (Spiel, Downloads, Einrichtung), öffnet die App die Installation –
// iOS fragt nur noch einmal nach und ersetzt die App. Android lädt die APK auf Tipp und öffnet den Installationsdialog.
// „Später“ blendet die Version für diese Sitzung aus.
const CHECK_INTERVAL_MS = 4 * 60 * 60 * 1000
const FIRST_CHECK_MS = 8000

const status = ref<MobileUpdateStatus | null>(null)
const busy = ref(false)
const message = ref('')
const hidden = ref<string | null>(null)
let timer: ReturnType<typeof setTimeout> | undefined
let lastCheck = 0
/** iOS: Versionen, deren Installation in dieser Sitzung schon von selbst geöffnet wurde (nicht ständig nachfragen). */
const autoStarted = new Set<string>()

const visible = computed(() => !!status.value?.available && !!status.value.latest && hidden.value !== status.value.latest)
/** In dieser Sitzung fand sich kein SideStore/AltStore. */
const noStore = ref(false)
const canInstall = computed(() => hostOs === 'android' || !!status.value?.installUrl || (!!status.value?.sideloadUrl && !noStore.value))
/** iOS ohne Profil: Update über SideStore (installiert und signiert auf dem Gerät). */
const viaStore = computed(() => hostOs === 'ios' && !status.value?.installUrl && !!status.value?.sideloadUrl)

async function check() {
  clearTimeout(timer)
  lastCheck = Date.now()
  try {
    status.value = await backend.mobileUpdateCheck()
  } catch {
    // Offline oder Kanal gerade leer (wird neu veröffentlicht) – später still erneut.
  }
  timer = setTimeout(check, CHECK_INTERVAL_MS)
}

function onVisibility() {
  if (document.visibilityState === 'visible' && shouldRecheckOnResume(lastCheck, Date.now())) void check()
}

// iOS: von selbst installieren, sobald nichts läuft – einmal je Version und App-Start.
const games = useGamesStore()
const tasks = useTasksStore()
const onboarding = useOnboardingStore()
const idle = computed(() => games.runningCount === 0 && tasks.active.length === 0 && !onboarding.open)
watch([status, hidden, idle], () => {
  const latest = status.value?.latest
  const state = { os: hostOs, status: status.value, hidden: hidden.value, idle: idle.value, busy: busy.value, started: autoStarted, noStore: noStore.value }
  if (!latest || !shouldAutoInstall(state)) return
  autoStarted.add(latest)
  void install()
})

async function install() {
  busy.value = true
  message.value = ''
  try {
    const outcome = await backend.mobileUpdateInstall()
    if (outcome.status === 'noStore') noStore.value = true
    message.value = {
      permissionRequired: t('mobileUpdate.permissionRequired'),
      storeStarted: t('mobileUpdate.storeStarted'),
      noStore: t('mobileUpdate.noStore'),
      started: hostOs === 'ios' ? t('mobileUpdate.iosStarted') : '',
    }[outcome.status]
  } catch (e) {
    message.value = errorMessage(e)
  } finally {
    busy.value = false
  }
}

onMounted(() => {
  if (!isTauri() || !isMobile || MESSE) return
  timer = setTimeout(check, FIRST_CHECK_MS)
  document.addEventListener('visibilitychange', onVisibility)
})

// „Beta-Versionen“ umgeschaltet: gleich neu prüfen (ein Beta-Update verschwindet beim Ausschalten wieder).
const settings = useSettingsStore()
watch(
  () => settings.current?.mobileBeta,
  (now, before) => {
    if (before === undefined || now === before || !isTauri() || !isMobile || MESSE) return
    clearTimeout(timer)
    void check()
  },
)
onBeforeUnmount(() => {
  clearTimeout(timer)
  document.removeEventListener('visibilitychange', onVisibility)
})
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
        <p class="font-semibold text-base-50">
          {{ t('mobileUpdate.available', { version: status.latest ?? '' }) }}
          <span v-if="status.beta" class="badge ml-1 bg-lamp-400/15 text-lamp-300">{{ t('mobileUpdate.betaBadge') }}</span>
        </p>
        <p class="text-xs text-base-300">
          {{ message || (viaStore && canInstall ? t('mobileUpdate.storeHint') : canInstall ? t('mobileUpdate.installHint') : t('mobileUpdate.sideloadHint')) }}
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
