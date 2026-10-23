import { describe, expect, it } from 'vitest'
import { backupInstances, backupOverviewSchema, backupTime } from '../app/utils/backup'
import { appSettingsSectionsFor } from '../app/utils/sections'

const overview = backupOverviewSchema.parse({
  places: { local: '/Documents/Backups', icloud: null },
  backups: [
    {
      path: '/Documents/Backups/TRS-Launcher_2026-10-23_10-00-00.trsbackup',
      fileName: 'TRS-Launcher_2026-10-23_10-00-00.trsbackup',
      size: 1_234_567,
      modified: '2026-10-23T10:00:05Z',
      manifest: {
        format: 1,
        appVersion: '0.27.1',
        created: '2026-10-23T10:00:00Z',
        device: 'iPhone14,4',
        automatic: false,
        instances: ['Survival', 'Creative', 'Skyblock', 'PvP'].map((name, i) => ({ id: `i${i}`, name, gameVersion: '1.21.1' })),
        bytes: 9_000_000,
      },
      downloaded: true,
      icloud: false,
    },
    // Nur in iCloud: ohne Beschreibung, Zeit aus der Datei.
    { path: '/c/B/a.trsbackup', fileName: 'a.trsbackup', size: 0, modified: '2026-10-20T08:00:00Z', manifest: null, downloaded: false, icloud: true },
  ],
  estimate: 9_000_000,
  lastAutomatic: null,
})

describe('Sicherung', () => {
  it('liest die Übersicht des Kerns', () => {
    expect(overview.backups).toHaveLength(2)
    expect(backupTime(overview.backups[0]!)).toBe('2026-10-23T10:00:00Z')
    expect(backupTime(overview.backups[1]!)).toBe('2026-10-20T08:00:00Z')
  })

  it('kürzt lange Instanzlisten', () => {
    expect(backupInstances(overview.backups[0]!)).toEqual({ names: ['Survival', 'Creative', 'Skyblock'], more: 1 })
    expect(backupInstances(overview.backups[1]!)).toEqual({ names: [], more: 0 })
  })

  it('zeigt den Bereich nur auf iPhone und iPad', () => {
    const keys = (platform: 'ios' | 'android' | 'windows') =>
      appSettingsSectionsFor({ clips: false, java: platform === 'windows', gameLaunch: true, platform }).map((s) => s.key)
    expect(keys('ios')).toContain('backup')
    expect(keys('android')).not.toContain('backup')
    expect(keys('windows')).not.toContain('backup')
  })
})
