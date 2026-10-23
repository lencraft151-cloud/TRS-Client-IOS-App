import { backend } from './backend'
import { isTauri } from '@tauri-apps/api/core'
import type { Router } from 'vue-router'

/**
 * Klick-Test im CI (`scripts/ios/simulator-smoke-test.sh` startet die App mit `TRS_UI_TOUR=1`): Die Oberfläche geht
 * selbst durch die Einrichtung (ohne Anmeldung) und die Hauptseiten. Jeder Schritt meldet sich im Log
 * (`ui-tour: <schritt> ok|FEHLER`), das Skript macht dazu einen Screenshot. Ohne die Variable passiert nichts.
 */
export const UI_TOUR_ROUTES = ['/', '/instances', '/browse', '/social', '/skins', '/screenshots', '/achievements', '/servers', '/controls', '/pc', '/accounts'] as const

/** So lange bleibt ein Schritt stehen – das Skript fotografiert in dieser Zeit. */
const SETTLE_MS = 3000
const HOLD_MS = 2000

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

/** Seiten- und Schrittnamen fürs Log (das Skript macht daraus Dateinamen). */
export function tourStepName(path: string): string {
  return path === '/' ? 'page-home' : `page${path.replaceAll('/', '-')}`
}

function hasContent(el: HTMLElement | null): boolean {
  return !!el && (el.innerText ?? '').trim().length > 0
}

async function report(name: string, ok: boolean) {
  await backend.uiTourStep(name, ok).catch(() => {})
  await sleep(HOLD_MS)
}

export async function runUiTour(router: Router, onboardingOpen: () => boolean): Promise<void> {
  if (!isTauri() || !(await backend.uiTour().catch(() => false))) return
  await report('start', true)
  // Einrichtung: jeden Schritt zeigen, dann den „Weiter/Später“-Knopf (data-tour-next) – nie anmelden.
  for (let i = 0; i < 12 && onboardingOpen(); i++) {
    await sleep(SETTLE_MS)
    const root = document.querySelector<HTMLElement>('.onboarding')
    if (!root) break
    const step = root.dataset.tourStep ?? 'unbekannt'
    await report(`onboarding-${step}`, hasContent(root))
    const next = root.querySelector<HTMLElement>('[data-tour-next]:not([disabled])')
    if (!next) {
      await report(`onboarding-${step}-ohne-weiter`, false)
      break
    }
    next.click()
  }
  for (const path of UI_TOUR_ROUTES) {
    await router.push(path).catch(() => {})
    await sleep(SETTLE_MS)
    await report(tourStepName(path), hasContent(document.querySelector<HTMLElement>('main')))
  }
  await report('fertig', true)
}
