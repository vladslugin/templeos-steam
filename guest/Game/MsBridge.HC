/* /Game/MsBridge.HC - put the pointer exactly where the player is pointing.

The launcher knows where the player's hand is. Until now it had no way to say
so: RFB carries an absolute position, the emulator turns consecutive positions
into PS/2 movement, and PS/2 movement is relative. A relative device can be
made to track - scale it right, do not lose packets, agree on a starting corner
- and /Game/Pointer.HC does all three. But it is still an integral, and an
integral only has to be wrong once. After that the cursor is somewhere else
forever, and the player finds they cannot reach the bottom-left corner of the
screen because they run out of desk first.

So stop integrating. The host sends a position over the bridge and we put the
pointer there.

THE CALL

MsSet is Terry's own public entry point for this, declared in
Kernel/KernelC.HH:614 and defined at Kernel/SerialDev/Mouse.HC:42. It is the
only correct way in, because it writes both halves of the mouse state:

    MsSet(x,y,z,l,r)
      -> MsUpdate    Mouse.HC:59   ms.presnap, ms.pos, ms.pos_text, ms.lb/rb
      -> MsHardSet   Mouse.HC:60   ms_hard.prescale, ms_hard.bttns

The second half is what makes it stick. ms_hard.prescale is the accumulator
every future PS/2 delta is added to, and the window manager re-derives ms.pos
from it on any packet at all (Adam/Win.HC:226-227 passes ms_hard.pos, never
ms.pos). Write ms.pos by hand and the next packet drags the cursor back;
re-base the accumulator and there is nothing to drag it back to.

Nothing in the OS recomputes the position on a timer. WinMsUpdate only acts
when ms_hard.evt is set (Adam/Win.HC:225), ms_hard.evt is set only by
MsHardSetPost (Mouse.HC:225,230), and MsHardSetPost runs only on a real packet
or from MsHardSet. So a position we write stays written - not for a while,
indefinitely.

THE TRAPS

MsSet does not clamp an out-of-range coordinate, it IGNORES it -

    if (!(0<=x<GR_WIDTH))  x=ms.pos.x;
    Kernel/SerialDev/Mouse.HC:44-47

- which means a bad number does not put the cursor at the edge, it freezes that
axis. Clamping is the caller's job and it is done below.

MsHardSet divides by ms_grid.x_speed (Mouse.HC:276-278). GridInit sets it to
1.0, but the Cmd/Grid form a player can open with Ctrl-Alt-G lets them type
zero into it (Adam/Win.HC:100-113), and every MsSet after that would divide by
it. Checked on every call rather than once at start-up, because start-up is not
when the player opens that form.

And screen zoom. Ctrl-Alt-Z (Adam/Gr/GrEnd.HC:8) scales what the framebuffer
shows, so under zoom a pixel on the host is no longer a pixel in the guest, and
the two ends stop agreeing about what a coordinate means. Rather than forbid a
feature of the OS, the position is mapped through the zoom window on the way
in. Zoom stays usable and the pointer stays under the hand.

LATENCY

Better than the path it replaces, slightly. PS/2 packets are drained from
ms_hard.fifo2 at the END of a window-manager frame (Adam/WinMgr.HC:309) and
only turned into a position at the start of the next one (:263) - a built-in
frame of lag. MsSet writes the position immediately, so the next screen update
paints it. Against that, the bridge pump polls every 4ms. Net win.

Public domain.
*/

#help_index "Game"

//What the host last told us. Kept so the wheel can be moved without also
//having to be told the position again.
class CMsBridgeState
{
  I64	x, y;
  Bool	lb, rb;
  I64	wheel;
  I64	cnt;		//how many positions the host has pushed
  Bool	primed;
} ms_bridge;

U0 MsBridgeGuardGrid()
{/*MsHardSet divides by these. A zero here is a divide fault on every pointer
move, and the form that can set one is two keystrokes away.
*/
  if (!ms_grid.x_speed) ms_grid.x_speed = 1.0;
  if (!ms_grid.y_speed) ms_grid.y_speed = 1.0;
  if (!ms_grid.z_speed) ms_grid.z_speed = 1.0;
}

public U0 MsAbs(I64 x, I64 y, Bool l, Bool r)
{/*Put the pointer at (x,y) with these buttons, in framebuffer coordinates.

x and y are where the player is pointing on the picture they can see. Under
screen zoom that is a window onto the guest's screen rather than the whole of
it, so map through the window: gr.sx is its top-left and gr.scrn_zoom its
magnification (Adam/Gr/GrScrn.HC:97-103).
*/
  if (gr.scrn_zoom > 1) {
    x = gr.sx + x / gr.scrn_zoom;
    y = gr.sy + y / gr.scrn_zoom;
  }

  x = ClampI64(x, 0, GR_WIDTH  - 1);
  y = ClampI64(y, 0, GR_HEIGHT - 1);

  MsBridgeGuardGrid;

  //Interrupts off across the write. MsUpdate sets ms.pos.x and ms.pos.y one
  //after the other, and DrawMs reads them the same way under its own CLI
  //(Adam/Win.HC:177-181) - without this a handler landing between the two
  //could draw the cursor at the new x and the old y. It is not about
  //preemption; this OS does not preempt.
  PUSHFD
  CLI
  MsSet(x, y, , l, r);
  POPFD

  ms_bridge.x = x;
  ms_bridge.y = y;
  ms_bridge.lb = l;
  ms_bridge.rb = r;
  ms_bridge.primed = TRUE;
  ms_bridge.cnt++;
}

public U0 MsAbsWheel(I64 z)
{/*Move the wheel. z is the absolute accumulator ms.pos.z, not a delta - the
host keeps the running total and applications here diff it themselves
(Adam/WinMgr.HC:641).

Does nothing before the first MsAbs: without a known position there is nothing
to hold the pointer still at while the wheel turns.
*/
  if (!ms_bridge.primed)
    return;
  MsBridgeGuardGrid;
  ms_bridge.wheel = z;
  PUSHFD
  CLI
  MsSet(ms_bridge.x, ms_bridge.y, z, ms_bridge.lb, ms_bridge.rb);
  POPFD
}

U0 MsBridgeOnMs(I64 x, I64 y, I64 b, I64 w)
{//What the bridge hands us: position, a button bitmap, and a wheel total.
 //Bit 0 is the left button and bit 1 the right; TempleOS has no middle one
 //(MsUpdate takes two, Mouse.HC:9).
  MsAbs(x, y, b & 1, (b >> 1) & 1);
  if (w != ms_bridge.wheel)
    MsAbsWheel(w);
}

public U0 MsReport()
{/*Say where the pointer actually is.

Not for the game - for the person building it. The launcher knows where it put
the pointer and the guest knows where the pointer is, and until those two
numbers could be compared in one place, the difference between them was found
by photographing the screen and guessing. This makes the launcher able to check
itself, and --stats prints both.
*/
  U8 buf[64];
  StrPrint(buf,"x=%d y=%d bx=%d by=%d n=%d",
	ms.pos.x,ms.pos.y,ms_bridge.x,ms_bridge.y,ms_bridge.cnt);
  EvSend("ms_at",buf);
}

U0 MsBridgeInit()
{
  MemSet(&ms_bridge, 0, sizeof(CMsBridgeState));
  eb_on_ms = &MsBridgeOnMs;
  eb_on_ms_report = &MsReport;
}
