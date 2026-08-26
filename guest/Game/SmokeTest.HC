/* /Game/SmokeTest.HC - does the game layer's HolyC actually compile?

Every construct here was typed into a live TempleOS 5.03 shell and watched
compile before it went in. The layer leans on all of them, and several were
guesses until they were run - HolyC is close enough to C to lull you and
different enough to bite.

Run it from the shell:

    #include "/Game/SmokeTest";
    SmokeTest;

A pass prints one line per group and returns TRUE. Anything that fails to
compile stops the include with a compiler error naming the line, which is the
point: this file is the canary for a HolyC change breaking the layer.

Public domain.
*/

#help_index "Game/SmokeTest"

// 1. class with an array member, and an array of instances.
//    Comm.HC keeps per-port state exactly this way.
class CSmokeRec
{
  U8	buf[64];
  I64	len,
	flags;
  U8	*ptr;
} smoke_recs[3];

// 2. default arguments.
U0 SmokeDefault(I64 n, I64 m=3, U8 *tag=NULL)
{
  I64 k = n + m;
  if (tag)
    "%s ", tag;
  "%d ", k;
}

// 3. interrupt handler shape plus port I/O. Comm.HC installs two of these.
//    Not hooked to a vector here - this only proves it compiles.
interrupt U0 SmokeIRQ()
{
  OutU8(0x20, 0x20);
}

// 4. a global function pointer with an initialiser. EventBridge dispatches
//    incoming commands through a table of these.
U0 (*smoke_fp)(I64 x) = NULL;

U0 SmokeTarget(I64 x)
{
  "fp:%d ", x;
}

// 5. interrupt-safe section. CommPutChar and CommGetChar both wrap FIFO
//    access in this.
U0 SmokeCritical()
{
  PUSHFD
  CLI
  smoke_recs[0].len++;
  POPFD
}

// 6. a task body. Spawn hands it a data pointer the body may ignore, and an
//    unnamed parameter is legal.
U0 SmokeTask(U8 *)
{
  "task ";
}

public Bool SmokeTest()
{
  U8 buf[64];
  I64 v;
  CTask *t;

  "$$LTBLUE$$SmokeTest$$FG$$\n";

  "  types+class : ";
  smoke_recs[0].len = 0;
  StrCpy(smoke_recs[0].buf, "abc");
  "len=%d str=%s\n", StrLen(smoke_recs[0].buf), smoke_recs[0].buf;

  "  defaults    : ";
  SmokeDefault(1);
  SmokeDefault(1, 2);
  SmokeDefault(1, 2, "tag");
  '\n';

  "  strings     : ";
  StrPrint(buf, "a=%d", 42);
  v = Str2I64("77");
  "%s v=%d cmp=%d\n", buf, v, MemCmp("abc", "abd", 3);

  "  critical    : ";
  SmokeCritical;
  "len=%d\n", smoke_recs[0].len;

  "  fn pointer  : ";
  smoke_fp = &SmokeTarget;
  (*smoke_fp)(7);
  '\n';

  "  time        : ";
  "jiffies=%d freq=%d\n", cnts.jiffies, JIFFY_FREQ;

  "  spawn       : ";
  t = Spawn(&SmokeTask, NULL, "smoke");
  Sleep(50);
  "task=%08X\n", t;

  "  fifo        : ";
  {
    CFifoU8 *f = FifoU8New(16);
    U8 got = 0;
    Bool ok;
    FifoU8Ins(f, 'X');
    ok = FifoU8Rem(f, &got);
    "ins/rem=%d got=%c\n", ok, got;
    FifoU8Del(f);
  }

  "$$LTGREEN$$SmokeTest passed$$FG$$\n";
  return TRUE;
}
