// Package cache implements a small LRU cache with expiry.
package cache

import (
	"container/list"
	"errors"
	"sync"
	"time"
)

// ErrNotFound is returned when a key is missing or expired.
var ErrNotFound = errors.New("cache: not found")

// Entry is one cached value.
type Entry struct {
	Key     string
	Value   []byte
	Expires time.Time
}

// Cache is safe for concurrent use.
type Cache struct {
	mu       sync.Mutex
	capacity int
	ttl      time.Duration
	order    *list.List
	items    map[string]*list.Element
}

// New returns a cache holding at most capacity entries.
func New(capacity int, ttl time.Duration) *Cache {
	return &Cache{capacity: capacity, ttl: ttl, order: list.New(), items: make(map[string]*list.Element)}
}

// Get returns the value for key, refreshing its position.
func (c *Cache) Get(key string) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	el, ok := c.items[key]
	if !ok {
		return nil, ErrNotFound
	}
	e := el.Value.(*Entry)
	if time.Now().After(e.Expires) {
		c.removeElement(el)
		return nil, ErrNotFound
	}
	c.order.MoveToFront(el)
	return e.Value, nil
}

// Set stores value under key, evicting the least recently used entry if full.
func (c *Cache) Set(key string, value []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if el, ok := c.items[key]; ok {
		el.Value.(*Entry).Value = value
		c.order.MoveToFront(el)
		return
	}
	if c.order.Len() >= c.capacity {
		c.removeElement(c.order.Back())
	}
	c.items[key] = c.order.PushFront(&Entry{Key: key, Value: value, Expires: time.Now().Add(c.ttl)})
}

func (c *Cache) removeElement(el *list.Element) {
	c.order.Remove(el)
	delete(c.items, el.Value.(*Entry).Key)
}

// Len reports the number of entries, including expired ones not yet evicted.
func (c *Cache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.order.Len()
}
