import { createHash, randomBytes } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import fs from 'node:fs'
import tailwindcss from '@tailwindcss/vite'

// Messe-Build (TRS_MESSE=1, alternativ NUXT_PUBLIC_MESSE=1): Präsentation + Kiosk-Ebene. Normale Builds bekommen
// weder die Präsentation (.messe-pitch/) noch aktive Messe-Pfade – MESSE ist dort zur Bauzeit fest `false`.
const messe = process.env.TRS_MESSE === '1' || process.env.NUXT_PUBLIC_MESSE === '1'
const messePitchDir = fileURLToPath(new URL('./.messe-pitch', import.meta.url))
if (messe && !fs.existsSync(`${messePitchDir}/index.html`)) {
  throw new Error('Messe-Build ohne Präsentation: erst `node scripts/messe/import-pitch.mjs <Ordner>` ausführen.')
}

// Eingebaute Personal-PIN (TRS_MESSE_PIN, 4–8 Ziffern) – landet nur als gesalzener Hash im Build
// (gleiches Format wie hashPin in app/utils/messe.ts).
const messePin = messe ? (process.env.TRS_MESSE_PIN ?? '') : ''
if (messePin && !/^\d{4,8}$/.test(messePin)) throw new Error('TRS_MESSE_PIN: 4–8 Ziffern erwartet.')
const messePinSalt = messePin ? randomBytes(16).toString('hex') : ''
const messePinRecord = messePin
  ? JSON.stringify({ salt: messePinSalt, hash: createHash('sha256').update(`trs-messe:${messePinSalt}:${messePin}`).digest('hex') })
  : ''

// Web-Version (TRS_WEB=1, .github/workflows/web-app.yml): dieselbe Oberfläche als Web-App auf GitHub Pages, unter
// dem Unterpfad TRS_WEB_BASE (z. B. /TRS-Client-IOS-App/). Dazu Manifest, Service Worker und App-Symbole
// (web/public/, Symbole aus dem iOS-Projekt); öfter nach neuen Versionen schauen (app/plugins/web.client.ts).
const web = process.env.TRS_WEB === '1'
const webBase = web ? `/${(process.env.TRS_WEB_BASE ?? '').replace(/^\/+|\/+$/g, '')}/`.replace(/^\/\/$/, '/') : '/'
const webIcons = fileURLToPath(new URL('./src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset', import.meta.url))
const webAssets = web
  ? [
      { dir: fileURLToPath(new URL('./web/public', import.meta.url)), maxAge: 0 },
      { dir: webIcons, baseURL: '/app-icons', maxAge: 0 },
    ]
  : []
// Das Ladebild (app/spa-loading-template.html) ist reines HTML ohne Verarbeitung – für den Unterpfad eine Kopie.
let webLoadingTemplate: string | undefined
if (webBase !== '/') {
  const cache = new URL('./node_modules/.cache/trs-web/', import.meta.url)
  fs.mkdirSync(cache, { recursive: true })
  webLoadingTemplate = fileURLToPath(new URL('spa-loading-template.html', cache))
  const template = fs.readFileSync(new URL('./app/spa-loading-template.html', import.meta.url), 'utf8')
  fs.writeFileSync(webLoadingTemplate, template.replaceAll('src="/', `src="${webBase}`))
}

// Tauri hat keine Server-Runtime: SPA-Modus + `nuxt generate`.
export default defineNuxtConfig({
  compatibilityDate: '2026-09-01',
  ssr: false,
  telemetry: false,
  // Web-Version: alle 15 min nach einer neuen Version schauen (sonst stündlich, Nuxt-Standard).
  ...(web ? { experimental: { checkOutdatedBuildInterval: 15 * 60 * 1000 } } : {}),
  ...(webLoadingTemplate ? { spaLoadingTemplate: webLoadingTemplate } : {}),
  devtools: { enabled: false },
  modules: [
    '@pinia/nuxt',
    // Nur `nuxt dev`: Vorschau der Start-Animation unter /intro-preview (wird nicht mit ausgeliefert).
    (_options, nuxt) => {
      if (!nuxt.options.dev) return
      nuxt.hook('pages:extend', (pages) => {
        pages.push({ name: 'intro-preview', path: '/intro-preview', file: fileURLToPath(new URL('./app/dev/intro-preview.vue', import.meta.url)) })
      })
    },
  ],
  css: ['~/assets/css/main.css'],
  app: {
    baseURL: webBase,
    pageTransition: { name: "page", mode: "out-in" },
    head: {
      title: 'TRS Launcher',
      htmlAttrs: { lang: 'en' },
      // Handy: bis unter Notch/Gestenleiste zeichnen (Ränder über env(safe-area-inset-*)),
      // die Tastatur verkleinert die Seite – das Eingabefeld im Chat bleibt sichtbar.
      viewport: 'width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content',
      // Web-Version: Manifest, Symbole und Home-Bildschirm-App (iOS).
      link: web
        ? [
            { rel: 'manifest', type: 'application/manifest+json', href: `${webBase}manifest.webmanifest` },
            { rel: 'icon', type: 'image/png', href: `${webBase}icon.png` },
            { rel: 'apple-touch-icon', type: 'image/png', href: `${webBase}app-icons/AppIcon-60x60@3x.png` },
          ]
        : [],
      meta: web
        ? [
            { name: 'apple-mobile-web-app-capable', content: 'yes' },
            { name: 'mobile-web-app-capable', content: 'yes' },
            { name: 'apple-mobile-web-app-status-bar-style', content: 'black-translucent' },
            { name: 'apple-mobile-web-app-title', content: 'TRS Launcher' },
            { name: 'theme-color', content: '#111116' },
          ]
        : [],
    },
  },
  devServer: { port: 3000 },
  ignore: ['**/src-tauri/**'],
  // Das REC-Overlay lädt als eigenes Fenster direkt `/clip-overlay`; die Route wird sonst von
  // keiner Seite verlinkt, daher explizit mit vorbauen (eigene index.html).
  nitro: {
    prerender: { routes: ['/clip-overlay'] },
    // Nur im Messe-Build: Präsentation unter /messe-pitch/ (eingebettet per iframe).
    // Web-Version: Manifest, Service Worker, App-Symbole.
    publicAssets: messe ? [{ dir: messePitchDir, baseURL: '/messe-pitch', maxAge: 0 }] : webAssets,
  },
  vite: {
    clearScreen: false,
    // vue-i18n: nur Composition API; Nachrichten werden ohne eval übersetzt (CSP bleibt streng).
    define: {
      'import.meta.env.VITE_TRS_MESSE': JSON.stringify(messe ? '1' : ''),
      'import.meta.env.VITE_TRS_MESSE_PIN': JSON.stringify(messePinRecord),
      'import.meta.env.VITE_TRS_WEB': JSON.stringify(web ? '1' : ''),
      'import.meta.env.VITE_TRS_BASE': JSON.stringify(webBase),
      __VUE_I18N_FULL_INSTALL__: true,
      __VUE_I18N_LEGACY_API__: false,
      __INTLIFY_PROD_DEVTOOLS__: false,
      __INTLIFY_DROP_MESSAGE_COMPILER__: false,
    },
    envPrefix: ['VITE_', 'TAURI_'],
    server: {
      strictPort: true,
      watch: { ignored: ['**/src-tauri/**'] },
    },
    plugins: [tailwindcss()],
  },
})
