<script>
  let count = $state(0);
  let doubled = $derived(count * 2);
</script>

<button onclick={() => count++}>
  Clicked {count} {count === 1 ? "time" : "times"}
</button>
<p>Doubled: {doubled}</p>

<style>
  button { font-size: 1.25rem; }
</style>
