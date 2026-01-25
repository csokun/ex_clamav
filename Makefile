.PHONY: all clean

MIX_APP_PATH ?= $(shell pwd)

PRIV = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/lib/native/build
NIF_SRC_DIR = lib/native/clamav_nif/src

SRC = $(wildcard $(NIF_SRC_DIR)/*.c)
HEADERS = $(wildcard $(NIF_SRC_DIR)/*.h)
OBJ = $(patsubst $(NIF_SRC_DIR)/%.c,$(BUILD)/%.o,$(SRC))

CFLAGS = -std=c11 -O3 -Wall -Wextra -Wpedantic \
         -fPIC -I$(ERTS_INCLUDE_DIR) \
         -I/usr/local/include -I/usr/include

LDFLAGS = -shared -L/usr/local/lib -L/usr/lib -lclamav

ifeq ($(shell uname -s),Darwin)
  LDFLAGS += -undefined dynamic_lookup
endif

all: $(PRIV)/clamav_nif.so

$(PRIV)/clamav_nif.so: $(OBJ)
	@mkdir -p $(PRIV)
	$(CC) $(OBJ) $(LDFLAGS) -o $@

$(BUILD)/%.o: $(NIF_SRC_DIR)/%.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(PRIV)/clamav_nif.so $(BUILD)

install-deps:
	# Install libclamav development packages
	sudo apt-get install -y libclamav-dev clamav  # Debian/Ubuntu
	# or: sudo yum install clamav-devel clamav    # RHEL/CentOS
