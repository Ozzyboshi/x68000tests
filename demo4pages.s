;==============================================================================
; demo4pages.s - Sharp X68000 / Human68k
;
; Enables all four 16-colour graphic pages at once and plots one red pixel on
; each of them, at an arbitrary (configurable) position.
;
; Built on top of the helper library (ScreenINIT / GetScreenPos / waitVBlank).
; Assemble with HAS060 / AS.X / vasm (Motorola syntax), link into a .X file.
;
;   has060 demo4pages.s -o demo4pages.o
;   lk     demo4pages.o -o demo4pages.x
;
; Press any key to restore the screen and return to Human68k.
;==============================================================================

; Pick exactly one resolution: the library selects the CRTC table with 'ifd'.
; All three give four independent pages, because 16-colour mode always splits
; the VRAM word into four nibbles.
Res512x256	equ	1
;Res256x256	equ	1
;Res512x512	equ	1

; Graphic palette word format: GGGGG RRRRR BBBBB I
COL_BG		equ	%0000000000011110	; medium blue - background (entry 0)
COL_RED		equ	%0000011111000000	; pure red

RED_IDX		equ	3			; colour index we plot with

; One pixel per page. GetScreenPos masks x and y to 8 bits, so stay in 0..255.
P0X	equ	100
P0Y	equ	100
P1X	equ	110
P1Y	equ	104
P2X	equ	120
P2Y	equ	108
P3X	equ	130
P3Y	equ	112

; Hardware addresses used directly here
VRAM_GRP	equ	$C00000		; page 0; pages 1,2,3 at +$80000 each
VRAM_GRP_END	equ	$E00000		; end of page 3's window
SPRITE_REGS	equ	$EB0000		; 128 sprites x 8 bytes
SPRITE_REGS_END	equ	$EB0400
PALETTE_GRP	equ	$E82000		; 256 graphic palette entries
CRTC_SCROLL	equ	$E80018		; R12..R19: X/Y scroll of pages 0..3
VC_R2		equ	$E82600		; screen on/off


	.text

;------------------------------------------------------------------------------
; Entry point
;------------------------------------------------------------------------------
Main:
	bsr	EnterSupervisor		; the $E8xxxx/$EBxxxx I/O area needs it
	bsr	SaveCrtMode		; so we can give the console back at the end

	bsr	ScreenINIT		; library: CRTC + video controller + palette
	bsr	ClearSpriteRam		; sprite regs hold boot garbage - blank them
	bsr	ClearGraphicVram	; all four pages at once (whole words)
	bsr	ResetScroll		; zero the per-page scroll registers
	bsr	InitPalette		; our own palette, see notes inside
	bsr	EnableFourPages		; R2: switch pages 0,1,2,3 on together

	bsr	waitVBlank		; library: land on a frame boundary

	; --- one red pixel per page --------------------------------------------
	moveq	#P0X,d1
	moveq	#P0Y,d2
	moveq	#0,d3			; page 0
	moveq	#RED_IDX,d4
	bsr	PlotPixel

	moveq	#P1X,d1
	moveq	#P1Y,d2
	moveq	#1,d3			; page 1
	moveq	#RED_IDX,d4
	bsr	PlotPixel

	moveq	#P2X,d1
	moveq	#P2Y,d2
	moveq	#2,d3			; page 2
	moveq	#RED_IDX,d4
	bsr	PlotPixel

	moveq	#P3X,d1
	moveq	#P3Y,d2
	moveq	#3,d3			; page 3
	moveq	#RED_IDX,d4
	bsr	PlotPixel

	; --- wait for a key, then clean up -------------------------------------
	moveq	#$00,d0			; IOCS _B_KEYINP: wait for a keypress
	trap	#15

	bsr	RestoreCrtMode
	bsr	LeaveSupervisor
	dc.w	$FF00			; DOS _EXIT


;------------------------------------------------------------------------------
; PlotPixel - write one colour index into one page.
;
; The four pages are NOT nibbles you have to mask by hand: each one has its own
; 512 KB address window, and in 16 colour mode only the low 4 bits are live
; there. So the page select is just an address offset and the write is a plain
; move.w - no read-modify-write, and the other pages are untouched.
;
;     page 0 $C00000   page 1 $C80000   page 2 $D00000   page 3 $D80000
;
; In:  d1 = x (0..255), d2 = y (0..255), d3 = page (0..3), d4 = colour (0..15)
; Out: nothing. All registers preserved.
;------------------------------------------------------------------------------
PlotPixel:
	movem.l	d0/d3/a6,-(sp)
		bsr	GetScreenPos	; library: a6 = page 0 address of (x,y)

		and.l	#3,d3
		move.l	d3,d0
		lsl.l	#3,d0		; page * 8
		swap	d0		; ...* 65536 = page * $80000
		add.l	d0,a6		; ...move into that page's window

		move.w	d4,(a6)		; only the low 4 bits are taken
	movem.l	(sp)+,d0/d3/a6
	rts


;------------------------------------------------------------------------------
; EnableFourPages - turn pages 0..3 on simultaneously.
;
; ScreenINIT writes %0000000011000001 to R2: graphic page 0 (GS0) + sprites
; (SON, bit 6) + border colour (BCON, bit 7). Here we want GS3..GS0 all on and
; nothing else, so the console text and any uninitialised sprites stay hidden.
;
; Stacking order is NOT the page number: it comes from the GP3..GP0 fields of
; R1 ($E82500), which ScreenINIT programs as %11100100 = page 0 in front.
; Colour index 0 in a page is transparent, so the pages below show through,
; down to palette entry 0.
;------------------------------------------------------------------------------
EnableFourPages:
	;	 YSAH--------SNGGGG
	move.w	#%0000000000001111,VC_R2
	rts


;------------------------------------------------------------------------------
; InitPalette - set up the colours we actually rely on.
;
; ScreenINIT only fills entries 0,1,2,3 and 15, leaving 4..14 as boot garbage.
; In 16 colour mode only the first 16 palette entries exist and ALL FOUR pages
; share them: there is no per-page palette block, so index 3 is the same red
; whichever page you draw it on.
;------------------------------------------------------------------------------
InitPalette:
	lea	PALETTE_GRP,a0
	moveq	#16-1,d0		; the 16 entries this mode uses
InitPaletteLoop:
	move.w	#0,(a0)+
	dbra	d0,InitPaletteLoop

	move.w	#COL_BG,PALETTE_GRP		; entry 0 = screen background
	move.w	#COL_RED,PALETTE_GRP+(RED_IDX*2)
	rts


;------------------------------------------------------------------------------
; ClearGraphicVram - blank all four pages.
; Each page is a separate 512 KB window, so one sweep across $C00000-$DFFFFF
; covers all four. Slow (a good fraction of a second at 10 MHz); the CRTC fast
; clear is the real answer - select the pages in R21 ($E8002A, 0 = selected),
; set bit 1 of the operation port $E80481, poll it until it clears itself.
;------------------------------------------------------------------------------
ClearGraphicVram:
	lea	VRAM_GRP,a0
	lea	VRAM_GRP_END,a1
	moveq	#0,d0
ClearGraphicVramLoop:
	move.l	d0,(a0)+
	cmpa.l	a1,a0
	bne	ClearGraphicVramLoop
	rts


;------------------------------------------------------------------------------
; ClearSpriteRam - the library leaves the sprite plane enabled in R2 but never
; initialises the 128 sprite entries, which would otherwise draw whatever was
; left in RAM. Zeroing priority (last word of each entry) is enough to hide
; them; we clear the lot for good measure.
;------------------------------------------------------------------------------
ClearSpriteRam:
	lea	SPRITE_REGS,a0
	lea	SPRITE_REGS_END,a1
	moveq	#0,d0
ClearSpriteRamLoop:
	move.l	d0,(a0)+
	cmpa.l	a1,a0
	bne	ClearSpriteRamLoop
	rts


;------------------------------------------------------------------------------
; ResetScroll - zero CRTC R12..R19, the X/Y scroll pair of each graphic page.
; They survive whatever the previous program left in them, and each page scrolls
; independently - which is exactly the Amiga dual-playfield trick, only with
; four playfields and no blitting.
;------------------------------------------------------------------------------
ResetScroll:
	lea	CRTC_SCROLL,a0
	moveq	#8-1,d0			; 4 pages x (X,Y)
ResetScrollLoop:
	move.w	#0,(a0)+
	dbra	d0,ResetScrollLoop
	rts


;------------------------------------------------------------------------------
; Supervisor mode / screen mode housekeeping
;
; DOS calls are F-line opcodes ($FFxx). With doscall.mac included you would
; write "DOS _SUPER" and "DOS _EXIT" instead of the raw dc.w below.
;------------------------------------------------------------------------------
EnterSupervisor:
	clr.l	-(sp)			; _SUPER(0) -> switch to supervisor
	dc.w	$FF20			; DOS _SUPER
	addq.l	#4,sp
	move.l	d0,oldUsp		; keep the old USP for the way back
	rts

LeaveSupervisor:
	move.l	oldUsp,-(sp)		; _SUPER(oldUsp) -> back to user mode
	dc.w	$FF20			; DOS _SUPER
	addq.l	#4,sp
	rts

; IOCS _CRTMOD ($10): d1 = mode, d1 = -1 just reports the current one.
; We stomp the CRTC by hand, so this is how the console gets its mode back.
; Worth double-checking against your IOCS reference if you hit anything odd.
SaveCrtMode:
	moveq	#-1,d1
	moveq	#$10,d0
	trap	#15
	move.w	d0,oldCrtMode
	rts

RestoreCrtMode:
	move.w	oldCrtMode,d1
	moveq	#$10,d0
	trap	#15
	rts


;------------------------------------------------------------------------------
; Library (ScreenINIT, GetScreenPos, GetNextLine, DefineSprite, SetSprite,
; waitVBlank). Keep the resolution equate above this include.
;------------------------------------------------------------------------------
	.include	"x68k_screen_sprite_lib.s"


	.even
oldUsp:		dc.l	0
oldCrtMode:	dc.w	0

	.end	Main
