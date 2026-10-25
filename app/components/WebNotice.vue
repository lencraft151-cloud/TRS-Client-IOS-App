<script setup lang="ts">
// Web-Version: kurzer Hinweis, was im Browser geht und was nur in der App. Einmal weggeklickt, bleibt er weg
// (in diesem Browser).
const KEY = 'trs.web.noticeHidden'
const hidden = ref(true)

onMounted(() => {
  try {
    hidden.value = localStorage.getItem(KEY) === '1'
  } catch {
    hidden.value = false
  }
})

function dismiss() {
  hidden.value = true
  try {
    localStorage.setItem(KEY, '1')
  } catch {}
}
</script>

<template>
  <div v-if="!hidden" class="px-4 pt-3 pb-1" data-testid="web-notice">
    <div class="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-xl border border-base-700 bg-base-850/95 px-4 py-3 shadow-lg shadow-black/30 backdrop-blur-sm" role="note">
      <div class="min-w-0 flex-1 text-sm">
        <p class="font-semibold text-base-50">{{ t('web.title') }}</p>
        <p class="text-xs text-base-300">{{ t('web.body') }}</p>
      </div>
      <button class="btn btn-ghost px-3 py-1.5 text-xs" data-testid="web-notice-dismiss" @click="dismiss">{{ t('web.dismiss') }}</button>
    </div>
  </div>
</template>
