import { describe, expect, it } from 'vitest'
import { tourStepName, UI_TOUR_ROUTES } from '../app/utils/uiTour'

describe('Klick-Test (CI)', () => {
  it('benennt Seiten so, wie das Skript sie als Dateinamen nutzt', () => {
    expect(tourStepName('/')).toBe('page-home')
    expect(tourStepName('/instances')).toBe('page-instances')
    for (const path of UI_TOUR_ROUTES) expect(tourStepName(path)).toMatch(/^[a-z0-9-]+$/)
  })

  it('besucht die Startseite zuerst und jede Seite nur einmal', () => {
    expect(UI_TOUR_ROUTES[0]).toBe('/')
    expect(new Set(UI_TOUR_ROUTES).size).toBe(UI_TOUR_ROUTES.length)
  })
})
