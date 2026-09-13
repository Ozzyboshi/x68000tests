;==============================================================================
; Sharp X68000 - low level screen / sprite helper library (MC68000 asm)
;
; This is NOT a standalone program: it is a set of subroutines that talk
; directly to the X68000 custom chips, bypassing IOCS/Human68k entirely.
;
;   ScreenINIT    - program CRTC + video controller + sprite controller + palette
;   GetScreenPos  - convert (x,y) into a graphic VRAM address
;   GetNextLine   - advance that address by one scanline
;   DefineSprite  - upload a 16x16 pattern into PCG/sprite VRAM
;   SetSprite     - write one hardware sprite entry (pos/pattern/palette/prio)
;   waitVBlank    - busy-wait frame synchronisation via the MFP GPIP
;
; Requirements / caveats:
;   - All $E8xxxx / $EBxxxx addresses live in the I/O area: the CPU must be in
;     SUPERVISOR mode. A Human68k .X program starts in user mode, so call
;     DOS _SUPER (or run from an IOCS-level environment) before using these.
;   - The screen mode is set by hand, not through IOCS _CRTMOD, so nothing
;     restores the previous mode on exit - do that yourself if you return to DOS.
;   - The target resolution is picked at ASSEMBLY time by defining exactly one
;     of Res256x256 / Res512x256 / Res512x512 (ifd = "if defined").
;
; Memory map used here:
;   $C00000  graphic VRAM (1024 bytes per line, 1 word per pixel in EVERY mode).
;            In 16 colour mode only the low 4 bits are valid and each page has
;            its OWN window: page 0 $C00000, page 1 $C80000, page 2 $D00000,
;            page 3 $D80000. In 256 colour mode: low 8 bits, page 0 $C00000,
;            page 1 $C80000. In 65536 colour mode: one page, all 16 bits live.
;   $E80000  CRTC registers R00..
;   $E82000  graphic palette (16 bit per entry, GGGGGRRRRRBBBBBI)
;   $E82400  video controller R0 (screen mode)
;   $E82500  video controller R1 (priority)
;   $E82600  video controller R2 (screen on/off)
;   $E88000  MFP MC68901 (GPIP status, bit 4 = VDISP)
;   $EB0000  sprite registers  (128 sprites x 8 bytes)
;   $EB0800  sprite controller registers
;   $EB8000  PCG / sprite pattern VRAM (128 bytes per 16x16 pattern)
;==============================================================================


;------------------------------------------------------------------------------
; ScreenINIT - set up video mode, priorities, sprite plane and palette.
; Trashes: nothing meaningful (only immediate stores), returns via rts.
;------------------------------------------------------------------------------
ScreenINIT:	
		ifd Res256x256	
			; R20 memory/display mode. Real field layout:
			;   bits 1-0 HD  horizontal dots  (00=256, 01=512, 10=768)
			;   bits 3-2 VD  vertical dots    (00=256, 01=512, 1x=1024 ilace)
			;   bit  4   HF  scan rate        (0=15.98kHz, 1=31.50kHz)
			;   bits 9-8 COL colours          (00=16, 01=256, 11=65536)
			;   bit  10  SIZE real screen     (0=512x512, 1=1024x1024)
			; -> this value = 256x256, 16 colours, 15.98kHz
			;		 FEDCBA9876543210	
			move.w #%0000000000000000,$e80028 ;R20 Memory mode/Display mode control
			move.w #%0000000000000000,$e82400 ;R0 (Screen mode initialization) - Detail
			; R1 priority: SS=sprite, TT=text, GG=graphic plane group,
			; then the relative order of graphic pages 4,3,2,1
			;		 --SSTTGG44332211
			move.w #%0000001011100100,$e82500 ;R1 (Priority control) - Priority
			; R2 screen enable: bits 3-0 GS3..GS0 = the four graphic pages,
			; bit 4 GS4 (1024x1024 mode), bit 5 TON = text, bit 6 SON = sprite,
			; bit 7 BCON = border colour. This value: page 0 + sprites + border,
			; text off. With one page, GS3..GS0 must all carry the same value.
			;		 FEDCBA9876543210	
			;				  ST43210		
			move.w #%0000000011000001,$e82600 ;R2 (Special priority/screen display) - Screen On - sprites on
			
			; Standard 256x256 CRTC timings (same table IOCS uses for this mode).
			; Horizontal values are counted in units of 8 dots.
			move.w #$025,$E80000 	;R00 Horizontal total 
			move.w #$001,$E80002	;R01 Horizontal synchronization end position timing
			move.w #$000,$E80004	;R02 Horizontal display start position
			move.w #$020,$E80006	;R03 Horizontal display end position
			move.w #$103,$E80008	;R04 Vertical total 
			move.w #$002,$E8000A	;R05 Vertical synchronization end position timing
			move.w #$010,$E8000C	;R06 Vertical display start position
			move.w #$100,$E8000E	;R07 Vertical display end position
			move.w #$024,$E80010	;R08 External synchronization horizontal adjust: Horizontal position tuning
			
			; The sprite plane has its own timing regs: they must agree with the CRTC
			move.w #$25,$EB080A		; Sprite H Total   (mirrors CRTC R00)
			move.w #$04,$EB080C		; Sprite H Disp
			move.w #$10,$EB080E		; Sprite V Disp
			move.w #$00,$EB0810		; Sprite Res %---FVVHH -> 256x256
			
		endif
		ifd Res512x256
			; HD=01 -> 512 dots, VD=00 -> 256 lines, HF=0 -> 15.98kHz, 16 colours
			;		 FEDCBA9876543210	
			move.w #%0000000000000001,$e80028 ;R20 Memory mode/Display mode control
			move.w #%0000000000000000,$e82400 ;R0 (Screen mode initialization) - Detail
			;		 --SSTTGG44332211
			move.w #%0000001011100100,$e82500 ;R1 (Priority control) - Priority
			;				  ST43210		
			move.w #%0000000011000001,$e82600 ;R2 (Special priority/screen display) - Screen On	/ sprite on
			
			; 15.98kHz timings: vertical total $103 = 259 lines per frame,
			; which is the 15kHz figure (31.5kHz would need roughly 568)
			move.w #$4B,$E80000		;R00 Horizontal total 
			move.w #$03,$E80002		;R01 Horizontal synchronization end position timing
			move.w #$05,$E80004		;R02 Horizontal display start position
			move.w #$45,$E80006		;R03 Horizontal display end position
			move.w #$103,$E80008	;R04 Vertical total 
			move.w #$2,$E8000A		;R05 Vertical synchronization end position timing
			move.w #$10,$E8000C		;R06 Vertical display start position
			move.w #$100,$E8000E	;R07 Vertical display end position
			move.w #$44,$E80010		;R08 External synchronization horizontal adjust: Horizontal position tuning
			
			move.w #$FF,$EB080A		; Sprite H Total
			move.w #$09,$EB080C		; Sprite H Disp
			move.w #$10,$EB080E		; Sprite V Disp
			move.w #$01,$EB0810		; Sprite Res %---FVVHH -> H=512, V=256
			
		endif
		ifd Res512x512
			; HD=01 -> 512 dots, VD=01 -> 512 lines, HF=0 -> 15.98kHz,
			; i.e. the interlaced 15kHz mode (same frame timings as above)
			;		 FEDCBA9876543210	
			move.w #%0000000000000101,$e80028 ;R20 Memory mode/Display mode control
			move.w #%0000000000000000,$e82400 ;R0 (Screen mode initialization) - Detail
			; same page ordering as above, but the graphic group sits one step
			; further back in the priority chain (GG = 3 instead of 2)
			move.w #%0000001111100100,$e82500 ;R1 (Priority control) - Priority
			;		 FEDCBA9876543210	
			;				  ST43210		
			move.w #%0000000011000001,$e82600 ;R2 (Special priority/screen display) - Screen On - sprites on
			
			move.w #$04B,$E80000	;R00 Horizontal total 
			move.w #$003,$E80002	;R01 Horizontal synchronization end position timing
			move.w #$005,$E80004	;R02 Horizontal display start position
			move.w #$045,$E80006	;R03 Horizontal display end position
			move.w #$103,$E80008	;R04 Vertical total 
			move.w #$002,$E8000A	;R05 Vertical synchronization end position timing
			move.w #$010,$E8000C	;R06 Vertical display start position
			move.w #$100,$E8000E	;R07 Vertical display end position
			move.w #$044,$E80010	;R08 External synchronization horizontal adjust: Horizontal position tuning
			
			move.w #$FF,$EB080A		; Sprite H Total
			move.w #$09,$EB080C		; Sprite H Disp
			move.w #$10,$EB080E		; Sprite V Disp
			move.w #$05,$EB0810		; Sprite Res %---FVVHH -> H=512, V=512
		endif

		; Sprite controller enable. While the sprite plane is displayed the CPU
		; shares the sprite/PCG VRAM with the video hardware, so writes to
		; $EB0000/$EB8000 are slow (and are best done during blanking).
		;  	     FEDCBA9876543210	
		move.w #%0000001000000000,$eB0808 ;Disp/CPU 1=sprites on (slow writing)
				
		; Graphic palette, one word per colour: GGGGG RRRRR BBBBB I
		; (G = bits 15-11, R = bits 10-6, B = bits 5-1, I = intensity bit 0)
		;        GGGGGRRRRRBBBBB-
		move.w #%0000000000011110,$e82000		;Palette Entry 0  -> medium blue (background)
		move.w #%1111111100000000,$e82002		;Palette Entry 1  -> yellow/green
		move.w #%1111100000111110,$e82004		;Palette Entry 2  -> cyan
		move.w #%0000011111000000,$e82006		;Palette Entry 3  -> red
		move.w #%1111111100000000,$e8201E		;Palette Entry 15 -> yellow/green
		; In 16 colour mode ONLY the first 16 entries are used, and all four
		; graphic pages share them - there is no per-page palette block.
		; NOTE: sprites/PCG do NOT use this palette - they read the text/sprite
		; palette at $E82200 onwards, which this routine never initialises.
	rts
	
	

;------------------------------------------------------------------------------
; GetScreenPos - compute the VRAM address of pixel (x,y) in graphic page 0.
; In:  d1 = x, d2 = y
; Out: a6 = address in graphic VRAM (one word per pixel). In 16 colour mode
;           this is page 0's window and only the low 4 bits are live; add
;           $80000 per page to reach pages 1, 2 and 3. In 65536 colour mode
;           the whole word is the colour.
; All other registers are preserved.
;
; LIMIT: x and y are masked to 8 bits, so only the 256x256 top-left corner of
;        the screen can be addressed even in 512 wide / 512 tall modes.
;------------------------------------------------------------------------------
GetScreenPos: ; d1=x d2=y
	moveM.l d0-d7/a0-a5,-(sp)
		and.l #$FF,d1			;clamp x to 0..255
		and.l #$FF,d2			;clamp y to 0..255
		
		rol.l #1,d1				;2 bytes per pixel		
		add.l #$c00000,d1		;Graphics Vram – Page 0
		bclr.l #0,d1			;Clear Bit 0 (safety: rol wraps bit31 into bit0)
		move.l d1,a6
		
		rol.l #8,d2				;1024 bytes per Y line 
		rol.l #2,d2				;y * 256 * 4 = y * 1024
		add.l d2,a6
	moveM.l (sp)+,d0-d7/a0-a5
	rts

; GetScreenPos2 - d1=x d2=y -> a6 = VRAM address. CLOBBERS d1/d2.
GetScreenPos2:	; d1=x d2=y -> a6, CLOBBERS d1/d2
	and.l	#$1FF,d1
	and.l	#$FF,d2
	lsl.l	#1,d1
	add.l	#$c00000,d1
	move.l	d1,a6
	lsl.l	#8,d2
	lsl.l	#2,d2
	add.l	d2,a6
	rts
	
;------------------------------------------------------------------------------
; GetNextLine - move the pointer in a6 down one scanline (fixed 1024 byte stride)
;------------------------------------------------------------------------------
GetNextLine:	
	addA #1024,a6
	rts
	
	
	
	;move.l #1,d0		;Tile Number
	;lea Sprite,a3		;Sprite Address

;------------------------------------------------------------------------------
; DefineSprite - upload one 16x16 4bpp pattern into PCG VRAM.
; In:  d0 = pattern number (0..255), a3 = pointer to the pattern data
; Trashes: d0, d2, a0, a3 (no registers are saved!)
;
; BUG: a 16x16 4bpp pattern is 128 bytes, and the destination stride below is
;      indeed 128 ($80) bytes - but the loop copies $80 WORDS = 256 bytes, so it
;      overruns into the next pattern slot. Use #$40-1 to copy exactly 128 bytes.
;------------------------------------------------------------------------------
DefineSprite:
	rol.l #7,d0				;Each sprite has 128 bytes of data (&80 bytes)
	add.l #$EB8000,d0		;Base address of sprite vram
	move.l d0,a0
	
	move.l #$80-1,d2		;<- see BUG note above ($40-1 would be correct)
	clr.l d0				;dead instruction: d0 is not used afterwards
CopySpriteAgain:			;Copy the data from A3 to the Sprite ram
	move.w (a3)+,(a0)+
	dbra d2,CopySpriteAgain
	rts

	

	; move.l #0,d0		;Hardware Sprite Number
	; move.l #$50,d1	;Xpos
	; move.l #$30,d2	;Ypos
	; move.l #0,d3		;Sprite Pattern
	; move.l #0,d4		;Palette
	; move.l #3,d5		;Priority
	
;------------------------------------------------------------------------------
; SetSprite - program one of the 128 hardware sprites.
; In:  d0 = sprite index, d1 = X, d2 = Y, d3 = pattern number,
;      d4 = palette block (0..15), d5 = priority (0..3, 0 = sprite hidden)
; Preserves d0-d2/a0, but MODIFIES d3 and d4.
;
; NOTE: screen origin for sprites is offset by 16 pixels, i.e. X=$10,Y=$10 puts
;       the sprite at the top-left visible corner.
;------------------------------------------------------------------------------
SetSprite:
	moveM.l d0-d2/a0,-(sp)	
		rol.l #3,d0			;4 bytes per sprite  <- comment is wrong: 4 regs x 16 bit
		add.l #$EB0000,d0	;   = 8 bytes, and rol #3 (x8) is the correct maths
		move.l d0,a0
		
		move.w d1,(a0)+		;------XX XXXXXXXX - X=Xpos (10 bits)
		move.w d2,(a0)+		;------YY YYYYYYYY - Y=Ypos (10 bits)
		
		rol.l #8,d4			;Shift palette into top byte (lands on bits 8-11)
		add.l d4,d3			;keep d4 in 0..15 or it will corrupt the flip bits
		
		move.w d3,(a0)+		;VH--CCCC SSSSSSSS - S=Sprite C=Color V=Vflip H=Hflip
		move.w d5,(a0)+		;-------- ------PP - P=Priority
	moveM.l (sp)+,d0-d2/a0
	rts


	
;------------------------------------------------------------------------------
; waitVBlank - busy-wait frame sync using the MFP MC68901 GPIP register.
; Bit 4 (VDISP) tracks the vertical display period, so the routine first waits
; for the bit to go high, then for it to go low again: it therefore always
; returns at the same point of the frame, once per frame.
; Trashes d0.
;------------------------------------------------------------------------------
waitVBlank:
	move.w $e88000,d0			;MFP (MC68901) - word read, GPIP is the low byte
	and.w #%00010000,d0			;Wait for vblank to start
	beq waitVBlank
waitVBlank2:	
	move.w $e88000,d0			;MFP (MC68901)
	and.w #%00010000,d0			;Wait for Vblank to end
	bne waitVBlank2
	rts

	
; MFP GPIP bit assignments, for reference:
;#define GPIP_ALARM    (1 << 0)
;#define GPIP_EXPON    (1 << 1)
;#define GPIP_POWSW    (1 << 2)
;#define GPIP_OPMIRQ   (1 << 3)
;#define GPIP_VDISP    (1 << 4)
;#define GPIP_CRTC     (1 << 6)
;#define GPIP_HSYNC    (1 << 7)
