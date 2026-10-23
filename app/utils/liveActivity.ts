import { watch } from 'vue'
import type { TaskKind } from '../types'
import { backend } from './backend'

/**
 * iOS: laufende Aufgaben (Spielstart mit Downloads, Modpacks, Java, Importe …) als Live-Aktivität auf dem
 * Sperrbildschirm und in der Dynamic Island. Die Anzeige baut die Widget-Erweiterung (gen/apple/Widgets).
 */

/** Kurze Aufgaben ohne Downloads – keine Live-Aktivität. */
const SKIP: TaskKind[] = ['presets', 'shared-folders', 'duplicate', 'move']
/** Erst Aufgaben, die so lange laufen, bekommen eine Aktivität (kurze sollen nicht aufblitzen). */
export const START_AFTER_MS = 3000
/** Höchstens so oft aktualisieren (iOS drosselt sonst ohnehin). */
export const MIN_INTERVAL_MS = 2000

export interface ActivityTask {
  key: string
  kind: TaskKind
  title: string
  stage: string
  percent: number | null
  status: 'running' | 'done' | 'failed' | 'cancelled'
  startedAt: number
}

export interface SentState {
  at: number
  percent: number | null
  stage: string
  title: string
}

/** Was mit einer Aufgabe passieren soll: starten/aktualisieren, beenden oder nichts. */
export function activityAction(task: ActivityTask, sent: SentState | undefined, now: number): 'update' | 'end' | 'none' {
  if (SKIP.includes(task.kind)) return 'none'
  if (task.status !== 'running') return sent ? 'end' : 'none'
  if (!sent) return now - task.startedAt >= START_AFTER_MS ? 'update' : 'none'
  if (now - sent.at < MIN_INTERVAL_MS) return 'none'
  const changed = sent.stage !== task.stage || sent.title !== task.title || Math.abs((task.percent ?? -1) - (sent.percent ?? -1)) >= 1
  return changed ? 'update' : 'none'
}

/** Beobachtet die Aufgaben und hält die Live-Aktivitäten aktuell (einmal beim Start der Oberfläche). */
export function startLiveActivities(tasks: () => Record<string, ActivityTask>) {
  const sent = new Map<string, SentState>()
  const sync = () => {
    const now = Date.now()
    for (const task of Object.values(tasks())) {
      const action = activityAction(task, sent.get(task.key), now)
      if (action === 'none') continue
      const done = action === 'end'
      void backend
        .liveActivity({
          id: task.key,
          kind: task.kind,
          title: task.title,
          detail: task.stage,
          progress: done ? 1 : task.percent === null ? -1 : task.percent / 100,
          done,
        })
        .catch(() => {})
      if (done) sent.delete(task.key)
      else sent.set(task.key, { at: now, percent: task.percent, stage: task.stage, title: task.title })
    }
  }
  watch(() => Object.values(tasks()).map((t) => `${t.key}|${t.status}|${t.percent}|${t.stage}|${t.title}`).join('\n'), sync)
  // Läuft eine Aufgabe ohne neuen Fortschritt weiter, trotzdem nach START_AFTER_MS starten.
  setInterval(sync, START_AFTER_MS)
}

/** Kurzbefehl „Minecraft spielen“ (`play/last`): die zuletzt gespielte Instanz, sonst die erste. */
export function lastPlayedInstance<T extends { lastPlayed?: string | null }>(items: T[]): T | undefined {
  const time = (i: T) => (i.lastPlayed ? Date.parse(i.lastPlayed) || 0 : 0)
  return [...items].sort((a, b) => time(b) - time(a))[0]
}
