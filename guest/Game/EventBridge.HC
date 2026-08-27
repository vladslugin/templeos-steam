/* /Game/EventBridge.HC - line protocol between the OS and the host.

Runs over COM1 via /Game/Comm.HC. ASCII lines, LF terminated, 240 bytes max.

    guest -> host                    host -> guest
      HELLO <proto> <os> <layer>       ACK <event_id>
      EV <event_id> [<k>=<v> ...]      CMD load_task id=<id>
      HB <jiffies>                     CMD check_task id=<id>
      LOG <text>                       CMD hint id=<id> level=<1..3>
                                       CMD reset_home
                                       CMD set_lang <en|ru>
                                       CMD ms x=<n> y=<n> b=<n> [w=<n>]
                                       CMD ms_report
                                       CMD fps n=<rate>
                                       CMD clock n=<0|1>
                                       CMD perf
                                       CMD hello

HELLO is sent once when the layer starts, which is usually before anything is
listening. `CMD hello` asks for it again, so a launcher that attaches to an
already-running guest can still find out what it is talking to - it needs the
layer version to know whether the pointer can come down this wire.

If no host is listening the whole layer goes quiet and the OS stays exactly as
it was. That is deliberate. Someone who boots this image without the launcher
should get a clean, fully working TempleOS, not a crippled one nagging them to
start a game.

Public domain.

Not yet run in a VM.
*/

#help_index "Game/EventBridge"

#define EB_PORT		1		//COM1, base 0x3F8
#define EB_BAUD		115200
#define EB_PROTO_VER	1
#define EB_LAYER_VER	"0.2.0"
#define EB_LINE_MAX	240
#define EB_HB_MS	1000

class CEvBridge
{
  CTask	*owner;			//the task the layer was started from
  Bool	up,			//host has answered at least once
	hello_acked;
  I64	seed,
	sent_cnt,
	recv_cnt,
	last_hb_jiffy;
  U8	last_ack[64];
} eb;

U0 EvRaw(U8 *line)
{//Send a prepared line. No-op when nothing is listening.
  if (!CommIsEnabled(EB_PORT)) return;
  CommPutS(EB_PORT,line);
  CommPutChar(EB_PORT,'\n');
  eb.sent_cnt++;
}

public U0 EvSend(U8 *id,U8 *kv=NULL)
{/*Emit an event.

No validation of id against the whitelist here. We are in ring 0 - anything we
checked could be bypassed in four keystrokes, and the host has to filter its
own input anyway. The only thing worth enforcing on this side is the line
length, because that would corrupt the framing.
*/
  U8 buf[EB_LINE_MAX+2];
  if (!CommIsEnabled(EB_PORT)) return;
  if (kv && *kv)
    StrPrint(buf,"EV %s %s",id,kv);
  else
    StrPrint(buf,"EV %s",id);
  buf[EB_LINE_MAX]=0;
  EvRaw(buf);
}

public U0 EvLog(U8 *fmt,...)
{/*Free text up to the host.

The host also reads this channel to catch compiler diagnostics and pair them
with a plain-English explanation for beginners. The original message always
stays on screen - we annotate, we do not replace.
*/
  U8 *msg=StrPrintJoin(NULL,fmt,argc,argv);
  U8 buf[EB_LINE_MAX+2];
  StrPrint(buf,"LOG %s",msg);
  buf[EB_LINE_MAX]=0;
  EvRaw(buf);
  Free(msg);
}

public I64 EvSig(U8 *task_id)
{/*Session hash attached to task_done.

This is not anti-cheat and is not meant to be. Anti-cheat in ring 0 is a
fiction, and a player who works out how to poke events into the serial port by
hand has learned exactly what this game is trying to teach. All it does is stop
a double-fired check from awarding the same task twice, so a cheap rolling hash
is enough.
*/
  I64 h=eb.seed;
  U8 *p=task_id;
  while (*p)
    h=h*131+*p++;
  return h & 0x7FFFFFFF;
}

public U0 EvTaskDone(U8 *task_id,Bool hinted)
{//hinted means the player opened the full solution. It costs them nothing
 //except the one campaign-wide achievement for never looking.
  U8 buf[EB_LINE_MAX];
  StrPrint(buf,"id=%s sig=%08X hinted=%d",task_id,EvSig(task_id),hinted!=0);
  EvSend("task_done",buf);
}

/* Incoming commands. TaskRunner installs the handlers - the transport has no
   business knowing what a task is. */

U0 (*eb_on_load_task)(U8 *id)=NULL;
U0 (*eb_on_check_task)(U8 *id)=NULL;
//Pointer position, sixty times a second while the player is moving the mouse.
//Installed by MsBridge; see /Game/MsBridge.HC for why the pointer comes down
//this wire at all instead of arriving as PS/2 movement like a real mouse.
U0 (*eb_on_ms)(I64 x,I64 y,I64 b,I64 w)=NULL;
//Asked for by the launcher when it wants to check itself.
U0 (*eb_on_ms_report)()=NULL;
//Composite rate: the launcher raises it for the desktop and drops it back for
//anything that paints the whole screen every frame.
U0 (*eb_on_fps)(I64 n)=NULL;
U0 (*eb_on_perf)()=NULL;
U0 (*eb_on_fps_sample)()=NULL;
//Whether the guest corrects its jiffy count against the HPET rather than
//trusting the timer interrupt to arrive. See /Game/Clock.HC.
U0 (*eb_on_clock)(I64 n)=NULL;
U0 (*eb_on_hint)(U8 *id,I64 level)=NULL;
U0 (*eb_on_reset_home)()=NULL;
U0 (*eb_on_set_lang)(U8 *lang)=NULL;

U8 *EbFindVal(U8 *line,U8 *key,U8 *dst,I64 dst_size)
{//Pull key=value out of a line. NULL if absent.
 //Deliberately dumb: it is our own protocol, plain ASCII, no quoting.
  I64 klen=StrLen(key),i=0;
  U8 *p=line;
  while (*p) {
    if (!MemCmp(p,key,klen) && p[klen]=='=') {
      p+=klen+1;
      while (*p && *p!=' ' && i<dst_size-1)
	dst[i++]=*p++;
      dst[i]=0;
      return dst;
    }
    while (*p && *p!=' ') p++;
    while (*p==' ') p++;
  }
  return NULL;
}

U0 EbSendHello()
{//Who we are. Sent once at start-up and again whenever a host asks.
  U8 buf[128];
  StrPrint(buf,"HELLO %d %s %s",EB_PROTO_VER,"TempleOS-5.03",EB_LAYER_VER);
  EvRaw(buf);
}

U0 EbHandleCmd(U8 *line)
{//line has already had "CMD " stripped.
  U8 id[64],lvl[8],lang[8],v[16];

  //First, because it arrives far more often than everything else together.
  //Every line carries the complete pointer state rather than what changed, so
  //a line lost to a full receive FIFO costs one frame of pointer and heals
  //itself on the next one.
  if (!MemCmp(line,"ms ",3)) {
    I64 x,y,b=0,w=0;
    if (!EbFindVal(line,"x",v,sizeof(v))) return;
    x=Str2I64(v);
    if (!EbFindVal(line,"y",v,sizeof(v))) return;
    y=Str2I64(v);
    if (EbFindVal(line,"b",v,sizeof(v)))
      b=Str2I64(v);
    if (EbFindVal(line,"w",v,sizeof(v)))
      w=Str2I64(v);
    if (eb_on_ms)
      (*eb_on_ms)(x,y,b,w);
  } else if (!MemCmp(line,"load_task",9)) {
    if (EbFindVal(line,"id",id,sizeof(id)) && eb_on_load_task)
      (*eb_on_load_task)(id);
  } else if (!MemCmp(line,"check_task",10)) {
    if (EbFindVal(line,"id",id,sizeof(id)) && eb_on_check_task)
      (*eb_on_check_task)(id);
  } else if (!MemCmp(line,"hint",4)) {
    if (EbFindVal(line,"id",id,sizeof(id)) && eb_on_hint) {
      if (!EbFindVal(line,"level",lvl,sizeof(lvl)))
	StrCpy(lvl,"1");
      (*eb_on_hint)(id,Str2I64(lvl));
    }
  } else if (!MemCmp(line,"fps",3)) {
    if (EbFindVal(line,"n",v,sizeof(v)) && eb_on_fps)
      (*eb_on_fps)(Str2I64(v));
  } else if (!MemCmp(line,"clock",5)) {
    if (EbFindVal(line,"n",v,sizeof(v)) && eb_on_clock)
      (*eb_on_clock)(Str2I64(v));
  } else if (!MemCmp(line,"perf",4)) {
    if (eb_on_perf) (*eb_on_perf)();
  } else if (!MemCmp(line,"ms_report",9)) {
    if (eb_on_ms_report) (*eb_on_ms_report)();
  } else if (!MemCmp(line,"hello",5)) {
    EbSendHello;
  } else if (!MemCmp(line,"reset_home",10)) {
    if (eb_on_reset_home) (*eb_on_reset_home)();
  } else if (!MemCmp(line,"set_lang",8)) {
    U8 *p=line+8;
    while (*p==' ') p++;
    StrCpy(lang,p);
    if (eb_on_set_lang) (*eb_on_set_lang)(lang);
  } else
    EvLog("unknown CMD: %s",line);
}

U0 EbHandleLine(U8 *line)
{
  eb.recv_cnt++;
  if (!MemCmp(line,"ACK ",4)) {
    StrCpy(eb.last_ack,line+4);
    eb.up=TRUE;
    eb.hello_acked=TRUE;
  } else if (!MemCmp(line,"CMD ",4))
    EbHandleCmd(line+4);
  else
    EvLog("unparsed: %s",line);
}

U0 EbPumpTask(U8 *)
{/*Drain the port and keep the heartbeat going.

Sleep rather than a bare Yield. Polling every few milliseconds is plenty, and
a Yield loop would peg a core for nothing.
*/
  U8 line[EB_LINE_MAX+2],buf[64];

  while (TRUE) {
    //Service the port before reading from it. The interrupt does this too,
    //but it cannot be relied on to keep firing - see CommPump in /Game/Comm.HC
    //for what goes wrong and how it looks from the outside.
    CommPump(EB_PORT);

    while (CommGetLine(EB_PORT,line,sizeof(line)))
      EbHandleLine(line);

    if (cnts.jiffies-eb.last_hb_jiffy >= JIFFY_FREQ) {
      eb.last_hb_jiffy=cnts.jiffies;
      StrPrint(buf,"HB %d",cnts.jiffies);
      EvRaw(buf);
    }
    //Two compares, so the frame-rate report has something real to say. See
    //FpsSample in /Game/Fps.HC for why it is sampled here and not asked for
    //from the host.
    if (eb_on_fps_sample)
      (*eb_on_fps_sample)();

    CommPump(EB_PORT);
    Sleep(4);
  }
}

public U0 EvBridgeInit()
{//Safe to call with no host present.
  U8 buf[EB_LINE_MAX];

  MemSet(&eb,0,sizeof(CEvBridge));
  //Remember who started us. Commands arriving on the wire are typed into this
  //task rather than run in the pump, because a spawned task is not a terminal:
  //swapping its put_doc does not redirect printing (DocPut reads it, but the
  //window manager owns the field), so output capture only works here. Typing
  //into another task is the OS's own idiom - Misc/OSInstall.HC:152 drives the
  //boot-loader installer exactly this way.
  eb.owner=Fs;
  eb.seed=cnts.jiffies ^ (cnts.jiffies<<17);
  eb.last_hb_jiffy=cnts.jiffies;

  CommInit8n1(EB_PORT,EB_BAUD);

  EbSendHello;

  Spawn(&EbPumpTask,NULL,"EventBridge");
}

U8 *EbYesNo(Bool b)
{
  if (b) return "yes";
  return "no";
}

public U0 EvBridgeRep()
{//Bridge status. Handy when debugging, and the kernel chapter points at it.
  "$$LTBLUE$$EventBridge$$FG$$  port COM%d @ %d baud\n",EB_PORT,EB_BAUD;
  "  enabled : %s\n",EbYesNo(CommIsEnabled(EB_PORT));
  "  host up : %s\n",EbYesNo(eb.up);
  "  sent    : %d\n",eb.sent_cnt;
  "  recv    : %d\n",eb.recv_cnt;
  "  last ACK: %s\n",eb.last_ack;
}
