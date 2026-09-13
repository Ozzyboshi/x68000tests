;==============================================================================
; demo_chunky.s - Sharp X68000 / Human68k
;
; True chunky mode: 65536 colours, ONE graphic page, one word per pixel and
; that word IS the colour (GGGGG RRRRR BBBBB I). No pages, no nibbles, no
; read-modify-write - just move.w.
;
; Plots one red pixel at an arbitrary (configurable) position.
;
; Assemble with vasm (Motorola syntax), Xfile output:
;   vasmm68k_mot -Fxfile -m68000 -exec=Main -I. -o DEMO.X demo_chunky.s
;
; Press any key to restore the screen and return to Human68k.
;
; Reference: Inside X68000 / X68k IOMAP register documentation.
;==============================================================================

; The library's CRTC timing table to reuse. All three are 15.98 kHz; only the
; horizontal/vertical dot counts differ. The colour-mode bits are overridden
; below, so any of them works - 512x256 is the usual choice.
Res512x256	equ	1
;Res256x256	equ	1
;Res512x512	equ	1

; ---- colours (direct 16 bit value written straight into VRAM) --------------
;         GGGGGRRRRRBBBBBI
COL_RED			equ	%0000011111000000
COL_GREEN		equ	%1111100000000000
COL_BLACK	equ	%0000000000000000

; ---- pixel position. GetScreenPos masks x,y to 8 bits: stay in 0..255 ------
PX		equ	100
PY		equ	100

; ---- hardware ---------------------------------------------------------------
VRAM		equ	$C00000		; single page, 512x512 words, 512 KB
VRAM_END	equ	$C80000
PALETTE		equ	$E82000		; graphic palette (special layout in 65536!)
CRTC_R20	equ	$E80028		; memory mode / display mode
CRTC_SCROLL	equ	$E80018		; R12..R19
VC_R0		equ	$E82400		; colour mode / GVRAM size
VC_R1		equ	$E82500		; priority
VC_R2		equ	$E82600		; screen on/off


;------------------------------------------------------------------------------
; Entry point
;------------------------------------------------------------------------------
Main:
	bsr	EnterSupervisor		; $E8xxxx is I/O space: supervisor only
	bsr	SaveCrtMode

	bsr	ScreenINIT		; library: CRTC timings (+ 16 colour setup)
	move.w	#$11,$E80004		; R02 display start
	move.w	#$39,$E80006		; R03 display end   -> 40*8 = 320 dot
	bsr	SetChunkyMode		; override the colour-mode registers
	bsr	InitDirectPalette	; identity LUT - see the note inside
	bsr	ResetScroll
	bsr	ClearVram

	bsr.w CopyImage

loop:
	bsr	waitVBlank

	cmpi.l #-1,XPOSOLD
	beq.s nocanc
	move.l	XPOSOLD,d1
	move.l	YPOSOLD,d2
	move.w	OLDCOLOR,d3
	bsr	PlotPixel
nocanc:

	move.l	#0,d1
	move.l	#0,d2
	move.w	#COL_GREEN,d3
	bsr	PlotPixel

	move.l	#319,d1
	move.l	#0,d2
	move.w	#COL_GREEN,d3
	bsr	PlotPixel

	move.l	#0,d1
	move.l	#239,d2
	move.w	#COL_GREEN,d3
	bsr	PlotPixel

	move.l	#319,d1
	move.l	#239,d2
	move.w	#COL_GREEN,d3
	bsr	PlotPixel

	; --- the whole point: one word = one pixel = one colour ----------------
	move.l	XPOS,d1
	move.l	YPOS,d2
	bsr	GetScreenPos2
	move.w	(a6),d5			; save color
	move.w	d5,OLDCOLOR		; save color
	;move.w	#COL_RED,d3
	;bsr	PlotPixel
	move.w	#COL_RED,(a6)

	move.l XPOS,XPOSOLD
	move.l YPOS,YPOSOLD

	; --- wait for a key, then clean up -------------------------------------
	moveq	#$01,d0			; IOCS _B_KEYSNS - poll, don't block
	; moveq	#$00,d0			; IOCS _B_KEYINP
	trap	#15
	tst.l	d0
	bne.s	quit

	addi.l #1,XPOS
	addi.l #1,YPOS

	andi.l #$FF,XPOS
	andi.l #$FF,YPOS
	bra.w loop
quit:
	moveq	#$00,d0			; IOCS _B_KEYINP - consume the key
	trap	#15


	bsr	RestoreCrtMode
	bsr	LeaveSupervisor
	dc.w	$FF00			; DOS _EXIT

XPOS: dc.l PX
YPOS: dc.l PY
XPOSOLD: dc.l -1
YPOSOLD: dc.l -1
OLDCOLOR: dc.w 0

;------------------------------------------------------------------------------
; Copyimage - copies a raw image into vram , a6 must point to vram
;------------------------------------------------------------------------------
CopyImage:
	lea	IMAGE_DATA,a0		; source
	lea	VRAM,a6			; destination: top-left corner
	move.w	#240-1,d7		; rows
CopyRow:
	move.l	a6,a1
	move.w	#(320/2)-1,d6		; 160 longwords = 320 pixels
CopyPixels:
	move.l	(a0)+,(a1)+
	dbra	d6,CopyPixels
	adda.l	#1024,a6		; next VRAM line
	dbra	d7,CopyRow
	rts

;------------------------------------------------------------------------------
; PlotPixel - in 65536 colour mode this is the entire graphics API.
; In:  d1 = x (0..255), d2 = y (0..255), d3 = 16 bit colour
; All registers preserved.
;
; No masking, no page select, no read-modify-write: the word at
; $C00000 + y*1024 + x*2 is the pixel.
;------------------------------------------------------------------------------
PlotPixel:
	movem.l	d0-d3/a6,-(sp)
		bsr	GetScreenPos2	; library: a6 = VRAM address of (x,y)
		move.w	d3,(a6)
	movem.l	(sp)+,d0-d3/a6
	rts


;------------------------------------------------------------------------------
; SetChunkyMode - switch the colour-mode registers to 65536 colours.
;
; ScreenINIT already programmed R00..R08 (the timings) and R20 for 16 colours.
; Only the colour bits change here, so the same routine works whichever of the
; three resolutions was compiled in.
;
;   CRTC R20 bits 9-8 (COL) = %11  -> 65536 colours   (bit 10 SIZE = 0: 512x512)
;   VC   R0  bits 1-0 (COL) = %11, bit 2 (SIZ) = 0    -> must match R20
;   VC   R1  GP3..GP0 = %11100100 (the value the docs prescribe for 1 page),
;            GR = %00 -> graphics is the front-most plane, TX/SP behind it
;   VC   R2  GS3..GS0 all = 1 (required when the graphic screen is 1 page),
;            text / sprite / border colour off
;------------------------------------------------------------------------------
SetChunkyMode:
	move.w	CRTC_R20,d0		; R20 is readable: keep the timing bits
	or.w	#%0000001100000000,d0	; COL = %11
	move.w	d0,CRTC_R20

	move.w	#%0000000000000011,VC_R0
	;	 --SSTTGGGP3GP2GP1GP0
	move.w	#%0010010011100100,VC_R1
	;	 YSAH--------SNGGGG      (SON/TON off, GS3..GS0 on)
	move.w	#%0000000000001111,VC_R2
	rts


;------------------------------------------------------------------------------
; InitDirectPalette - build the identity lookup table.
;
; "Direct colour" on the X68000 is not quite direct: in 65536 colour mode the
; VRAM word is split into two bytes and each one is still looked up in the
; graphic palette, then recombined. The two tables are interleaved in a way
; that trips everybody up the first time:
;
;   $E82000 +0 : low  byte value for VRAM low  byte = 0
;   $E82000 +1 : low  byte value for VRAM low  byte = 1
;   $E82000 +2 : high byte value for VRAM high byte = 0
;   $E82000 +3 : high byte value for VRAM high byte = 1
;   ...and so on, four bytes per pair of indices.
;
; IOCS sets this up for you; we bypass IOCS, so we do it here. Writing the
; identity mapping makes the VRAM word come out as the colour unchanged.
; (Leave it out and you get a screen full of whatever the previous program
; left in the palette.)
;------------------------------------------------------------------------------
InitDirectPalette:
	lea	PALETTE,a0
	moveq	#0,d0			; d0 = even index
	move.w	#128-1,d1
InitDirectPaletteLoop:
	move.b	d0,d2
	addq.b	#1,d2			; d2 = odd index
	move.b	d0,(a0)+		; low  byte table, even index
	move.b	d2,(a0)+		; low  byte table, odd  index
	move.b	d0,(a0)+		; high byte table, even index
	move.b	d2,(a0)+		; high byte table, odd  index
	addq.b	#2,d0
	dbra	d1,InitDirectPaletteLoop
	rts


;------------------------------------------------------------------------------
; ClearVram - 512 KB of longword writes. In 65536 colour mode every bit of
; every word is live, so one pass really does clear the whole screen.
;
; The CRTC can also do this in hardware (select the pages in R21 $E8002A, then
; set bit 1 of the operation port $E80481 and poll it until it clears) which is
; far faster - worth switching to once you are clearing every frame.
;------------------------------------------------------------------------------
ClearVram:
	lea	VRAM,a0
	lea	VRAM_END,a1
	move.l	#(COL_BLACK<<16)|COL_BLACK,d0
ClearVramLoop:
	move.l	d0,(a0)+
	cmpa.l	a1,a0
	bne	ClearVramLoop
	rts


;------------------------------------------------------------------------------
; ResetScroll - zero CRTC R12..R19. Only X0/Y0 matter with a single page, but
; the others survive from whatever ran before, so clear the lot.
;------------------------------------------------------------------------------
ResetScroll:
	lea	CRTC_SCROLL,a0
	moveq	#8-1,d0
ResetScrollLoop:
	move.w	#0,(a0)+
	dbra	d0,ResetScrollLoop
	rts


;------------------------------------------------------------------------------
; Supervisor mode / screen mode housekeeping.
; DOS calls are F-line opcodes ($FFxx); with doscall.mac you would write
; "DOS _SUPER" / "DOS _EXIT" instead of the raw dc.w.
; Variables are reached PC-relative, so the program stays position independent
; and needs no relocations.
;------------------------------------------------------------------------------
EnterSupervisor:
	clr.l	-(sp)			; _SUPER(0) -> switch to supervisor
	dc.w	$FF20			; DOS _SUPER
	addq.l	#4,sp
	lea	oldUsp(pc),a0
	move.l	d0,(a0)			; old USP, needed to get back
	rts

LeaveSupervisor:
	lea	oldUsp(pc),a0
	move.l	(a0),-(sp)		; _SUPER(oldUsp) -> back to user mode
	dc.w	$FF20			; DOS _SUPER
	addq.l	#4,sp
	rts

; IOCS _CRTMOD ($10): d1 = mode, d1 = -1 only reports the current one.
; We stomp the CRTC by hand, so this is how the console gets its mode back.
SaveCrtMode:
	moveq	#-1,d1
	moveq	#$10,d0
	trap	#15
	lea	oldCrtMode(pc),a0
	move.w	d0,(a0)
	rts

RestoreCrtMode:
	lea	oldCrtMode(pc),a0
	move.w	(a0),d1
	moveq	#$10,d0
	trap	#15
	rts


;------------------------------------------------------------------------------
; The helper library (ScreenINIT, GetScreenPos, GetNextLine, DefineSprite,
; SetSprite, waitVBlank). The resolution equate must come before this.
;------------------------------------------------------------------------------
	include	"x68k_screen_sprite_lib.s"


	even
oldUsp:		dc.l	0
oldCrtMode:	dc.w	0

IMAGE_DATA:
	incbin "sharp-x68000-logo-1_zrkb.1280.raw"
