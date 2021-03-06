'' =================================================================================================
''
''   File....... jm_rgbx_pixel.spin
''   Purpose.... 800kHz driver for WS281x & SK681xRGBW LEDs
''   Author..... Jon "JonnyMac" McPhalen
''               Copyright (C) 2016-2022 Jon McPhalen
''               -- see below for terms of use
''   E-mail..... jon@jonmcphalen.com
''   Started....
''   Updated.... 10 JUN 2021
''
''   {$P1}
''
'' =================================================================================================

{ -------------------------------------- }
{  NOTE: Requires system clock >= 80MHz  }
{ -------------------------------------- }

{

  References:
  -- https://cdn-shop.adafruit.com/datasheets/WS2811.pdf
  -- https://cdn-shop.adafruit.com/datasheets/WS2812.pdf
  -- https://cdn-shop.adafruit.com/datasheets/WS2812B.pdf
  -- http://www.szledcolor.com/download/WS2813%20LED.pdf
  -- https://cdn-shop.adafruit.com/product-files/1138/SK6812+LED+datasheet+.pdf
  -- https://cdn-shop.adafruit.com/product-files/2757/p2757_SK6812RGBW_REV01.pdf

  Important Note:

    In order to accomdate 24- and 32-bit pixels, the data for 24-bit pixels must be left
    aligned in long holding the RGB value. In previous drivers, the data was right aligned.

    old format: $00_RR_GG_BB
    new format: $RR_GG_BB_00

    BYTE0 of the pixel data holds the white channel for RBGW pixels.

    $RR_GG_BB_WW

    The driver needs to know the data pixel length: 24 (rgb) or 32 (rgbw) bits

}


con { fixed io pins }

  RX_PGM   = 31  { I }                                          ' serial / programming
  TX_PGM   = 30  { O }

  SDA_EE   = 29  { I/O }                                        ' i2c / eeprom
  SCL_EE   = 28  { I/O }


con

  MAX_PIXELS = 1024                                             ' max pixels per strip


con { rgbw colors }

  ' borrowed from Gavin Garner's TM1804 LED driver
  ' -- additional colors by Lachlan
  ' -- some alterations by JM
  ' -- modified for RGB and RGBW pixels

  '             RR GG BB WW
  BLACK      = $00_00_00_00
  RED        = $FF_00_00_00
  GREEN      = $00_FF_00_00
  BLUE       = $00_00_FF_00
  WHITE      = $FF_FF_FF_00
  WHITE2     = $00_00_00_FF
  CYAN       = $00_FF_FF_00
  MAGENTA    = $FF_00_FF_00
  YELLOW     = $FF_FF_00_00
  CHARTREUSE = $7F_FF_00_00
  ORANGE     = $FF_60_00_00
  AQUAMARINE = $7F_FF_D4_00
  PINK       = $FF_5F_5F_00
  TURQUOISE  = $3F_E0_C0_00
  REALWHITE  = $C8_FF_FF_00
  INDIGO     = $3F_00_7F_00
  VIOLET     = $BF_7F_BF_00
  MAROON     = $32_00_10_00
  BROWN      = $0E_06_00_00
  CRIMSON    = $DC_28_3C_00
  PURPLE     = $8C_00_FF_00


var

  long  cog

  long  p_pixels                                                ' pointer to active pixel buffer
  long  npixels                                                 ' number of pixels in buffer
  long  tpin                                                    ' active transmit pin

  ' do not modify order; this structure passed to PASM cog
  '
  long  connection                                              ' compressed connection details
  long  resetticks                                              ' ticks in reset period
  long  rgfix                                                   ' swap r&g? + bit count for pixels
  long  t0h                                                     ' bit0 high time (ticks)
  long  t1h                                                     ' bit1 high time (ticks)
  long  cycleticks                                              ' ticks in 1.25us


pub null

'' This is not a top-level object


pub start_2811(p_buf, count, pin, holdoff)

'' Start pixel driver for WS2811 ICs
'' -- p_buf is pointer to [long] array holding pixel data
'' -- count is # of pixels supported by array at p_buf
'' -- pin is serial output to pixels
'' -- hold-off is delay (0.1 to 5.0ms) between tranmissions
''    * units are 100us (0.1ms) 10 units = 1ms

  return startx(p_buf, count, pin, holdoff, false, 24, 250, 600)


pub start_2812(p_buf, count, pin, holdoff)

'' Start pixel driver for WS2812 LEDs
'' -- p_buf is pointer to [long] array holding pixel data
'' -- count is # of pixels supported by array at p_buf
'' -- pin is serial output to pixels
'' -- holdoff is the delay between data bursts
''    * units are 100us (0.1ms) 10 units = 1ms

  return startx(p_buf, count, pin, holdoff, true, 24, 350, 700)


pub start_2812b(p_buf, count, pin, holdoff)

'' Start pixel driver for WS2812b LEDs
'' -- p_buf is pointer to [long] array holding pixel data
'' -- count is # of pixels supported by array at p_buf
'' -- pin is serial output to pixels
'' -- holdoff is the delay between data bursts
''    * units are 100us (0.1ms) 10 units = 1ms

  return startx(p_buf, count, pin, holdoff, true, 24, 400, 800)


pub start_2813(p_buf, count, pin, holdoff)

'' Start pixel driver for WS2813 LEDs
'' -- p_buf is pointer to [long] array holding pixel data
'' -- count is # of pixels supported by array at p_buf
'' -- pin is serial output to pixels
'' -- holdoff is the delay between data bursts
''    * units are 100us (0.1ms) 10 units = 1ms
''    * minimum hold-off is 300us

  return startx(p_buf, count, pin, (holdoff #> 3), true, 24, 375, 875)


pub start_6812x(p_buf, count, pin, holdoff, bits)

'' Start pixel driver for SK6812RBGW LEDs
'' -- p_buf is pointer to [long] array holding pixel data
'' -- count is # of pixels supported by array at p_buf
'' -- pin is serial output to pixels
'' -- holdoff is the delay between data bursts
''    * units are 100us (0.1ms) 10 units = 1ms
'' -- bits is 24 for SK6812, or 32 for SK6812RGBW

  return startx(p_buf, count, pin, holdoff, true, bits, 300, 600)


pub startx(p_buf, count, pin, holdoff, rgswap, bits, ns0h, ns1h) | ustix

'' Start smart pixel driver driver
'' -- p_buf is pointer to [long] array holding pixel data
'' -- count is # of pixels supported by array at p_buf
'' -- pin is serial output to pixels
'' -- holdoff is the delay between data bursts
''    * units are 100us (0.1ms) 10 units = 1ms
''    * long pixel strings tend to require long hold-off delays (e.g. 10 for 1ms)
'' -- rgswap is red/green swap flag
'' -- bits is 24 for RGB (WS2812x, WS2813, SK6812), 32 for RBGW (SK6812RGBW)
'' -- ns0h is 0-bit high timing (ns)
'' -- ns1h is 1-bit high timing (ns)

  stop                                                          ' stop if running
  dira[pin] := 0                                                ' clear tx pin in this cog

  if (clkfreq < 80_000_000)                                     ' requires 80MHz clock
    return 0

  ustix := clkfreq / 1_000_000                                  ' ticks in 1us

  ' set cog parameters

  use(p_buf, count, pin, bits)                                  ' set connection details

  resetticks := ustix * 100 * (1 #> holdoff <# 50)              ' note: 80us min reset timing
  rgfix      := rgswap <> 0                                     ' promote non-zero to true
  t0h        := ustix * ns0h / 1000 - 9                         ' pulse widths in ticks (adjusted)
  t1h        := ustix * ns1h / 1000 - 9
  cycleticks := ustix * 1_25 / 1_00                             ' ticks in 1.25us (800kHz)

  cog := cognew(@pixdriver, @connection) + 1                    ' start the cog
  if (cog)                                                      ' if it started
    repeat until (connection == 0)                              '  wait until ready

  return cog


pub stop

'' Stops pixel driver cog (if running)

  if (cog)
    cogstop(cog - 1)
    cog := 0


pub use(p_buf, count, pin, bits) : c

'' Assigns buffer at p_buf to pixel driver
'' -- p_buf is pointer to long array
'' -- count is # of elements in the array
'' -- pin is serial output to pixels
'' -- bits is bit count for pixel type (24 or 32)

   longmove(@p_pixels, @p_buf, 3)                               ' copy parameters
   npixels := 1 #> count <# MAX_PIXELS                          ' force  count into range

   c := p_pixels | ((npixels-1) << 16) | (pin << 26)            ' compress for driver cog

   if (bits == 32)
     c |= |<31                                                  ' set bit 31 for 32-bit pixels

   connection := c                                              ' set new connection


pub connected

'' Returns true when latest connection details picked up by driver

  return (connection == 0)


pub color(r, g, b, w)

'' Packs r-g-b-w bytes into long

  result.byte[3] := r
  result.byte[2] := g
  result.byte[1] := b
  result.byte[0] := w


pub colorx(r, g, b, w, level)

'' Packs r-g-b-w bytes into long
'' -- r, g, b, and w are element levels, 0..255
'' -- level is brightness, 0..255 (0..100%)

  if (level =< 0)
    return $00_00_00_00

  elseif (level => 255)
    return color(r, g, b, w)

  else
    r := r * level / 255                                        ' apply level to rgbw
    g := g * level / 255
    b := b * level / 255
    w := w * level / 255
    return color(r, g, b, w)


pub wheel(pos)

'' Creates color from 0 to 255 position input
'' -- colors transition r->g->b back to r
'' -- does not use white channel

  pos &= $FF

  if (pos < 85)
    return color(255-pos*3, pos*3, 0, 0)
  elseif (pos < 170)
    pos -= 85
    return color(0, 255-pos*3, pos*3, 0)
  else
    pos -= 170
    return color(pos*3, 0, 255-pos*3, 0)


pub wheelx(pos, level)

'' Creates color from 0 to 255 position input
'' -- colors transition r-g-b back to r
'' -- level is brightness, 0..255 (0..100%)
'' -- does not use white channel

  pos &= $FF

  if (pos < 85)
    return colorx(255-pos*3, pos*3, 0, 0, level)
  elseif (pos < 170)
    pos -= 85
    return colorx(0, 255-pos*3, pos*3, 0, level)
  else
    pos -= 170
    return colorx(pos*3, 0, 255-pos*3, 0, level)


pub set(ch, rgbw)

'' Writes rgbw value to channel ch in buffer
'' -- rgbw is packed long in form $RR_GG_BB_WW

  if ((ch => 0) and (ch < npixels))
    long[p_pixels][ch] := rgbw


pub setx(ch, rgbw, level)

'' Writes scaled rgbw value to channel ch in buffer
'' -- rgbw is packed long in form $RR_GG_BB_WW
'' -- level is brightness, 0..255 (0..100%)

  if ((ch => 0) and (ch < npixels))
    long[p_pixels][ch] := scale_rgbw(rgbw, level)


pub scale_rgbw(rgbw, level)

'' Scales rgbw value to level
'' -- level is brightness, 0..255 (0..100%)

  if (level =< 0)
    result := $00_00_00_00

  elseif (level => 255)
    result := rgbw

  else
    result.byte[3] := rgbw.byte[3] * level / 255
    result.byte[2] := rgbw.byte[2] * level / 255
    result.byte[1] := rgbw.byte[1] * level / 255
    result.byte[0] := rgbw.byte[0] * level / 255


pub set_rgbw(ch, r, g, b, w)

'' Writes rgbw elements to channel ch in buffer
'' -- r, g, b, and w are byte values, 0 to 255

  set(ch, color(r, g, b, w))


pub set_red(ch, level)

'' Sets red led level of selected channel
'' -- level is brightness, 0..255 (0..100%)

  if ((ch => 0) and (ch < npixels))                             ' valid?
    byte[p_pixels + (ch << 2) + 3] := level                     '  set it


pub set_green(ch, level)

'' Sets green led level of selected channel
'' -- level is brightness, 0..255 (0..100%)

  if ((ch => 0) and (ch < npixels))
    byte[p_pixels + (ch << 2) + 2] := level


pub set_blue(ch, level)

'' Sets blue led level of selected channel
'' -- level is brightness, 0..255 (0..100%)

  if ((ch => 0) and (ch < npixels))
    byte[p_pixels + (ch << 2) + 1] := level


pub set_white(ch, level)

'' Sets white led level of selected channel
'' -- level is brightness, 0..255 (0..100%)

  if ((ch => 0) and (ch < npixels))
    byte[p_pixels + (ch << 2) + 0] := level


pub set_all(rgbw)

'' Sets all channels to rgb
'' -- rgbw is packed long in form $RR_GG_BB_WW

  longfill(p_pixels, rgbw, npixels)


pub fill(first, last, rgbw) | swap

'' Fills first through last channels with rgb
'' -- rgbw is packed long in form $RR_GG_BB_WW

  first := 0 #> first <# npixels-1
  last  := 0 #> last  <# npixels-1

  if (first > last)
    swap  := first
    first := last
    last  := swap

  longfill(p_pixels+(first << 2), rgbw, last-first+1)


pub morph(c1, c2, phase) : newcolor

'' Morph between c1 and c2
'' -- phase 0 is color1
'' -- phase 255 is color2

  if (phase =< 0)
    newcolor := c1

  elseif (phase => 255)
    newcolor := c2

  else
    c1 := scale_rgbw(c1, 255-phase)
    c2 := scale_rgbw(c2, phase)
    newcolor := c1 + c2


pub clear

'' Turns off all LEDs

  longfill(p_pixels, $00_00_00_00, npixels)


pub read(ch)

'' Returns color of channel

  if ((ch => 0) and (ch < npixels))                             ' valid?
    return long[p_pixels][ch]
  else
    return $00_00_00_00


pub gamma(idx)

'' Adjusts gamma for better midrange colors

  return GammaTable[0 #> idx <# 255]


pub running

'' Returns true if running

  return (cog <> 0)


pub address

'' Returns address of assigned pixel array

  return p_pixels


pub num_pixels

'' Returns number of pixels in assiged pixel array

  return npixels


dat { gamma table }

' Liberated from an Adafruit WS2812 demo

  GammaTable            byte      0,   0,   0,   0,   0,   0,   0,   0
                        byte      0,   0,   0,   0,   0,   0,   0,   0
                        byte      0,   0,   0,   0,   0,   0,   0,   0
                        byte      1,   1,   1,   1,   1,   1,   1,   1
                        byte      1,   1,   1,   1,   2,   2,   2,   2
                        byte      2,   2,   2,   2,   3,   3,   3,   3
                        byte      3,   3,   4,   4,   4,   4,   5,   5
                        byte      5,   5,   5,   6,   6,   6,   6,   7
                        byte      7,   7,   8,   8,   8,   9,   9,   9
                        byte     10,  10,  10,  11,  11,  11,  12,  12
                        byte     13,  13,  13,  14,  14,  15,  15,  16
                        byte     16,  17,  17,  18,  18,  19,  19,  20
                        byte     20,  21,  21,  22,  22,  23,  24,  24
                        byte     25,  25,  26,  27,  27,  28,  29,  29
                        byte     30,  31,  31,  32,  33,  34,  34,  35
                        byte     36,  37,  38,  38,  39,  40,  41,  42
                        byte     42,  43,  44,  45,  46,  47,  48,  49
                        byte     50,  51,  52,  53,  54,  55,  56,  57
                        byte     58,  59,  60,  61,  62,  63,  64,  65
                        byte     66,  68,  69,  70,  71,  72,  73,  75
                        byte     76,  77,  78,  80,  81,  82,  84,  85
                        byte     86,  88,  89,  90,  92,  93,  94,  96
                        byte     97,  99, 100, 102, 103, 105, 106, 108
                        byte    109, 111, 112, 114, 115, 117, 119, 120
                        byte    122, 124, 125, 127, 129, 130, 132, 134
                        byte    136, 137, 139, 141, 143, 145, 146, 148
                        byte    150, 152, 154, 156, 158, 160, 162, 164
                        byte    166, 168, 170, 172, 174, 176, 178, 180
                        byte    182, 184, 186, 188, 191, 193, 195, 197
                        byte    199, 202, 204, 206, 209, 211, 213, 215
                        byte    218, 220, 223, 225, 227, 230, 232, 235
                        byte    237, 240, 242, 245, 247, 250, 252, 255


dat { auto-run driver }

                        org     0

pixdriver               mov     t1, par                         ' hub address of parameters -> t1
                        movd    :read, #connect                 ' location of cog parameters -> :read(dest)
                        mov     t2, #6                          ' get 6 parameters
:read                   rdlong  0-0, t1                         ' copy parameter from hub to cog
                        add     t1, #4                          ' next hub element
                        add     :read, INC_DEST                 ' next cog element
                        djnz    t2, #:read                      ' done?

setup                   mov     p_hub, connect                  ' extract pointer to pixel array
                        shl     p_hub, #16
                        shr     p_hub, #16

                        mov     pixcount, connect               ' extract/fix pixel count
                        shl     pixcount, #6                    ' (remove bits flag, tx pin)
                        shr     pixcount, #22                   ' align, 0..MAX_PIXELS-1
                        add     pixcount, #1                    ' fix, 1..MAX_PIXELS

                        mov     t1, connect                     ' extract pin
                        shl     t1, #1                          ' (remove bits flag)
                        shr     t1, #27                         ' align, 0..31
                        mov     txmask, #1                      ' create mask for tx
                        shl     txmask, t1
                        andn    outa, txmask                    ' set to output low
                        or      dira, txmask

                        mov     pixelbits, #24                  ' assume 24-bit pixels
                        rcl     connect, #1             wc, nr  ' check bit 31
        if_c            add     pixelbits, #8                   ' if set add 8 for 32-bit pixels

                        mov     t1, #0
                        wrlong  t1, par                         ' tell hub we have connection

rgbx_main               rdlong  connect, par            wz      ' check connection
        if_nz           jmp     #setup

                        mov     addr, p_hub                     ' point to rgbbuf[0]
                        mov     npix, pixcount                  ' set # active pixels

frame_loop              rdlong  colorbits, addr                 ' read a channel
                        add     addr, #4                        ' point to next
                        tjz     swapflag, #shift_out            ' skip fix if swap = 0


' Correct placement of rg color bytes
' -- $RR_GG_BB_WW --> $GG_RR_BB_WW

swap_rg                 mov     t1, colorbits                   ' copy for red
                        mov     t2, colorbits                   ' copy for green
                        and     colorbits, HX_0000FFFF          ' isolate blue and white
                        and     t1, HX_FF000000                 ' isolate red
                        shr     t1, #8                          ' move red from byte3 to byte2
                        or      colorbits, t1                   ' add red back in
                        and     t2, HX_00FF0000                 ' isolate green
                        shl     t2, #8                          ' move green from byte2 to byte3
                        or      colorbits, t2                   ' add green back in


shift_out               mov     nbits, pixelbits                ' set for pixel used
                        mov     bittimer, cycletix              ' set cycle timer for 800kHz
                        add     bittimer, cnt                   ' sync with system

:loop                   rcl     colorbits, #1           wc      ' msb --> C
        if_nc           mov     t1, bit0hi                      ' if C = 0, use bit0 timing
        if_c            mov     t1, bit1hi                      ' if C = 1, use bit1 timing
                        or      outa, txmask                    ' make tx high
                        add     t1, cnt                         ' sync with system
                        waitcnt t1, #0                          ' hold high
                        andn    outa, txmask                    ' make tx low
                        waitcnt bittimer, cycletix              ' finish low side of cycle
                        djnz    nbits, #:loop                   ' more bits?

next_pixel              djnz    npix, #frame_loop               ' done with all leds?

reset_delay             mov     bittimer, resettix              ' set reset timing
                        add     bittimer, cnt                   ' sync timer
                        waitcnt bittimer, #0                    ' let timer expire

                        jmp     #rgbx_main                      ' back to top

' --------------------------------------------------------------------------------------------------

INC_DEST                long    1 << 9                          ' to increment D field

HX_0000FFFF             long    $0000FFFF                       ' byte masks
HX_00FF0000             long    $00FF0000
HX_FF000000             long    $FF000000

connect                 res     1                               ' packed connection details
resettix                res     1                               ' frame reset timing
swapflag                res     1                               ' if !0, swap R & G
bit0hi                  res     1                               ' bit0 high timing
bit1hi                  res     1                               ' bit1 high timing
cycletix                res     1                               ' 1.25us cycle ticks

p_hub                   res     1                               ' pointer to pixel buffer in use
pixcount                res     1                               ' # pixels in buffer
txmask                  res     1                               ' mask for output pin

pixelbits               res     1                               ' bits per pixel
bittimer                res     1                               ' timer for reset/bit
addr                    res     1                               ' address of current rgbw pixel
npix                    res     1                               ' # of pixels to process
colorbits               res     1                               ' rgbw for current pixel
nbits                   res     1                               ' # of bits to process

t1                      res     1                               ' work vars
t2                      res     1
t3                      res     1

                        fit     496


con { license }

{{

  Terms of Use: MIT License

  Permission is hereby granted, free of charge, to any person obtaining a copy of this
  software and associated documentation files (the "Software"), to deal in the Software
  without restriction, including without limitation the rights to use, copy, modify,
  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
  permit persons to whom the Software is furnished to do so, subject to the following
  conditions:

  The above copyright notice and this permission notice shall be included in all copies
  or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
  PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
  OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

}}