/* /Game/Pointer.HC - make the pointer land where the player points it.

TempleOS drives a PS/2 mouse, which reports movement rather than position, and
the driver halves that movement on the way in:

    ms_hard.scale.x=0.5;
    ms_hard.scale.y=0.5;
    Kernel/SerialDev/Mouse.HC:358-359

A sensible default for a hand on a desk. The wrong one here, because what
arrives over the wire is already in screen pixels: the launcher knows exactly
where on the guest's 640x480 the player is pointing and sends that position,
and the emulator turns consecutive positions back into movement. Halve it and
the pointer travels half as far as the hand does, so the two drift apart and
never recover - which is exactly what it looks like, a cursor that is not where
it really is.

Measured against a running guest before this file existed. Asked to move:

     50 px  ->   25 px      250 px  ->  125 px
    200 px  ->  100 px      400 px  ->  200 px

and with the scale below, all of them exact.

This is the knob Terry documented for it. /HomeLocalize.HC carries the same
three lines under "adjust these to set mouse move scale", and the prescale
recompute is his as well: the position is derived from prescale, so changing
the scale without recomputing prescale teleports the pointer.

The grid below is the other half, and it is subtler. Knowing how far the
pointer moved is not the same as knowing where it is: the launcher has to get
the two ends to agree on a starting point, and the way to do that with a device
that only reports movement is to run the pointer into a corner and let the
guest's own clamp stop it. Except that the clamp is computed on the position
rounded down to the grid -

    i=Trunc(ms.scale.x*ms_hard.pos.x/ms_grid.x)*ms_grid.x+ms.offset.x;
    if (i<0) ms.offset.x-=i;
    Kernel/SerialDev/Mouse.HC:210-214

- and the grid is 8, so a pointer pinned in the corner can be anywhere in the
first eight pixels. It comes to rest seven pixels off and stays there, at every
position, forever. A grid of 1 makes the clamp exact and the corner mean the
corner. Nothing else reads it while ms_grid.snap is FALSE, which it is by
default; a player who turns snapping on gets a one-pixel grid, which is to say
no snapping, and that is the whole cost.

One limit remains and belongs to the wire, not here. A PS/2 packet carries nine
signed bits of movement per axis, so a single jump of more than about 255
pixels arrives clipped. Ordinary movement is nowhere near that - it is a
handful of pixels per report - and the launcher breaks up the one case that is,
the pointer re-entering the guest's screen from somewhere else.

Public domain.
*/

#help_index "Game"

public U0 PointerScaleSet(F64 x, F64 y)
{/*Set how far the pointer travels per unit of reported movement.

1.0 means it goes exactly as far as it is told, which is what the launcher
wants. Terry's default is 0.5.
*/
  ms_hard.scale.x = x;
  ms_hard.scale.y = y;
  //Not optional: pos is prescale*scale, so changing scale alone moves the
  //pointer. This puts prescale back in step with where it already is.
  ms_hard.prescale.x = ms_hard.pos.x / ms_hard.scale.x;
  ms_hard.prescale.y = ms_hard.pos.y / ms_hard.scale.y;
}

U0 PointerInit()
{
  PointerScaleSet(1.0, 1.0);
  //So that running the pointer into a corner leaves it in the corner, and the
  //launcher and the guest can agree where it is.
  ms_grid.x = 1;
  ms_grid.y = 1;
}
