import { describe, expect, it } from 'vitest'
import { activityAction, lastPlayedInstance, MIN_INTERVAL_MS, START_AFTER_MS, type ActivityTask } from '../app/utils/liveActivity'

const base: ActivityTask = { key: 'launch:a', kind: 'launch', title: 'Survival', stage: 'Lädt', percent: 10, status: 'running', startedAt: 0 }

describe('Live-Aktivität (iOS)', () => {
  it('startet erst bei längeren Aufgaben und nie für kurze Arten', () => {
    expect(activityAction(base, undefined, START_AFTER_MS - 1)).toBe('none')
    expect(activityAction(base, undefined, START_AFTER_MS)).toBe('update')
    expect(activityAction({ ...base, kind: 'presets' }, undefined, 60_000)).toBe('none')
  })

  it('aktualisiert gedrosselt und nur bei Änderungen', () => {
    const sent = { at: 10_000, percent: 10, stage: 'Lädt', title: 'Survival' }
    expect(activityAction({ ...base, percent: 50 }, sent, 10_000 + MIN_INTERVAL_MS - 1)).toBe('none')
    expect(activityAction({ ...base, percent: 50 }, sent, 10_000 + MIN_INTERVAL_MS)).toBe('update')
    expect(activityAction(base, sent, 99_000)).toBe('none')
    expect(activityAction({ ...base, stage: 'Startet' }, sent, 99_000)).toBe('update')
  })

  it('beendet nur, was gestartet wurde', () => {
    const sent = { at: 0, percent: 10, stage: 'Lädt', title: 'Survival' }
    expect(activityAction({ ...base, status: 'done' }, sent, 1)).toBe('end')
    expect(activityAction({ ...base, status: 'failed' }, undefined, 99_000)).toBe('none')
  })

  it('findet die zuletzt gespielte Instanz', () => {
    const items = [
      { id: 'a', lastPlayed: '2026-10-01T10:00:00Z' },
      { id: 'b', lastPlayed: '2026-10-22T10:00:00Z' },
      { id: 'c', lastPlayed: null },
    ]
    expect(lastPlayedInstance(items)?.id).toBe('b')
    expect(lastPlayedInstance([{ id: 'x', lastPlayed: null }])?.id).toBe('x')
    expect(lastPlayedInstance([])).toBeUndefined()
  })
})
