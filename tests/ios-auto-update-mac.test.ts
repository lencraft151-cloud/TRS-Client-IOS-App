import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

// scripts/ios/auto-update-mac.sh läuft nur auf dem Mac. Hier läuft es in einem Wegwerf-Repo mit nachgebauten
// macOS-Werkzeugen (xcodebuild, xcrun devicectl, launchctl …), die jeden Aufruf mitschreiben.
const root = path.resolve(__dirname, '..')
const script = path.join(root, 'scripts/ios/auto-update-mac.sh')

const XCODEBUILD = `#!/bin/bash
echo "xcodebuild $*" >> "$STUB_LOG"
step="$(head -n 1 "$STUB_DIR/plan")"
sed -i '1d' "$STUB_DIR/plan"
derived=""
while [ $# -gt 0 ]; do [ "$1" = -derivedDataPath ] && derived="$2"; shift; done
case "$step" in
  ok)
    mkdir -p "$derived/Build/Products/debug-iphoneos/TRS Launcher.app"
    touch "$derived/Build/Products/debug-iphoneos/TRS Launcher.app/Info.plist"
    exit 0 ;;
  personal) echo 'error: Personal development teams, including "Max", do not support the Increased Memory Limit, Extended Virtual Addressing and App Groups capabilities.' ;;
  bundle) echo 'error: Failed Registering Bundle Identifier: The app identifier "dev.theredstonee.trslauncher" cannot be registered to your development team because it is not available.' ;;
  team) echo 'error: Signing for "trs-launcher_iOS" requires a development team. Select a development team in the Signing & Capabilities editor.' ;;
  *) echo 'error: Build input file cannot be found' ;;
esac
exit 65
`

const XCRUN = `#!/bin/bash
echo "xcrun $*" >> "$STUB_LOG"
[ "$1" = devicectl ] || exit 1
shift
args="$*"
out=""
while [ $# -gt 0 ]; do [ "$1" = --json-output ] && out="$2"; shift; done
case "$args" in
  "list devices"*) echo '{"result":{"devices":[{"identifier":"CORE-1","hardwareProperties":{"udid":"00008110-TEST","platform":"iOS","reality":"physical"},"connectionProperties":{"pairingState":"paired"},"deviceProperties":{"name":"Test-iPhone"}}]}}' > "$out" ;;
  "device info details"*) [ -z "$STUB_OFFLINE" ] || exit 1 ;;
  "device info processes"*) echo '{"result":{"runningProcesses":[]}}' > "$out" ;;
  "device install app"*) ;;
  *) exit 1 ;;
esac
`

const SIMPLE: Record<string, string> = {
  uname: 'echo Darwin',
  osascript: 'echo "osascript $*" >> "$STUB_LOG"',
  launchctl: 'echo "launchctl $*" >> "$STUB_LOG"; [ "$1" != print ]',
  plutil: 'case "$*" in *CFBundleExecutable*) echo trs-launcher ;; esac',
  security: 'exit 1',
}

let tmp: string
let repo: string
let home: string
let stubs: string

function run(mode: string, plan: string[], env: Record<string, string> = {}) {
  fs.writeFileSync(path.join(stubs, 'plan'), plan.map((s) => `${s}\n`).join(''))
  fs.writeFileSync(path.join(stubs, 'log'), '')
  const result = spawnSync('bash', [path.join(repo, 'scripts/ios/auto-update-mac.sh'), mode], {
    encoding: 'utf8',
    env: { ...process.env, HOME: home, PATH: `${stubs}:${process.env.PATH}`, STUB_DIR: stubs, STUB_LOG: path.join(stubs, 'log'), ...env },
  })
  const calls = fs.readFileSync(path.join(stubs, 'log'), 'utf8').trim().split('\n')
  return { ...result, calls, builds: calls.filter((c) => c.startsWith('xcodebuild')) }
}

const localSigning = () => fs.readFileSync(path.join(repo, 'src-tauri/gen/apple/Signing.local.xcconfig'), 'utf8')

describe.skipIf(process.platform === 'win32')('iOS: Mac hält die App aktuell (auto-update-mac.sh)', () => {
  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'trs-auto-update-'))
    repo = path.join(tmp, 'repo')
    home = path.join(tmp, 'home')
    stubs = path.join(tmp, 'bin')
    fs.mkdirSync(path.join(repo, 'scripts/ios'), { recursive: true })
    fs.mkdirSync(path.join(repo, 'src-tauri/gen/apple'), { recursive: true })
    fs.mkdirSync(home)
    fs.mkdirSync(stubs)
    fs.copyFileSync(script, path.join(repo, 'scripts/ios/auto-update-mac.sh'))
    fs.writeFileSync(path.join(repo, 'src-tauri/tauri.conf.json'), '{\n  "version": "1.2.3"\n}\n')
    fs.writeFileSync(path.join(repo, 'src-tauri/gen/apple/Signing.local.xcconfig'), 'DEVELOPMENT_TEAM = AB12CD34EF\n')
    const git = (...args: string[]) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: repo })
    git('init', '-q')
    git('add', '-A')
    git('commit', '-qm', 'init')
    fs.writeFileSync(path.join(stubs, 'xcodebuild'), XCODEBUILD, { mode: 0o755 })
    fs.writeFileSync(path.join(stubs, 'xcrun'), XCRUN, { mode: 0o755 })
    for (const [name, body] of Object.entries(SIMPLE)) fs.writeFileSync(path.join(stubs, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 })
  })

  afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }))

  it('--setup mit kostenlosem Konto: stellt Entitlements und Bundle-ID selbst um, installiert, richtet den Dienst ein', () => {
    const r = run('--setup', ['personal', 'bundle', 'ok'])
    expect(r.status, r.stdout + r.stderr).toBe(0)
    expect(r.builds).toHaveLength(3)
    // Erstes Mal: das iPhone als Ziel, damit Xcode es im Konto registriert.
    expect(r.builds[0]).toContain('-destination id=00008110-TEST -allowProvisioningDeviceRegistration')
    expect(localSigning()).toContain('TRS_ENTITLEMENTS = trs-launcher_iOS/trs-launcher_iOS-basic.entitlements')
    expect(localSigning()).toContain('TRS_WIDGET_ENTITLEMENTS = Widgets/TRSWidgets-basic.entitlements')
    expect(localSigning()).toContain('PRODUCT_BUNDLE_IDENTIFIER = dev.theredstonee.trslauncher.ab12cd34ef')
    expect(r.calls.some((c) => c.startsWith('xcrun devicectl device install app --device 00008110-TEST'))).toBe(true)
    expect(r.calls.some((c) => c.startsWith('launchctl bootstrap'))).toBe(true)
    expect(fs.existsSync(path.join(home, 'Library/LaunchAgents/de.trs-launcher.ios-auto-update.plist'))).toBe(true)
    expect(r.stdout).toContain('TRS Launcher 1.2.3')
  })

  it('baut nach einem Fehler mit dem iPhone als Ziel noch einmal für iOS allgemein', () => {
    const r = run('--setup', ['fail', 'ok'])
    expect(r.status, r.stdout + r.stderr).toBe(0)
    expect(r.builds[0]).toContain('-destination id=00008110-TEST')
    expect(r.builds[1]).toContain('-destination generic/platform=iOS')
    expect(r.builds[1]).not.toContain('-allowProvisioningDeviceRegistration')
  })

  it('iPhone nicht erreichbar: gleich „irgendein iPhone“ als Ziel', () => {
    const r = run('--setup', ['ok'], { STUB_OFFLINE: '1' })
    expect(r.status, r.stdout + r.stderr).toBe(0)
    expect(r.builds).toHaveLength(1)
    expect(r.builds[0]).toContain('-destination generic/platform=iOS')
  })

  it('echter Build-Fehler: kein Dienst, Hinweis zur Apple-ID, keine Endlosschleife', () => {
    const r = run('--setup', ['team', 'team', 'team', 'team'])
    expect(r.status).not.toBe(0)
    expect(r.builds).toHaveLength(2)
    expect(r.stdout + r.stderr).toContain('Settings → Accounts')
    expect(r.calls.some((c) => c.includes('device install'))).toBe(false)
    expect(r.calls.some((c) => c.startsWith('launchctl bootstrap'))).toBe(false)
  })

  it('stellt nichts um, was schon passt (Entitlements bleiben, eigene Bundle-ID bleibt)', () => {
    fs.appendFileSync(path.join(repo, 'src-tauri/gen/apple/Signing.local.xcconfig'), 'PRODUCT_BUNDLE_IDENTIFIER = de.max.trs\n')
    const r = run('--setup', ['bundle', 'bundle'], { STUB_OFFLINE: '1' })
    expect(r.status).not.toBe(0)
    expect(r.builds).toHaveLength(1)
    expect(localSigning()).toContain('PRODUCT_BUNDLE_IDENTIFIER = de.max.trs')
    expect(localSigning()).not.toContain('trslauncher.ab12cd34ef')
  })

  it('Sperre: Hintergrund-Lauf überspringt, wenn schon einer läuft; hängengebliebene Sperre wird aufgeräumt', () => {
    run('--setup', ['ok'])
    const lock = path.join(home, 'Library/Application Support/TRS-Launcher-AutoUpdate/lock')
    fs.mkdirSync(lock)
    const busy = run('--run', [])
    expect(busy.status).toBe(0)
    expect(busy.stdout).toContain('läuft schon')
    const old = new Date(Date.now() - 4 * 3600 * 1000)
    fs.utimesSync(lock, old, old)
    const stale = run('--now', ['ok'])
    expect(stale.status, stale.stdout + stale.stderr).toBe(0)
    expect(stale.builds).toHaveLength(1)
    expect(fs.existsSync(lock)).toBe(false)
  })

  it('--find-device meldet das gepaarte iPhone', () => {
    const r = run('--find-device', [])
    expect(r.status).toBe(0)
    expect(r.stdout.trim()).toBe('00008110-TEST\tTest-iPhone')
  })
})
