# Makefile comment
CC ?= gcc
CFLAGS := -O2 -Wall
SRC = $(wildcard src/*.c)
OBJ = $(SRC:.c=.o)
export PATH

.PHONY: all clean

all: app

app: $(OBJ)
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c
	@echo "compiling $<"
	$(CC) -c $< -o $@

clean:
	rm -f $(OBJ) app

ifeq ($(DEBUG),1)
CFLAGS += -g
endif
include config.mk
