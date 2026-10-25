// Web-Version (TRS_WEB=1, GitHub Pages): der Launcher als Web-App im Browser, ohne Rust-Kern.
// Relativ importiert (kein Nuxt-Kontext), damit tests/web.test.ts die Logik direkt laden kann.

/** Web-Build? Wird zur Bauzeit fest eingesetzt. */
export const WEB: boolean = import.meta.env.VITE_TRS_WEB === '1'

/** Unterpfad der Seite (GitHub Pages: `/<repo>/`), in der App `/`. */
const BASE: string = import.meta.env.VITE_TRS_BASE || '/'

/**
 * Datei aus `public/` (Symbol, Flaggen, News-Bilder) unter dem Unterpfad der Web-Version. In der App und für
 * fremde oder relative Adressen unverändert.
 */
export function publicUrl(path: string, base: string = BASE): string {
  if (base === '/' || !path.startsWith('/') || path.startsWith('//')) return path
  return base.replace(/\/+$/, '') + path
}

/** Nach so langer Pause im Hintergrund beim Zurückkommen gleich nach einer neuen Version schauen. */
export const RECHECK_AFTER_MS = 60_000

export function shouldRecheck(lastCheck: number, now: number): boolean {
  return now - lastCheck >= RECHECK_AFTER_MS
}
