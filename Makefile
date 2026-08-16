CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -fPIC
LDLIBS  ?= -ldl -lpthread -lrt

BUILD   := build
LIB     := $(BUILD)/libsafeunlink.so
DAEMON  := $(BUILD)/safeunlinkd
HOLD    := $(BUILD)/hold
DCLIENT := $(BUILD)/dclient
TRASHFLOW := $(BUILD)/trashflow

COMMON_SRC := src/snapshot.c

.PHONY: all install test clean

all: $(LIB) $(DAEMON) $(HOLD) $(DCLIENT) $(TRASHFLOW)

$(LIB): src/safeunlink.c $(COMMON_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -shared -o $@ src/safeunlink.c $(COMMON_SRC) $(LDLIBS)

$(DAEMON): src/safeunlinkd.c $(COMMON_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ src/safeunlinkd.c $(COMMON_SRC) $(LDLIBS)

$(HOLD): tests/hold.c | $(BUILD)
	$(CC) -O2 -Wall -o $@ $<

$(DCLIENT): tests/dclient.c | $(BUILD)
	$(CC) -O2 -Wall -o $@ $<

$(TRASHFLOW): tests/trashflow.c | $(BUILD)
	$(CC) -O2 -Wall -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

test: all
	LIB=$(LIB) HOLD=$(HOLD) DCLIENT=$(DCLIENT) DAEMON=$(DAEMON) bash tests/run_tests.sh

install: all
	sudo install -Dm755 $(LIB) /usr/local/lib/libsafeunlink.so
	sudo install -Dm755 $(DAEMON) /usr/local/bin/safeunlinkd
	sudo ldconfig
	@echo "已安装: /usr/local/lib/libsafeunlink.so 与 /usr/local/bin/safeunlinkd"
	@echo "用法: bin/safe-rm ...   或   safeunlinkd start  (常驻守护)"

clean:
	rm -rf $(BUILD)
