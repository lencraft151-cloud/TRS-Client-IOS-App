import { describe, expect, it } from 'vitest'
import { crashReportKind, crashReportSchema, unseenReports, type CrashReport } from '../app/utils/crashReport'

function report(id: string, seen = false): CrashReport {
  return { id, kind: 'ios', time: '2026-10-23T08:00:00Z', title: 'EXC_BREAKPOINT / SIGTRAP', text: 'Aufrufstapel …', seen }
}

describe('Absturzberichte (iOS)', () => {
  it('liest die Antwort von crash_reports', () => {
    const parsed = crashReportSchema.parse({ ...report('ios-20261023-080000.txt'), time: null })
    expect(parsed.time).toBeNull()
    expect(() => crashReportSchema.parse({ ...report('x'), text: 'x'.repeat(80_000) })).toThrow()
  })

  it('zeigt nur neue Berichte, höchstens zehn', () => {
    const list = [report('a', true), ...Array.from({ length: 12 }, (_, i) => report(`n${i}`))]
    const unseen = unseenReports(list)
    expect(unseen).toHaveLength(10)
    expect(unseen.every((r) => !r.seen)).toBe(true)
    expect(unseen[0]!.id).toBe('n0')
  })

  it('kennt die Arten und fällt sonst auf „unknown“ zurück', () => {
    for (const kind of ['panic', 'ios', 'hang', 'unclean', 'boot']) expect(crashReportKind(kind)).toBe(kind)
    expect(crashReportKind('neu')).toBe('unknown')
  })
})
