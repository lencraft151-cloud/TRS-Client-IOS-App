import { describe, expect, it } from 'vitest'
import { answerImageSource, chooseImageSource, imageSourceQuestion } from '../app/utils/imageSource'

describe('Bildquelle (iOS: Fotos oder Dateien)', () => {
  it('fragt nur auf iOS', async () => {
    expect(await chooseImageSource('windows')).toBeUndefined()
    expect(await chooseImageSource('android')).toBeUndefined()
    expect(imageSourceQuestion.value).toBeNull()
  })

  it('liefert die Antwort aus dem Blatt', async () => {
    const asked = chooseImageSource('ios')
    expect(imageSourceQuestion.value).not.toBeNull()
    answerImageSource('photos')
    expect(await asked).toBe('photos')
    expect(imageSourceQuestion.value).toBeNull()
  })

  it('Schließen bricht ab, eine neue Frage ersetzt die alte', async () => {
    const first = chooseImageSource('ios')
    const second = chooseImageSource('ios')
    expect(await first).toBeNull()
    answerImageSource(null)
    expect(await second).toBeNull()
    // Antwort ohne offene Frage: nichts passiert.
    answerImageSource('files')
    expect(imageSourceQuestion.value).toBeNull()
  })
})
