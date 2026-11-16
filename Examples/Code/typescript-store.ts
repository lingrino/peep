// A typed event emitter and a small store built on it.
export type Listener<T> = (payload: T) => void;

export interface Todo {
  id: number;
  title: string;
  done: boolean;
  tags?: string[];
}

export class Emitter<Events extends Record<string, unknown>> {
  private listeners = new Map<keyof Events, Set<Listener<any>>>();

  on<K extends keyof Events>(event: K, fn: Listener<Events[K]>): () => void {
    const set = this.listeners.get(event) ?? new Set();
    set.add(fn);
    this.listeners.set(event, set);
    return () => set.delete(fn);
  }

  emit<K extends keyof Events>(event: K, payload: Events[K]): void {
    this.listeners.get(event)?.forEach((fn) => fn(payload));
  }
}

type StoreEvents = { added: Todo; toggled: Todo; cleared: number };

export class TodoStore extends Emitter<StoreEvents> {
  private todos: Todo[] = [];
  private nextId = 1;

  add(title: string, tags: string[] = []): Todo {
    const todo: Todo = { id: this.nextId++, title: title.trim(), done: false, tags };
    this.todos.push(todo);
    this.emit("added", todo);
    return todo;
  }

  toggle(id: number): Todo | undefined {
    const todo = this.todos.find((t) => t.id === id);
    if (!todo) return undefined;
    todo.done = !todo.done;
    this.emit("toggled", todo);
    return todo;
  }

  clearDone(): number {
    const before = this.todos.length;
    this.todos = this.todos.filter((t) => !t.done);
    const removed = before - this.todos.length;
    this.emit("cleared", removed);
    return removed;
  }

  get remaining(): number {
    return this.todos.filter((t) => !t.done).length;
  }
}

export function summarize(store: TodoStore): string {
  return `${store.remaining} left`;
}

const store = new TodoStore();
store.on("added", (t) => console.log(`added #${t.id}: ${t.title}`));
store.add("Write the examples folder", ["peep"]);
console.log(summarize(store), /^\d+ left$/.test(summarize(store)), 0xff, 1e3);
