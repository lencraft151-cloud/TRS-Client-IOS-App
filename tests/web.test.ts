import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { publicUrl, RECHECK_AFTER_MS, shouldRecheck } from '../app/utils/web'

const root = path.resolve(__dirname, '..')

function files(dir: string, ext: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const full = path.join(dir, e.name)
    if (e.isDirectory()) return files(full, ext)
    return e.name.endsWith(ext) ? [full] : []
  })
}

describe('Web-Version: Dateien aus public/ unter dem Unterpfad', () => {
  it('lässt Pfade in der App (Basis /) unverändert', () => {
    expect(publicUrl('/icon.png')).toBe('/icon.png')
    expect(publicUrl('/news/0.29.0/banner.png', '/')).toBe('/news/0.29.0/banner.png')
  })

  it('setzt auf GitHub Pages den Unterpfad davor', () => {
    expect(publicUrl('/icon.png', '/TRS-Client-IOS-App/')).toBe('/TRS-Client-IOS-App/icon.png')
    expect(publicUrl('/flags/de.svg', '/TRS-Client-IOS-App')).toBe('/TRS-Client-IOS-App/flags/de.svg')
  })

  it('lässt fremde, relative und Daten-Adressen in Ruhe', () => {
    for (const url of ['https://cdn.modrinth.com/a.png', '//example.org/a.png', 'icon.png', 'data:image/png;base64,AA==', 'blob:x']) {
      expect(publicUrl(url, '/TRS-Client-IOS-App/')).toBe(url)
    }
  })

  it('kein fester Pfad auf public/ ohne publicUrl() (sonst fehlt das Bild in der Web-Version)', () => {
    const publicDirs = fs.readdirSync(path.join(root, 'public')).map((n) => n.replace(/[.]/g, '\\.'))
    const absolute = new RegExp(`(?<!publicUrl\\()[\`'"]/(?:${publicDirs.join('|')})(?:[/\`'"]|$)`)
    const problems: string[] = []
    for (const file of files(path.join(root, 'app'), '.vue')) {
      if (file.includes(`${path.sep}dev${path.sep}`)) continue
      fs.readFileSync(file, 'utf8')
        .split('\n')
        .forEach((line, i) => {
          if (absolute.test(line) || /\ssrc="\/(?!\/)/.test(line)) problems.push(`${path.relative(root, file)}:${i + 1}: ${line.trim()}`)
        })
    }
    expect(problems).toEqual([])
  })
})

describe('Web-Version: immer aktuell', () => {
  it('schaut nach einer Pause im Hintergrund gleich nach einer neuen Version', () => {
    expect(shouldRecheck(0, RECHECK_AFTER_MS - 1)).toBe(false)
    expect(shouldRecheck(0, RECHECK_AFTER_MS)).toBe(true)
  })

  it('Service Worker trägt den Platzhalter, den der Workflow durch den Commit ersetzt', () => {
    const sw = fs.readFileSync(path.join(root, 'web/public/sw.js'), 'utf8')
    const workflow = fs.readFileSync(path.join(root, '.github/workflows/web-app.yml'), 'utf8')
    expect(sw).toContain("const BUILD = '__TRS_BUILD__'")
    expect(workflow).toContain('s/__TRS_BUILD__/${GITHUB_SHA}/')
    // Versionsprüfung nie aus dem Cache – sonst bliebe die App auf der alten Version.
    expect(sw).toContain("if (path.startsWith('_nuxt/builds/')) return")
  })

  it('Manifest: alle Symbole gibt es (public/ bzw. Symbole des iOS-Projekts unter app-icons/)', () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(root, 'web/public/manifest.webmanifest'), 'utf8'))
    expect(manifest.start_url).toBe('./')
    expect(manifest.display).toBe('standalone')
    for (const icon of manifest.icons as { src: string; sizes: string }[]) {
      const file = icon.src.startsWith('app-icons/')
        ? path.join(root, 'src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset', icon.src.slice('app-icons/'.length))
        : path.join(root, 'public', icon.src)
      expect(fs.existsSync(file), icon.src).toBe(true)
      const png = fs.readFileSync(file)
      const [w, h] = icon.sizes.split('x').map(Number)
      expect([png.readUInt32BE(16), png.readUInt32BE(20)], icon.src).toEqual([w, h])
    }
  })
})
