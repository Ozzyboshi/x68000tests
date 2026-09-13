# =============================================================================
# X68000 demo - build with vasm, package into a floppy image for the emulator
#
#   make            convert the logo and assemble DEMO.X
#   make disk       2HD .XDF data disk containing DEMO.X, built on Linux
#   make bootdisk   copy of your Human68k system disk that boots the demo
#   make run        launch the emulator
#   make dump       inspect an image (IMG=... for an external one)
#   make clean
#
# Requirements: vasm with the m68k/mot frontend, python3. No mtools: mformat
# writes an MS-DOS BPB, which Human68k does not understand - mkxdf.py writes
# the real thing. See the comment at the top of mkxdf.py.
#
# "disk" is a DATA disk: boot Human68k in FDD0, mount this in FDD1, then B:
# and DEMO. "bootdisk" is a full Human68k disk that starts the demo by itself,
# and can equally be browsed from a file manager or run from the prompt.
# =============================================================================

# to compile everything: make clean && make && make bootdisk SYSDISK=Human68k.xdf && make disk

# ---- toolchain --------------------------------------------------------------
VASM       ?= vasmm68k_mot
PYTHON     ?= python3
EMU        ?= px68k                  # or xm6, xm6g, ...

# ---- project ----------------------------------------------------------------
SRC        := demo_chunky.s
LIB        := x68k_screen_sprite_lib.s
TARGET     := DEMO.X
ENTRY      := Main
LABEL      := DEMO

LOGO_PNG   := sharp-x68000-logo-1_zrkb.1280.png
LOGO_RAW   := sharp-x68000-logo-1_zrkb.1280.raw
LOGO_SIZE  := 320x240
PNG2X68K   := ./png2x68k.py

VASMFLAGS  := -Fxfile -m68000 -exec=$(ENTRY) -I. -nosym -no-opt

MKXDF      := ./mkxdf.py
DISK       := build/demo.xdf

# Your own Human68k system disk - it is only read, never modified.
#   make bootdisk SYSDISK=~/x68000/HUMAN302.XDF
SYSDISK    ?= HUMAN302.XDF
BOOTDISK   := build/boot.xdf

.PHONY: all disk bootdisk run dump clean
.DEFAULT_GOAL := all

# Build the demo image first, unless an external one was named with IMG=
ifeq ($(IMG),)
DUMP_DEP := $(DISK)
else
DUMP_DEP :=
endif

all: $(TARGET)

# ---- logo PNG -> X68k RAW ---------------------------------------------------
# --size refuses to convert anything that is not exactly the expected size,
# instead of silently producing a file with the wrong stride.
$(LOGO_RAW): $(LOGO_PNG) $(PNG2X68K)
	$(PYTHON) $(PNG2X68K) $(LOGO_PNG) -o $@ --size $(LOGO_SIZE)

# ---- assemble ---------------------------------------------------------------
# The raw logo is an incbin dependency: without it here, changing the PNG
# would rebuild the .raw but leave the old image inside DEMO.X.
$(TARGET): $(SRC) $(LIB) $(LOGO_RAW)
	$(VASM) $(VASMFLAGS) -o $@ $(SRC)

# ---- data disk --------------------------------------------------------------
# 2HD: 77 cylinders x 2 heads x 8 sectors x 1024 bytes = 1,261,568 bytes
$(DISK): $(TARGET) $(MKXDF)
	@mkdir -p build
	$(PYTHON) $(MKXDF) -o $@ -l $(LABEL) $(TARGET)

disk: $(DISK)

# ---- bootable disk ----------------------------------------------------------
# Copy of your Human68k system disk with DEMO.X and an AUTOEXEC.BAT added, so
# the emulator boots straight into the demo. Human68k cannot be redistributed,
# hence SYSDISK. Re-running this replaces the files instead of duplicating
# them, so the disk can be rebuilt as often as you like.
$(BOOTDISK): $(TARGET) $(MKXDF)
	@test -f "$(SYSDISK)" || { \
	  echo "*** $(SYSDISK) not found."; \
	  echo "*** make bootdisk SYSDISK=/path/to/your/Human68k.xdf"; \
	  exit 1; }
	@mkdir -p build
	$(PYTHON) $(MKXDF) --inject "$(SYSDISK)" -o $@ --autoexec $(TARGET) $(TARGET)

bootdisk: $(BOOTDISK)

# ---- inspect ----------------------------------------------------------------
# BPB read both ways plus the root directory. Point it at a real Human68k disk
# to confirm the on-disk layout:
#   make dump IMG=~/x68000/HUMAN302.XDF
dump: $(DUMP_DEP)
	$(PYTHON) $(MKXDF) --dump $(or $(IMG),$(DISK))

# ---- run --------------------------------------------------------------------
# px68k takes images on the command line; XM6 / XM6 TypeG are GUI driven, so
# there you mount the image in FDD0 (bootdisk) or FDD1 (data disk).
run: $(BOOTDISK)
	$(EMU) $(BOOTDISK)

clean:
	rm -f $(TARGET) $(LOGO_RAW)
	rm -rf build