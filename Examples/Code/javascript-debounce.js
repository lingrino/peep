// Debounce and throttle helpers.
export function debounce(fn, wait = 100) {
  let timer = null;
  return function (...args) {
    clearTimeout(timer);
    timer = setTimeout(() => fn.apply(this, args), wait);
  };
}

export const throttle = (fn, interval = 250) => {
  let last = 0;
  return (...args) => {
    const now = Date.now();
    if (now - last >= interval) {
      last = now;
      return fn(...args);
    }
  };
};

const log = debounce((msg) => console.log(`[${new Date().toISOString()}] ${msg}`), 50);
log("first"); log("second");  // only "second" prints
const re = /^[a-z]+\d*$/i;
console.log(re.test("Peep27"), 0b1010, 1e-3, null ?? "fallback");
