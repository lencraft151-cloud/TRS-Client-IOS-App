import { ref } from 'vue'
import { z } from 'zod'

/**
 * Sicherung des Launchers (iOS): Einstellungen → Sicherung und „Öffnen in TRS Launcher“ für `.trsbackup`.
 * Den Inhalt bestimmt der Kern (crates/core/src/backup.rs), Orte und tägliche Sicherung src-tauri/src/backup.rs.
 */

export const backupManifestSchema = z.object({
  format: z.number().int(),
  appVersion: z.string().max(64),
  created: z.string().max(64),
  device: z.string().max(200).default(''),
  automatic: z.boolean().default(false),
  instances: z
    .array(z.object({ id: z.string().max(200), name: z.string().max(200), gameVersion: z.string().max(64) }))
    .max(2000)
    .default([]),
  bytes: z.number().nonnegative().default(0),
})
export type BackupManifest = z.output<typeof backupManifestSchema>

export const backupEntrySchema = z.object({
  path: z.string().max(4096),
  fileName: z.string().max(512),
  size: z.number().nonnegative(),
  modified: z.string().max(64).nullable(),
  manifest: backupManifestSchema.nullable(),
  downloaded: z.boolean(),
  icloud: z.boolean(),
})
export type BackupEntry = z.output<typeof backupEntrySchema>

export const backupOverviewSchema = z.object({
  places: z.object({ local: z.string().max(4096).nullable(), icloud: z.string().max(4096).nullable() }),
  backups: z.array(backupEntrySchema).max(500),
  estimate: z.number().nonnegative(),
  lastAutomatic: z.string().max(64).nullable(),
})
export type BackupOverview = z.output<typeof backupOverviewSchema>

/** Zeitpunkt der Sicherung: aus der Beschreibung, sonst Änderungsdatum der Datei. */
export function backupTime(entry: BackupEntry): string | null {
  return entry.manifest?.created ?? entry.modified
}

/** Kurzbeschreibung des Inhalts: Instanznamen (die ersten drei, dann „+ n“). */
export function backupInstances(entry: BackupEntry, max = 3): { names: string[]; more: number } {
  const names = entry.manifest?.instances.map((i) => i.name) ?? []
  return { names: names.slice(0, max), more: Math.max(0, names.length - max) }
}

/** Sicherung, die gerade zum Wiederherstellen angeboten wird (Einstellungen oder geöffnete Datei). */
export const restoreRequest = ref<BackupEntry | null>(null)
