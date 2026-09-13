# =============================================================================
# X68000 demo - build with vasm, package into a floppy image for the emulator
#
#   make            assemble DEMO.X (Human68k executable)
#   make disk       2HD .XDF image containing DEMO.X, built entirely on Linux
#   make run        launch the emulator on it
#   make clean
#
# Requirements: vasm with the m68k/mot frontend, python3. No mtools: mformat
# writes an MS-DOS BPB, which Human68k does not understand - mkxdf.py writes
# the real thing. See the comment at the top of mkxdf.py.
#
# The image is a DATA disk, not bootable. Boot your Human68k system disk in
# FDD0, mount this one in FDD1, then at the prompt:  B:  then  DEMO
# =============================================================================

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
PNG2X68K   := ./png2x68k.py

VASMFLAGS  := -Fxfile -m68000 -exec=$(ENTRY) -I. -nosym -no-opt

MKXDF      := ./mkxdf.py
DISK       := build/demo.xdf

.PHONY: all disk run dump clean
.DEFAULT_GOAL := all

all: $(TARGET) $(LOGO_RAW)

# ---- logo PNG -> X68k RAW ---------------------------------------------------
$(LOGO_RAW): $(LOGO_PNG) $(PNG2X68K)
	$(PYTHON) $(PNG2X68K) $(LOGO_PNG) -o $@

# ---- assemble ---------------------------------------------------------------
$(TARGET): $(SRC) $(LIB)
	$(VASM) $(VASMFLAGS) -o $@ $(SRC)

# ---- floppy image -----------------------------------------------------------
# 2HD: 77 cylinders x 2 heads x 8 sectors x 1024 bytes = 1,261,568 bytes
$(DISK): $(TARGET) $(MKXDF)
	@mkdir -p build
	$(PYTHON) $(MKXDF) -o $@ -l $(LABEL) $(TARGET)

disk: $(DISK)

# Inspect an image: BPB read both ways plus the root directory.
# Point it at your Human68k system disk to confirm the layout:
#   make dump IMG=~/x68k/Human302.xdf
dump:
	$(PYTHON) $(MKXDF) --dump $(or $(IMG),$(DISK))

# ---- run --------------------------------------------------------------------
# px68k takes images on the command line; XM6 / XM6 TypeG are GUI driven, so
# there you mount your Human68k disk in FDD0 and build/demo.xdf in FDD1.
run: $(DISK)
	$(EMU) $(DISK)

clean:
	rm -f $(TARGET) $(LOGO_RAW)
	rm -rf build