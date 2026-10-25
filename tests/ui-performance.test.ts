import fs from 'node:fs'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { Palette } from '../app/utils/redstone/palette'

const root = path.resolve(__dirname, '..')

function files(dir: string, exts: string[]): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const full = path.join(dir, e.name)
    if (e.isDirectory()) return files(full, exts)
    return exts.some((x) => e.name.endsWith(x)) ? [full] : []
  })
}

/** Inhalt jedes `@keyframes`-Blocks (mit verschachtelten Klammern). */
function keyframes(css: string): { name: string; body: string }[] {
  const out: { name: string; body: string }[] = []
  for (const m of css.matchAll(/@keyframes\s+([\w-]+)\s*\{/g)) {
    let i = m.index! + m[0].length
    let depth = 1
    const start = i
    while (depth && i < css.length) {
      if (css[i] === '{') depth++
      else if (css[i] === '}') depth--
      i++
    }
    out.push({ name: m[1]!, body: css.slice(start, i - 1) })
  }
  return out
}

describe('Oberfläche bleibt flüssig', () => {
  it('keine Animation bewegt Höhe, Breite, Abstände oder Position (sonst Layout in jedem Bild – am Handy spürbar)', () => {
    const layout = /(?<![-\w])(height|width|top|left|right|bottom|inset|margin[-\w]*|padding[-\w]*|(?:min|max)-(?:height|width))\s*:/
    const problems: string[] = []
    for (const file of [...files(path.join(root, 'app'), ['.vue', '.css']), path.join(root, 'app/spa-loading-template.html')]) {
      for (const { name, body } of keyframes(fs.readFileSync(file, 'utf8'))) {
        const hit = body.match(layout)
        if (hit) problems.push(`${path.relative(root, file)}: @keyframes ${name} animiert „${hit[1]}“ – transform/opacity nehmen`)
      }
    }
    expect(problems).toEqual([])
  })

  it('Ladebildschirm: die Mond-Animation endet, sobald die App den Ladebildschirm entfernt', () => {
    const html = fs.readFileSync(path.join(root, 'app/spa-loading-template.html'), 'utf8')
    const loop = html.match(/requestAnimationFrame\(paint\)/g) ?? []
    expect(loop.length).toBeGreaterThan(0)
    // Jede Wiederholung (in paint) prüft, ob die Fläche noch im Dokument hängt.
    expect(html).toMatch(/if \(!reduced && canvas\.isConnected\) requestAnimationFrame\(paint\)/)
  })
})

// --- Redstone-Boden: Pixelpuffer statt fillRect je Texel -------------------------------------------------------

/** Minimales 2D-Canvas für Node: kennt #rrggbb, fillRect, clearRect und die ImageData-Wege. */
class FakeCanvas {
  pixels: Uint8ClampedArray
  readonly ctx = new FakeCtx(this)
  constructor(
    public width: number,
    public height: number,
  ) {
    this.pixels = new Uint8ClampedArray(width * height * 4)
  }
  getContext() {
    return this.ctx
  }
}

class FakeCtx {
  fillStyle = '#000000'
  fillRects = 0
  constructor(private readonly c: FakeCanvas) {}
  private set(x: number, y: number, rgba: number[]) {
    if (x < 0 || y < 0 || x >= this.c.width || y >= this.c.height) return
    this.c.pixels.set(rgba, (y * this.c.width + x) * 4)
  }
  fillRect(x: number, y: number, w: number, h: number) {
    this.fillRects++
    const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(this.fillStyle)
    if (!m) throw new Error(`Farbe im Test nicht unterstützt: ${this.fillStyle}`)
    const rgba = [parseInt(m[1]!, 16), parseInt(m[2]!, 16), parseInt(m[3]!, 16), 255]
    for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) this.set(xx, yy, rgba)
  }
  clearRect(x: number, y: number, w: number, h: number) {
    for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) this.set(xx, yy, [0, 0, 0, 0])
  }
  createImageData(w: number, h: number) {
    return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }
  }
  getImageData(x: number, y: number, w: number, h: number) {
    const img = this.createImageData(w, h)
    for (let yy = 0; yy < h; yy++) img.data.set(this.c.pixels.subarray(((y + yy) * this.c.width + x) * 4, ((y + yy) * this.c.width + x + w) * 4), yy * w * 4)
    return img
  }
  putImageData(img: { width: number; height: number; data: Uint8ClampedArray }, x: number, y: number) {
    for (let yy = 0; yy < img.height; yy++) this.c.pixels.set(img.data.subarray(yy * img.width * 4, (yy + 1) * img.width * 4), ((y + yy) * this.c.width + x) * 4)
  }
}

describe('Redstone-Hintergrund: Boden in einem Rutsch', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.resetModules()
  })

  it('gleiche Pixel wie Texel für Texel gemalt – mit einer Handvoll statt Zehntausender Zeichenaufrufe', async () => {
    vi.stubGlobal('OffscreenCanvas', FakeCanvas)
    const { paintFloor, paintFloorBlock, TEX } = await import('../app/utils/redstone/paint')
    const palette = { grout: '#15151a', floor: ['#26262e', '#2c2c35', '#33333d'] } as unknown as Palette
    for (const [w, h] of [
      [8, 17],
      [24, 12],
    ] as const) {
      const floor = paintFloor({ w, h } as never, palette) as unknown as FakeCanvas
      const reference = new FakeCanvas(w * TEX, h * TEX)
      for (let by = 0; by < h; by++) for (let bx = 0; bx < w; bx++) paintFloorBlock(reference.ctx as never, bx * TEX, by * TEX, bx, by, palette)
      expect(floor.width).toBe(w * TEX)
      expect(Buffer.from(floor.pixels).equals(Buffer.from(reference.pixels))).toBe(true)
      expect(floor.ctx.fillRects).toBe(0)
      expect(reference.ctx.fillRects).toBe(w * h * TEX * TEX)
    }
  })
})
