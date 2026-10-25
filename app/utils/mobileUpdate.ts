import type { MobileUpdateStatus } from '~/types'
import type { OsName } from './system'

/** Kanal neu prüfen, wenn die App nach mindestens so langer Pause wieder nach vorn kommt. */
export const RESUME_CHECK_MS = 30 * 60 * 1000

/** Was über das automatische Installieren entscheidet. */
export interface AutoInstallState {
  os: OsName
  status: MobileUpdateStatus | null
  /** Version, die der Nutzer mit „Später“ ausgeblendet hat. */
  hidden: string | null
  /** Nichts läuft: kein Spiel, keine Aufgabe (Download, Installation), keine Einrichtung. */
  idle: boolean
  /** Eine Installation wird gerade geöffnet. */
  busy: boolean
  /** Versionen, deren Installation in dieser Sitzung schon von selbst geöffnet wurde. */
  started: ReadonlySet<string>
  /** In dieser Sitzung fand sich kein SideStore/AltStore. */
  noStore?: boolean
}

/**
 * iOS: Update von selbst installieren? Mit OTA-Link (mit Profil signierte IPA) oder über SideStore (kostenloses Konto,
 * ohne Mac), wenn nichts läuft, nicht nach „Später“, je Version nur einmal pro App-Start und nicht, nachdem sich kein
 * SideStore fand. iOS bzw. SideStore fragt danach selbst noch „Installieren?“.
 */
export function shouldAutoInstall(s: AutoInstallState): boolean {
  const latest = s.status?.latest
  return (
    s.os === 'ios' &&
    !!s.status?.available &&
    (!!s.status.installUrl || (!!s.status.sideloadUrl && !s.noStore)) &&
    !!latest &&
    s.hidden !== latest &&
    s.idle &&
    !s.busy &&
    !s.started.has(latest)
  )
}

/** Wieder im Vordergrund: neu prüfen, wenn schon einmal geprüft wurde und das lange genug her ist. */
export function shouldRecheckOnResume(lastCheck: number, now: number): boolean {
  return lastCheck > 0 && now - lastCheck >= RESUME_CHECK_MS
}
