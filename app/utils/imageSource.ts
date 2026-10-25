import { ref } from 'vue'
import type { OsName } from './system'
import { hostOs } from './system'

/** Woher Bilder kommen (iOS): Mediathek („Fotos“) oder Dateien-App. Rust: `image_pick::ImageSource`. */
export type ImageSource = 'photos' | 'files'

/** Offene Frage „Fotos oder Dateien?“ (das Blatt `ImageSourceSheet` zeigt sie). */
export const imageSourceQuestion = ref<{ resolve: (source: ImageSource | null) => void } | null>(null)

/**
 * Vor dem Hochladen eines Bildes fragen, woher es kommt. Nur auf iOS: Der Dateidialog dort kennt bei Bildern sonst nur
 * die Mediathek – Skins aus Safari-Downloads liegen aber in „Dateien“. Andere Systeme: `undefined` (gewohnter Dialog).
 * `null` = abgebrochen.
 */
export function chooseImageSource(os: OsName = hostOs): Promise<ImageSource | null | undefined> {
  if (os !== 'ios') return Promise.resolve(undefined)
  // Eine noch offene Frage gilt als abgebrochen.
  imageSourceQuestion.value?.resolve(null)
  return new Promise((resolve) => {
    imageSourceQuestion.value = { resolve }
  })
}

/** Antwort aus dem Blatt (oder `null`, wenn es geschlossen wurde). */
export function answerImageSource(source: ImageSource | null): void {
  const question = imageSourceQuestion.value
  imageSourceQuestion.value = null
  question?.resolve(source)
}
