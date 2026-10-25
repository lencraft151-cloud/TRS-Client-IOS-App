// Service Worker der Web-Version (nur TRS_WEB=1, siehe nuxt.config.ts und app/plugins/web.client.ts).
//
// - Seiten: erst aus dem Netz (immer die neueste Version), ohne Netz die zuletzt geladene.
// - _nuxt/…: Dateinamen enthalten einen Hash und ändern sich nie – aus dem Cache, sonst aus dem Netz.
// - _nuxt/builds/… (Versionsprüfung): nie aus dem Cache.
// - Sonstiges (Symbol, Flaggen, News-Bilder): aus dem Cache und im Hintergrund auffrischen.
//
// Der Workflow trägt beim Veröffentlichen den Commit in BUILD ein: Jede neue Version bringt so einen neuen Service
// Worker mit, der den Cache der alten wegräumt.
const BUILD = '__TRS_BUILD__'
const CACHE = `trs-web-${BUILD}`
const SHELL = 'shell'

self.addEventListener('install', () => self.skipWaiting())

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const name of await caches.keys()) if (name !== CACHE) await caches.delete(name)
      await self.clients.claim()
    })(),
  )
})

self.addEventListener('fetch', (event) => {
  const request = event.request
  if (request.method !== 'GET') return
  const url = new URL(request.url)
  const scope = new URL(self.registration.scope)
  if (url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname)) return
  const path = url.pathname.slice(scope.pathname.length)
  if (path.startsWith('_nuxt/builds/')) return
  if (request.mode === 'navigate') event.respondWith(page(request))
  else if (path.startsWith('_nuxt/')) event.respondWith(immutable(request))
  else event.respondWith(refreshing(request))
})

async function page(request) {
  const cache = await caches.open(CACHE)
  try {
    const response = await fetch(request)
    // GitHub Pages liefert Unterseiten der App als 404.html (mit Status 404) – auch das ist die App.
    if (response.ok || response.status === 404) await cache.put(SHELL, response.clone())
    return response
  } catch (error) {
    const cached = await cache.match(SHELL)
    if (cached) return cached
    throw error
  }
}

async function immutable(request) {
  const cache = await caches.open(CACHE)
  const cached = await cache.match(request)
  if (cached) return cached
  const response = await fetch(request)
  if (response.ok) await cache.put(request, response.clone())
  return response
}

async function refreshing(request) {
  const cache = await caches.open(CACHE)
  const cached = await cache.match(request)
  const network = fetch(request)
    .then(async (response) => {
      if (response.ok) await cache.put(request, response.clone())
      return response
    })
    .catch(() => cached)
  return cached ?? network
}
