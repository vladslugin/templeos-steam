/* /Game/Fps.HC - ask the window manager to composite more often.

The guest paints 29.97 times a second and that is most of what the player feels
as lag. A keystroke waits for the next composite before it can appear, so the
average wait is half a frame - about 17ms of the roughly 40ms between pressing a
key and seeing it, and none of it is the emulator's fault.

There is no rate to set. WINMGR_PERIOD is a #define (Kernel/KernelA.HH:1479)
already compiled into WinMgrSleep, and winmgr.fps is not an input at all - it is
a readout, overwritten from the measured frame time every pass
(Adam/WinMgr.HC:231-234). Nothing in the OS exposes the number.

What the OS does expose is a way to ask for a frame right now. Refresh() pokes
sys_winmgr_task->wake_jiffy and waits for winmgr.updates to advance
(Adam/WinMgr.HC:16-28) - that is how any task that wants the screen brought up
to date gets one. Call it on a clock of our own and the compositor runs at our
rate instead of its own. Its own deadline keeps advancing a period at a time
(WinMgr.HC:267-268) and simply never arrives first.

Which also means there is nothing to undo. Stop asking and the next frame is
paced by the OS again, on a deadline it has been maintaining all along.

TWO THINGS THIS GETS RIGHT THAT THE OBVIOUS VERSION DOES NOT.

Poke in a loop, not once. Writing wake_jiffy directly looks equivalent and is
not: the compositor yields inside its own composite (Adam/DocRecalc.HC:285), and
a poke landing while it is between deciding its next deadline and going to sleep
is overwritten by SleepUntil's own store (Kernel/KMisc.HC:150) and lost. Refresh
re-pokes until it sees the frame counter move, which is why it is used here
rather than reimplemented.

Accumulate in seconds, not in jiffies. Under emulation the timer does not
deliver the ticks the OS asks for - a jiffy-counted period comes out badly slow
- while tS is real time and a tS accumulator converges on the target whatever
the tick rate does. This is Terry's own trick, from the loop at WinMgr.HC:267.

WHAT IT COSTS

The compositor holds the core while it paints, and this OS does not preempt, so
doubling the rate roughly doubles the share of the machine it takes - including
the share our own bridge pump needs. Measured before adopting; see the commit.

A full-screen animating game is the case where this is wrong: the compositor
alone cannot go much above thirty frames when every pixel changes, and taking
half the core from a game to composite it twice is a poor trade. FpsOff puts it
back.

Public domain.
*/

#help_index "Game/Fps"

F64	fps_target = 0;		//0 means the OS is pacing itself
Bool	fps_pacer_on = FALSE;
CTask	*fps_pacer = NULL;
//Periods the pacer was too late for. Not fatal - it catches up - but a rate
//that is being asked for and not achieved should say so rather than be
//guessed at from a frame counter.
I64	fps_skipped = 0;

U0 FpsPacerTask(I64)
{
  F64 ideal = tS, period;
  I64 n;

  while (fps_pacer_on) {
    period = 1.0 / fps_target;

    //Advance to the next deadline in the future. More than one step means a
    //frame took longer than a period and the rate is not being met.
    n = 0;
    while (ideal < tS + period / 8) {
      ideal += period;
      n++;
    }
    if (n > 1)
      fps_skipped += n - 1;

    SleepUntil(cnts.jiffies + (ideal - tS) * JIFFY_FREQ);
    if (!fps_pacer_on)
      break;
    Refresh(1, TRUE);
  }
  fps_pacer = NULL;
}

public U0 FpsOff()
{//Back to the OS's own 29.97. Nothing to restore; it never stopped keeping time.
  fps_pacer_on = FALSE;
  fps_target = 0;
}

public U0 FpsSet(F64 fps=60.0)
{/*Ask for a composite rate. Below the OS's own rate is meaningless - it paces
itself at 29.97 regardless - so anything lower just turns the pacer off.
*/
  if (fps < WINMGR_FPS) {
    FpsOff;
    return;
  }
  fps_target = fps;
  //A pacer already running re-reads the target at the top of its loop, so
  //changing the rate does not mean starting another one. Spawning a second
  //would leave two of them poking the compositor forever.
  if (fps_pacer_on && TaskValidate(fps_pacer))
    return;
  fps_skipped = 0;
  fps_pacer_on = TRUE;
  fps_pacer = Spawn(&FpsPacerTask, NULL, "FPS Pacer");
}

public F64 FpsTarget()
{
  return fps_target;
}

public I64 FpsSkipped()
{
  return fps_skipped;
}


U0 FpsOnCmd(I64 n)
{//The launcher asking for a rate. Zero means hand pacing back to the OS.
  if (n <= 0)
    FpsOff;
  else
    FpsSet(n);
}

U0 FpsOnPerf()
{/*What the guest is actually managing.

winmgr.fps is the OS's own measurement, taken from the last frame time
(Adam/WinMgr.HC:231-234), so it is instantaneous rather than an average - which
is worth knowing when reading it. target is what we asked for and skipped is
how often we did not get it.
*/
  U8 buf[96];
  StrPrint(buf,"fps=%d target=%d skipped=%d",
	ToI64(winmgr.fps),ToI64(fps_target),fps_skipped);
  EvSend("perf",buf);
}

U0 FpsInit()
{
  eb_on_fps  = &FpsOnCmd;
  eb_on_perf = &FpsOnPerf;
}
