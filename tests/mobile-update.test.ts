import { describe, expect, it } from 'vitest'
import type { MobileUpdateStatus } from '../app/types'
import { RESUME_CHECK_MS, shouldAutoInstall, shouldRecheckOnResume, type AutoInstallState } from '../app/utils/mobileUpdate'

const status: MobileUpdateStatus = {
  current: '0.28.0.40',
  latest: '0.28.1.41',
  available: true,
  notes: '',
  pubDate: null,
  size: null,
  altstoreSource: null,
  installUrl: 'itms-services://?action=download-manifest&url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fmanifest.plist',
  beta: false,
  betaChannel: true,
}
const state: AutoInstallState = { os: 'ios', status, hidden: null, idle: true, busy: false, started: new Set() }

describe('Automatische App-Updates (iOS)', () => {
  it('installiert eine neue, signierte Version von selbst, wenn nichts läuft', () => {
    expect(shouldAutoInstall(state)).toBe(true)
  })

  it('nie während Spiel/Download/Einrichtung, nach „Später“ oder zweimal je Version', () => {
    expect(shouldAutoInstall({ ...state, idle: false })).toBe(false)
    expect(shouldAutoInstall({ ...state, busy: true })).toBe(false)
    expect(shouldAutoInstall({ ...state, hidden: '0.28.1.41' })).toBe(false)
    expect(shouldAutoInstall({ ...state, started: new Set(['0.28.1.41']) })).toBe(false)
    // Neuere Version nach einer abgelehnten: wieder anbieten.
    expect(shouldAutoInstall({ ...state, status: { ...status, latest: '0.28.1.42' }, started: new Set(['0.28.1.41']) })).toBe(true)
  })

  it('nur auf iOS und nur mit OTA-Link (mit Profil signierte IPA)', () => {
    expect(shouldAutoInstall({ ...state, os: 'android' })).toBe(false)
    expect(shouldAutoInstall({ ...state, status: { ...status, installUrl: null } })).toBe(false)
    expect(shouldAutoInstall({ ...state, status: { ...status, available: false } })).toBe(false)
    expect(shouldAutoInstall({ ...state, status: null })).toBe(false)
  })

  it('prüft beim Zurückkehren in die App nur nach längerer Pause neu', () => {
    expect(shouldRecheckOnResume(0, 10 * RESUME_CHECK_MS)).toBe(false)
    expect(shouldRecheckOnResume(1000, 1000 + RESUME_CHECK_MS - 1)).toBe(false)
    expect(shouldRecheckOnResume(1000, 1000 + RESUME_CHECK_MS)).toBe(true)
  })
})
