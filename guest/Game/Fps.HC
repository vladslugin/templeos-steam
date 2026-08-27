/* /Game/Fps.HC - ask the window manager to composite more often.

The guest paints 29.97 times a second, and a keystroke waits for the next
composite before it can appear - half a frame on average. Worth shortening, but
read the note below before believing it was ever the main thing.

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

WHY - AND IT IS NOT THE THING THAT WAS ACTUALLY WRONG

Read the paragraph above about jiffies again, because what it treats as an
aside turned out to be the whole story. The emulated timer delivers about
sixty-five of the thousand interrupts a second the OS programs it for, so every
Sleep in the system takes about fifteen times as long as it asks for - including
the window manager's own wait for its next frame. The compositor was finishing
five frames a second, not thirty, and everything on the screen wandered to
match. /Game/Clock.HC fixes that at the source, and should be read first.

With the clock corrected, a keystroke into a still screen appears in 24ms with
this file switched off, against 75ms and a tail out to 319ms before it. So this
is a refinement now and not a rescue, and the table below was measured on the
slow clock.

What is left for it to do is the emulator's change-scan. The scan looks for
differences on a timer of its own and adds fifty milliseconds to the interval
every time it finds none - so one empty scan costs the next frame eighty
milliseconds. A guest painting at 29.97 against a scan running every 30ms is
exactly the arrangement that produces empty scans. Paint a little more often
than the scan and it always finds something:

    guest composing     stalls over 100ms      p99 gap
      30 a second          1.50 a second        112 ms
      33                   0.94                 112
      62                   0.12                 112
      80                   0.00                  33

On the corrected clock the same thing, measured end to end from a keystroke to
pixels on the wire, reads:

    pacer off      median  3ms   p90 48   max 50    emulator 12% of a core
    pacer at 60    median  4ms   p90 30   max 32                 32%
    pacer at 120   median 17ms   p90 28   max 33                 29%

which is what this file now offers: a tighter tail for a third of a core. Sixty
is what the launcher asks for, because the emulator passes on about thirty
updates a second however fast the guest paints, and asking for more than double
that buys nothing at all.

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

F64	fps_target = 0;		//the ceiling we were asked for; 0 means off
F64	fps_rate = 0;		//what we are actually pacing at, right now
Bool	fps_pacer_on = FALSE;
CTask	*fps_pacer = NULL;
//Periods the pacer was too late for. Not fatal - it catches up - but a rate
//being asked for and not achieved should say so rather than be guessed at
//from a frame counter.
I64	fps_skipped = 0;
F64	fps_window_tS = 0;
I64	fps_window_upd = 0;
I64	fps_clean = 0;

//How the rate finds its own level.
//
//Asking for sixty and taking whatever comes was the first version and it was
//wrong in a way that looked right: the average went from 29 to 68 and the
//screen got visibly worse. The compositor could not hold sixty on a desktop
//with two documents open, so it missed about one deadline a second, and what
//the eye reads is not the average - it is the variation. Measured over forty
//seconds on the same screen:
//
//    stock 29.97      median 29, min 23, max 58,   0 deadlines missed
//    asking for 60    median 68, min 25, max 99,  60 deadlines missed
//
//The second row is the higher number and the worse picture. So the rate is not
//asked for any more, it is found: back off hard when a deadline is missed,
//creep up when nothing has been missed for a while. It settles wherever this
//screen can actually be composited and follows the content when that changes -
//a full-screen game that cannot be drawn twice will push it back down to the
//OS's own rate on its own, with nobody having to notice and switch it.
#define FPS_WINDOW	0.5			//seconds
#define FPS_SHORTFALL	0.92			//below this share, back off
#define FPS_BACKOFF	0.85
#define FPS_CREEP	5.0
#define FPS_PATIENCE	2			//clean windows before creeping up

U0 FpsPacerTask(I64)
{
  F64 ideal = tS, period, achieved;
  I64 n;

  fps_window_tS = tS;
  fps_window_upd = winmgr.updates;

  while (fps_pacer_on) {
    period = 1.0 / fps_rate;

    //Advance to the next deadline in the future. More than one step means a
    //frame took longer than a period, which is the signal the rate is too high
    //for what is currently on screen.
    n = 0;
    while (ideal < tS + period / 8) {
      ideal += period;
      n++;
    }
    if (n > 1)
      fps_skipped += n - 1;

    if (tS - fps_window_tS >= FPS_WINDOW) {
      //Judge by what the compositor actually finished, not by whether a
      //deadline was tight. Counting a late frame as a miss looked like the
      //obvious signal and is useless near the bottom of the range: the OS's
      //own frames are 33.4ms apart, so at any rate close to 29.97 almost every
      //frame is a hair late and the pacer backs off from a rate it is in fact
      //holding perfectly. winmgr.updates is the compositor's own count
      //(Adam/WinMgr.HC:307) and the arithmetic is not open to interpretation.
      achieved = (winmgr.updates - fps_window_upd) / (tS - fps_window_tS);
      fps_window_upd = winmgr.updates;
      fps_window_tS = tS;

      if (achieved < fps_rate * FPS_SHORTFALL) {
	//Back off multiplicatively: a rate that cannot be held should stop
	//being asked for quickly, not eased away from.
	fps_rate *= FPS_BACKOFF;
	if (fps_rate < WINMGR_FPS)
	  fps_rate = WINMGR_FPS;
	fps_clean = 0;
      } else {
	fps_clean++;
	//And creep back additively, and only after several clean windows, so
	//one quiet moment does not undo a backoff that was right.
	if (fps_clean >= FPS_PATIENCE && fps_rate < fps_target) {
	  fps_rate += FPS_CREEP;
	  if (fps_rate > fps_target)
	    fps_rate = fps_target;
	  fps_clean = 0;
	}
      }
    }

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
  fps_rate = 0;
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
  //Start at the top and fall back if it cannot be held, not the other way
  //round. Working up from the OS's own rate was the first design and it had
  //the reasoning backwards: the low rate is the ragged one, and creeping two
  //frames at a time meant a full minute of it every time a launcher attached
  //- which is precisely the minute the player is watching hardest.
  fps_rate = fps_target;
  //A pacer already running re-reads both at the top of its loop, so changing
  //the rate does not mean starting another one. Spawning a second would leave
  //two of them poking the compositor forever.
  if (fps_pacer_on && TaskValidate(fps_pacer))
    return;
  fps_skipped = 0;
  fps_clean = 0;
  fps_pacer_on = TRUE;
  fps_pacer = Spawn(&FpsPacerTask, NULL, "FPS Pacer");
}

public F64 FpsTarget()
{//What was asked for.
  return fps_target;
}

public F64 FpsRate()
{//What it settled on.
  return fps_rate;
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

//Between one report and the next. winmgr.updates is the compositor's own
//count of frames it has finished (Adam/WinMgr.HC:272), so the difference over
//a known time is the real rate - which winmgr.fps is not.
I64	fps_mark_upd = 0;
F64	fps_mark_tS = 0;
I64	fps_lo = 0, fps_hi = 0;

public U0 FpsSample()
{/*Note the highest and lowest the OS's own counter has read.

Called from the bridge pump, which is already awake every few milliseconds.
Two compares and a load; it costs nothing and it is the only way to see a dip
that lasts one frame.

Sampling from the host instead was the obvious thing and it was useless: asking
over the wire several times a second loads the guest enough to change the
answer, and the guest then reports the slowness the asking caused. Measure from
the inside.
*/
  I64 f = ToI64(winmgr.fps);
  if (!fps_hi || f > fps_hi)
    fps_hi = f;
  if (!fps_lo || f < fps_lo)
    fps_lo = f;
}

U0 FpsOnPerf()
{/*What the guest is actually managing, since the last time anyone asked.

fps is winmgr.fps as it stands, which is one over the last frame's duration
(Adam/WinMgr.HC:231-234) and pinned at 99 under ten milliseconds - jumpy by
construction, and on its own it says almost nothing.

upd and ms are the honest pair: frames the compositor finished, and the real
milliseconds they took. lo and hi are the extremes seen since the last report,
sampled from inside the guest rather than by asking.
*/
  U8 buf[160];
  F64 now = tS;
  I64 upd = winmgr.updates - fps_mark_upd;
  I64 ms = ToI64((now - fps_mark_tS) * 1000);

  //jif is worth carrying next to ms. ms comes from tS, which is read off the
  //HPET and is always right; jif is counted one at a time by the timer
  //interrupt, and everything the OS schedules - Sleep, SleepUntil, the window
  //manager's own frame timing - is measured in it. The two should advance
  //together at a thousand to one. When they do not, the machine is running
  //slow while insisting the time is correct, and no amount of work on the
  //display path will make it feel otherwise.
  StrPrint(buf,"fps=%d target=%d rate=%d upd=%d ms=%d lo=%d hi=%d skipped=%d jif=%d",
	ToI64(winmgr.fps),ToI64(fps_target),ToI64(fps_rate),
	upd,ms,fps_lo,fps_hi,fps_skipped,cnts.jiffies);
  EvSend("perf",buf);

  fps_mark_upd = winmgr.updates;
  fps_mark_tS = now;
  fps_lo = 0;
  fps_hi = 0;
}


U0 FpsInit()
{
  eb_on_fps        = &FpsOnCmd;
  eb_on_perf       = &FpsOnPerf;
  eb_on_fps_sample = &FpsSample;
  fps_mark_upd = winmgr.updates;
  fps_mark_tS  = tS;
}
