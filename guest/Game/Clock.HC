/* /Game/Clock.HC - keep the guest's idea of time honest.

TempleOS keeps two clocks and only one of them is any good under an emulator.

tS reads the HPET (Kernel/KMisc.HC:122-128) and is right to the microsecond.
cnts.jiffies is counted one at a time by the timer interrupt
(Kernel/KMisc.HC:53) - and jiffies is the one that matters, because Sleep,
SleepUntil and the window manager's own frame timing (Adam/WinMgr.HC:269) are
all measured in it. Seconds are for showing the player; jiffies are what the
machine actually runs on.

Under the emulator the two come apart badly. The 8254 is programmed for a
thousand interrupts a second (SYS_TIMER0_PERIOD, KernelA.HH:570-573) and
delivers about sixty-five, because the host can only wake so often and a period
that is missed is never made up - the emulated chip has no way of saying "that
was fifteen ticks, not one". So the OS runs about fifteen times slower than it
believes: Sleep(33) waits half a second, the compositor asks for thirty frames
and finishes five, and everything on screen wades.

Nothing is broken in the OS and nothing is broken in the display path. Both were
gone through at length first, which is how the two clocks came to be printed
next to each other and the gap noticed. The clock is slow and everything
downstream of it is slow by exactly the same factor.

So stop counting interrupts and read the clock that works. This wakes on each
interrupt that does arrive, works out how much real time went by, and hands the
count the ticks the interrupt failed to deliver. Only what went missing since
the last look, and never more than CLOCK_MAX_STEP at a time - the count is
already thousands behind by the time this starts, and closing that gap in one
step would fire every sleeping task in the system at once.

What this cannot do is invent interrupts. Corrections land at whatever rate the
timer manages, so jiffies advance in steps of about fifteen rather than one, and
a Sleep shorter than that still waits that long. The rate is right, the grain is
coarse - which is the difference between a machine that feels slow and one that
feels normal.

Public domain.
*/

#help_index "Game/Clock"

Bool	clock_on = FALSE;
CTask	*clock_task = NULL;
I64	clock_steps = 0;	//corrections applied since the last report
I64	clock_worst = 0;	//furthest behind, in jiffies, ever seen

#define CLOCK_MAX_STEP	200	//jiffies to make up in one go, at most

//The fixed point everything is measured from: the moment correcting started,
//and the count as it stood then.
//
//Measuring from a moving mark instead - "how many went missing since I last
//looked" - loses the fraction on every call, because a count of jiffies is a
//whole number and 4.7 of them hands over 4. One caller a few times a second
//barely notices. Two callers two hundred times a second lose about a seventh
//of the clock, which is exactly the drift from a thousand a second down to the
//eight hundred and fifty this was doing before.
F64	clock_base_tS = 0;
I64	clock_base_jif = 0;

public U0 ClockTick()
{/*Hand the count whatever the interrupt failed to deliver since the last look.

Correct the rate, never the reading. Setting jiffies to tS*JIFFY_FREQ outright
looks tidier and is a trap: by the time this starts, the count is already
thousands behind, and closing that in one step would fire every sleeping task
in the system at once, in the middle of boot.

The whole thing runs with interrupts off, and not only the write. The other
writer of jiffies is the timer handler, which runs on core 0 and nowhere else -
it forwards to the other cores with MPInt rather than being taken up by them
(Kernel/KMisc.HC:47-58) - and both callers of this are on core 0. But the mark
has to move under the same guard as the count, or two callers can each read the
same shortfall and hand it over twice.
*/
  I64 want, owed;

  if (!clock_on)
    return;
  //Where the count should be by now, measured from the fixed base. Absolute
  //rather than incremental, so nothing is lost between calls and it does not
  //matter how often or how irregularly this is reached.
  want = clock_base_jif + ToI64((tS - clock_base_tS) * JIFFY_FREQ);
  PUSHFD
  CLI
  owed = want - cnts.jiffies;
  if (owed > CLOCK_MAX_STEP)
    owed = CLOCK_MAX_STEP;	//a stall is caught up over the next few calls
  if (owed > 0) {
    cnts.jiffies += owed;
    //cnts.timer is the same count in 8254 ticks, and is what SysTimerRead works
    //from. Nothing reads it while the HPET is up, but letting the two drift
    //apart would leave a trap for whoever looks next.
    cnts.timer += owed * (SYS_TIMER0_PERIOD + 1);
    clock_steps++;
    if (owed > clock_worst)
      clock_worst = owed;
  }
  POPFD
}

U0 ClockTask(I64)
{/*The corrector's own heartbeat.

Sleep(1) wakes this on the next timer interrupt, which is as often as there is
anything to correct. It is not the only caller: the bridge pump calls ClockTick
too, because with the compositor paced and the error watcher running, this task
does not get the processor on every interrupt and the count drifts to about
eight hundred and fifty a second instead of a thousand. Two callers on
different schedules hold it near the top.
*/
  while (clock_on) {
    Sleep(1);
    ClockTick;
  }
  clock_task = NULL;
}

public U0 ClockOff()
{//Back to counting interrupts, and to running fifteen times slow.
  clock_on = FALSE;
}

public U0 ClockOn()
{/*Start correcting.

Refused without an HPET, and that refusal is the whole safety argument: with no
HPET, tS falls back to SysTimerRead, which is built out of cnts.timer, which is
counted by the same interrupt that is being distrusted (Kernel/KMisc.HC:122-128,
61-78). Correcting jiffies from that would be correcting a clock against itself.
Every machine this game runs on is an emulated PC with an HPET, so the fallback
is a matter of not being quietly wrong rather than a case anyone will meet.
*/
  if (!cnts.HPET_freq) {
    "$$RED$$Clock: no HPET, leaving the timer alone.$$FG$$\n";
    return;
  }
  if (clock_on)
    return;
  clock_on = TRUE;
  clock_steps = 0;
  clock_worst = 0;
  clock_task = Spawn(&ClockTask, NULL, "Clock", 0);
}

public U0 ClockSet(Bool on)
{
  if (on)
    ClockOn;
  else
    ClockOff;
}

public I64 ClockRate()
{/*Interrupts a second the timer is actually managing.

Sampled rather than counted: two readings of the two clocks, a moment apart.
Worth having as a number because it is the one figure that says whether this
file is needed on a given host at all.
*/
  I64 j0, res;
  F64 t0;
  Bool was = clock_on;

  clock_on = FALSE;		//stop correcting, or this measures itself
  Sleep(50);			//let the task notice and leave the loop
  j0 = cnts.jiffies;
  t0 = tS;
  Sleep(100);
  res = ToI64((cnts.jiffies - j0) / (tS - t0));
  if (was)
    ClockOn;
  return res;
}

U0 ClockOnCmd(I64 n)
{
  ClockSet(n != 0);
}

U0 ClockStartTask(I64)
{/*Wait for the machine to finish coming up, then start correcting.

Calling ClockOn straight from GameInit does not take. GameInit runs inside the
Adam task while the boot script is still going, and a corrector started from
there never gets anywhere - the layer either does not finish loading or the task
does not run. Rather than guess which, this waits until boot is over and starts
it from a task of its own, where it demonstrably works.

A hundred jiffies is about a second and a half of real time at the uncorrected
rate, which is the point: while the clock is still slow, so is this wait.
*/
  Sleep(100);
  ClockOn;
}

U0 ClockInit()
{
  eb_on_clock = &ClockOnCmd;
  eb_on_clock_tick = &ClockTick;
  Spawn(&ClockStartTask, NULL, "Clock start");
}
