# Simple C project
CC      ?= clang
CFLAGS  := -O2 -Wall -Wextra -std=c17
SRCS    := $(wildcard src/*.c)
OBJS    := $(SRCS:src/%.c=build/%.o)

.PHONY: all clean test

all: build/app

build/app: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c -o $@ $<

build:
	mkdir -p $@

test: build/app
	./build/app --self-test

clean:
	rm -rf build
