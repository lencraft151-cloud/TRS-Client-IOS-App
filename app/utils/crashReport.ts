import { z } from 'zod'

/**
 * Absturzbericht aus `Dokumente/Crash Reports` (nur iOS, siehe `src-tauri/src/crash_report.rs`).
 * Arten: `panic` (Rust), `ios` (Absturz laut iOS), `hang` (Hänger), `unclean` (Start abgebrochen), `boot` (Oberfläche
 * lud nicht).
 */
export const crashReportSchema = z.object({
  id: z.string().max(200),
  kind: z.string().max(32),
  time: z.string().max(64).nullable(),
  title: z.string().max(2000),
  text: z.string().max(70_000),
  seen: z.boolean(),
})
export type CrashReport = z.output<typeof crashReportSchema>

export const CRASH_REPORT_KINDS = ['panic', 'ios', 'hang', 'unclean', 'boot'] as const

/** Bekannte Art oder `unknown` – für die Beschriftung. */
export function crashReportKind(kind: string): (typeof CRASH_REPORT_KINDS)[number] | 'unknown' {
  return (CRASH_REPORT_KINDS as readonly string[]).includes(kind) ? (kind as (typeof CRASH_REPORT_KINDS)[number]) : 'unknown'
}

/** Neue Berichte zuerst zeigen, höchstens `limit` – ältere bleiben in der Dateien-App. */
export function unseenReports(reports: CrashReport[], limit = 10): CrashReport[] {
  return reports.filter((r) => !r.seen).slice(0, limit)
}
