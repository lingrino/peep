<template>
  <article class="card" :class="{ done: todo.done }">
    <h2>{{ todo.title }}</h2>
    <button @click="$emit('toggle', todo.id)">Toggle</button>
  </article>
</template>

<script setup lang="ts">
defineProps<{ todo: { id: number; title: string; done: boolean } }>();
defineEmits<{ toggle: [id: number] }>();
</script>

<style scoped>
.card { padding: 1rem; border-radius: 8px; }
.done h2 { text-decoration: line-through; }
</style>
