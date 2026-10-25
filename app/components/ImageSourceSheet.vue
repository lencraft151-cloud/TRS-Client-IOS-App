<script setup lang="ts">
// iOS: „Fotos oder Dateien?“ vor dem Hochladen eines Bildes (Skins, Symbole, Banner, Chat, Umhänge).
// Die Frage stellt `chooseImageSource()`; dieses Blatt beantwortet sie.
import { answerImageSource, imageSourceQuestion, type ImageSource } from '~/utils/imageSource'
import { icons } from '~/utils/icons'
import type { MessageKey } from '~/utils/i18n'

const options: { source: ImageSource; icon: keyof typeof icons; label: MessageKey; hint: MessageKey }[] = [
  { source: 'photos', icon: 'image', label: 'imageSource.photos', hint: 'imageSource.photosHint' },
  { source: 'files', icon: 'storage', label: 'imageSource.files', hint: 'imageSource.filesHint' },
]
</script>

<template>
  <MobileSheet v-if="imageSourceQuestion" :title="t('imageSource.title')" @close="answerImageSource(null)">
    <div class="grid grid-cols-2 gap-2 pb-1" data-testid="image-source-sheet">
      <button
        v-for="option in options"
        :key="option.source"
        class="flex min-h-24 flex-col items-center justify-center gap-1.5 rounded-xl border border-base-800 bg-base-900 px-2 py-3 text-center transition-colors active:bg-base-700"
        :data-testid="`image-source-${option.source}`"
        @click="answerImageSource(option.source)"
      >
        <svg viewBox="0 0 24 24" class="size-7 text-base-200" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path :d="icons[option.icon]" />
        </svg>
        <span class="text-sm font-semibold text-base-50">{{ t(option.label) }}</span>
        <span class="text-xs leading-tight text-base-400">{{ t(option.hint) }}</span>
      </button>
    </div>
  </MobileSheet>
</template>
