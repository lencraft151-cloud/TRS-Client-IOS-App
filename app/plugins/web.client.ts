// Web-Version (TRS_WEB=1, GitHub Pages): offline startbar (Service Worker) und immer die neueste Version.
// Nuxt schaut regelmäßig in builds/latest.json (experimental.checkOutdatedBuildInterval) und meldet einen neuen
// Build über den Hook `app:manifest:update`. Dann lädt die Seite neu: sofort, wenn sie gerade nicht zu sehen ist,
// sonst beim nächsten Seitenwechsel. Kommt die App nach einer Pause wieder nach vorn (Home-Bildschirm-App auf dem
// iPhone), schaut sie gleich nach. In der App (Tauri) tut das Plugin nichts.
import type { NuxtAppManifestMeta } from '#app'

const UPDATED_KEY = 'trs.web.updated'

export default defineNuxtPlugin((nuxtApp) => {
  if (!WEB) return
  const { baseURL, buildAssetsDir } = useRuntimeConfig().app

  if ('serviceWorker' in navigator) navigator.serviceWorker.register(`${baseURL}sw.js`).catch(() => {})

  let pending = false
  let lastCheck = Date.now()

  function reload() {
    try {
      sessionStorage.setItem(UPDATED_KEY, '1')
    } catch {}
    window.location.reload()
  }

  async function check() {
    lastCheck = Date.now()
    try {
      const latest = await $fetch<NuxtAppManifestMeta>(`${baseURL}${buildAssetsDir.replace(/^\/+/, '')}builds/latest.json?${Date.now()}`)
      const current = await getAppManifest()
      if (latest.id !== current.id) await nuxtApp.hooks.callHook('app:manifest:update', latest)
    } catch {
      // Offline oder gerade neu veröffentlicht – beim nächsten Mal.
    }
  }

  nuxtApp.hooks.hook('app:manifest:update', () => {
    pending = true
    // Neuer Service Worker gleich mit (räumt den Cache der alten Version weg).
    navigator.serviceWorker
      ?.getRegistration()
      .then((r) => r?.update())
      .catch(() => {})
    if (document.visibilityState === 'hidden') reload()
  })

  useRouter().afterEach((to, from) => {
    if (pending && to.fullPath !== from.fullPath) reload()
  })

  document.addEventListener('visibilitychange', () => {
    if (pending) reload()
    else if (document.visibilityState === 'visible' && shouldRecheck(lastCheck, Date.now())) void check()
  })

  onNuxtReady(() => {
    try {
      if (!sessionStorage.getItem(UPDATED_KEY)) return
      sessionStorage.removeItem(UPDATED_KEY)
    } catch {
      return
    }
    useToasts().info(t('web.updated'))
  })
})
