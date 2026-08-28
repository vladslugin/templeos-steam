/* /Game/TaskRunner.HC - loads a campaign task, checks the player's answer.

The check works by compiling what the player wrote and then calling it, using
the compiler the OS already has:

    ExeFile(path)        compile and run the player's file
    ExePrint("Fib(%d);") compile and run a call, and hand back its value

That is the shell's own trick - typing an expression at the prompt runs exactly
this path - so a task is checked by the same machinery the player is learning.

ONE TRAP, and the reason TaskFunExists exists at all. ExePutS catches its own
compiler exception and returns 0 (Compiler/CMain.HC:31-37). So a file that fails
to compile does not raise - it quietly evaluates to zero. Fib(0) is also zero.
Without checking that the function is actually defined, an empty file would pass
the first case of this very task. So we look the name up in the task's hash
table first, the way the debugger does (Adam/ADbg.HC:223), and only then run
the cases.

Public domain.
*/

#help_index "Game/TaskRunner"

#include "/Game/Tasks"

#define TASK_HINT_LEVELS	3

class CTaskState
{
  U8	cur[TASK_ID_MAX];
  Bool	hinted;			//the full solution was opened for this task
  I64	checks,			//how many times the player asked to be checked
	passes;
} task_state;

CTaskDef *TaskFind(U8 *id)
{
  I64 i;
  for (i=0;i<TASK_CNT;i++)
    if (!StrCmp(task_defs[i].id,id))
      return &task_defs[i];
  return NULL;
}

Bool TaskFunExists(U8 *name)
{//Is this function actually defined right now?
  return HashFind(name,Fs->hash_table,HTT_FUN)!=NULL;
}

U8 *TaskCapture(U8 *path)
{/*Run a file with its printing diverted, and hand back what it printed.

Fs->put_doc is where a task's output lands, and pointing it somewhere else is
how the OS itself does this - Adam/Gr/SpriteEd.HC:587-591 swaps it out, prints,
and puts it back. display_doc is left alone, so the capture never reaches the
screen and the player's terminal stays as it was.

DocSave (Adam/DolDoc/DocFile.HC:56) serialises the document, and a DolDoc file
begins with its plain ASCII up to the first NUL - which for a document holding
nothing but printed text is exactly the text.

The caller frees the result. NULL means the run produced nothing at all.
*/
  CDoc *old_put=Fs->put_doc,*cap;
  U8 *txt;

  cap=DocNew;
  Fs->put_doc=cap;
  try {
    ExeFile(path);
  } catch {
    //A compile error has already printed itself into the capture doc, which is
    //where we want it - the host reads it back and glosses it for the player.
    Fs->catch_except=TRUE;
  }
  Fs->put_doc=old_put;

  txt=DocSave(cap);
  DocDel(cap);
  return txt;
}

public I64 TaskLoad(U8 *id)
{/*Make a task current and make sure the player has something to edit.

The template is not overwritten if the file is already there - a player who
walked away mid-task comes back to their own work, not to a blank sheet.
*/
  CTaskDef *t=TaskFind(id);
  if (!t) {
    "$$RED$$No such task: %s$$FG$$\n",id;
    return -1;
  }
  StrCpy(task_state.cur,t->id);
  task_state.hinted=FALSE;

  if (!FileFind(t->start_file))
    "$$RED$$Missing %s - the launcher should have placed it.$$FG$$\n",t->start_file;

  "$$LTBLUE$$Task$$FG$$ %s   edit $$GREEN$$%s$$FG$$\n",t->id,t->start_file;
  "  when you are ready:  $$LTBLUE$$TaskCheck(\"%s\");$$FG$$\n",t->id;
  EvSend("task_loaded",MStrPrint("id=%s",t->id));
  return 0;
}

public I64 TaskCheck(U8 *id=NULL)
{/*Compile the player's file and run the task's cases against it.

Returns the number of failing cases: 0 means the task is done, -1 means it
could not even be attempted.
*/
  CTaskDef *t;
  I64 i,got,bad=0;
  U8 *kv;

  if (!id || !*id) id=task_state.cur;
  t=TaskFind(id);
  if (!t) {
    "$$RED$$No such task: %s$$FG$$\n",id;
    return -1;
  }
  task_state.checks++;

  if (!FileFind(t->start_file)) {
    "$$RED$$%s does not exist.$$FG$$\n",t->start_file;
    return -1;
  }

  if (t->kind==TASKK_STDOUT) {
    U8 *out=TaskCapture(t->start_file);
    "$$LTBLUE$$Checking %s$$FG$$\n",t->id;
    if (!out) {
      //Nothing came back at all, which means this is not a terminal - see the
      //note by the command handlers. Say so rather than blaming the player.
      "$$RED$$Cannot capture output here.$$FG$$ Run it in your own shell.\n";
      EvLog("capture unavailable id=%s",t->id);
      return -1;
    }
    if (!StrFind(t->expect,out)) {
      "  $$RED$$bad$$FG$$  did not print \"%s\"\n",t->expect;
      bad=1;
    } else
      "  $$GREEN$$ok$$FG$$   printed \"%s\"\n",t->expect;
    if (out) Free(out);
  } else {
    //Compile whatever the player has written. Errors print themselves and the
    //host reads them off the LOG channel to gloss them for beginners.
    ExeFile(t->start_file);

    if (!TaskFunExists(t->fun)) {
      "$$RED$$%s is not defined.$$FG$$ Check the spelling and the capital letter.\n",t->fun;
      return -1;
    }

    "$$LTBLUE$$Checking %s$$FG$$\n",t->id;
    for (i=0;i<t->case_cnt;i++) {
      got=ExePrint("%s(%d);",t->fun,t->cases[i].arg);
      if (got==t->cases[i].want)
	"  $$GREEN$$ok$$FG$$   %s(%d) = %d\n",t->fun,t->cases[i].arg,got;
      else {
	"  $$RED$$bad$$FG$$  %s(%d) = %d, expected %d\n",
	      t->fun,t->cases[i].arg,got,t->cases[i].want;
	bad++;
      }
    }
  }

  //Report every check, not just the winning one. The host offers hint level 1
  //by itself after a first failed attempt, so it has to hear about failures;
  //if only successes were sent it would never know an attempt had been made.
  kv=MStrPrint("id=%s cases=%d failed=%d",t->id,t->case_cnt,bad);
  EvSend("task_checked",kv);
  Free(kv);

  if (bad) {
    "$$RED$$%d of %d cases failed.$$FG$$\n",bad,t->case_cnt;
    return bad;
  }

  task_state.passes++;
  "$$LTGREEN$$%s passed.$$FG$$\n",t->id;
  kv=MStrPrint("id=%s sig=%08X hinted=%d",t->id,EvSig(t->id),task_state.hinted!=0);
  EvSend("task_done",kv);
  Free(kv);
  return 0;
}

public U0 TaskHint(U8 *id=NULL,I64 lvl=1)
{/*Ask the host for a hint.

The text lives on the host, in data/tasks/<id>.json, so it can be localised and
edited without touching the image. Level 3 is the full solution; taking it costs
nothing except the one campaign-wide achievement for never looking, so it is
offered plainly rather than hidden behind a warning.
*/
  U8 *kv;
  if (!id || !*id) id=task_state.cur;
  if (lvl<1) lvl=1;
  if (lvl>TASK_HINT_LEVELS) lvl=TASK_HINT_LEVELS;
  if (lvl==TASK_HINT_LEVELS)
    task_state.hinted=TRUE;
  kv=MStrPrint("id=%s level=%d",id,lvl);
  EvSend("hint_asked",kv);
  Free(kv);
  "$$LTBLUE$$Hint %d for %s requested.$$FG$$\n",lvl,id;
}

/* Command handlers, wired into the bridge so the host can drive the campaign.

A NOTE ON WHERE THESE RUN, because it constrains what they can do.

These execute in the bridge pump, which is a task spawned by EvBridgeInit - not
a terminal. func_tests work there: ExeFile compiles the player's file and
ExePrint calls it, and neither needs to print anywhere in particular.

stdout checks do not. Capturing output means pointing Fs->put_doc at a document
of our own, and in a spawned task that has no effect - not even on this layer's
own printing. DocPut (Adam/DolDoc/DocDblBuf.HC:2) does read task->put_doc, so
the field is right; something downstream of it is not ours to control. Measured,
not guessed: in a spawned task the capture document comes back empty even when
the print is our own, while the identical code in a terminal returns the text.

Routing the command into another task with XTalk was tried and is worse: at boot
the layer starts from MakeHome, so the task that owns the bridge is the start-up
task rather than any terminal the player is looking at.

So a stdout task is checked where the player types it - TaskCheck("id") in their
own shell, which is how they would reach it anyway. Driving one from the host
needs a worker task that owns a document, and that belongs with the launcher
work rather than here. TaskCheck reports the refusal rather than failing the
task, so the host can tell the two apart.
*/

public Bool TaskReset(U8 *id=NULL)
{/*Put a task's file back the way it started.

The one thing a person needs to be able to do in a machine like this before
they will experiment in it at all. TempleOS has no undo across a save and no
bin to fish a file back out of, so without this the fourth task can be ruined
by one wrong keystroke and there is nothing to be done about it - which is a
very good reason never to touch anything.

The starting file ships with the layer at /Game/Tasks/<id>/Start.HC and is
never written to, so it is the copy to restore from. Read and write rather than
Copy, so that a missing source is a refusal rather than a half-written file.

Returns FALSE and says why if it cannot.
*/
  CTaskDef *t=TaskFind(id);
  U8 src[TASK_PATH_MAX+32],*buf;
  I64 size;

  if (!t) {
    "$$RED$$No such task: %s$$FG$$\n",id;
    return FALSE;
  }
  StrPrint(src,"/Game/Tasks/%s/Start.HC",t->id);
  if (!FileFind(src)) {
    "$$RED$$No starting file for %s$$FG$$\n",t->id;
    return FALSE;
  }
  buf=FileRead(src,&size);
  if (!buf) {
    "$$RED$$Could not read %s$$FG$$\n",src;
    return FALSE;
  }
  FileWrite(t->start_file,buf,size);
  Free(buf);
  "$$GREEN$$%s is back as it started.$$FG$$\n",t->start_file;
  EvSend("task_reset",MStrPrint("id=%s",t->id));
  return TRUE;
}

public I64 TaskResetAll()
{/*Every task's file back to its starting point.

Only the files the campaign owns. Anything else the player has written in
/Home is theirs and is left alone - a "reset" that quietly deleted somebody's
own experiments would be a worse thing than the problem it solves.
*/
  I64 i,n=0;
  for (i=0;i<TASK_CNT;i++)
    if (TaskReset(task_defs[i].id))
      n++;
  "$$LTBLUE$$%d of %d task file(s) restored.$$FG$$\n",n,TASK_CNT;
  return n;
}

public U0 TaskType(U8 *text)
{/*Type text into whatever window the player is looking at.

The launcher writes commands for people who do not yet know what to type, and
the obvious way to do that - synthesise keystrokes on the frame connection -
does not survive contact with this machine. Scancodes go missing: shift arrives
a character late and Type("/Home/Hello.HC"); lands as Type("/Home/Hello.HC'0:
with the quote unshifted and the semicolon shifted. That is the same lossy
interrupt delivery that was making the timer fire sixty-five times a second
instead of a thousand, and it cannot be tuned around honestly.

XTalk is the OS's own answer and has no keyboard in it at all: it hands the
text to another task's input queue (Kernel/Job.HC:445-452), which is how User()
passes a command to the terminal it just spawned. No modifier state to lose.

sys_focus_task rather than a remembered terminal, because the player's window
is wherever they last clicked - and text should arrive where they are looking,
which is the same rule a keyboard follows.
*/
  if (sys_focus_task && text && *text)
    XTalk(sys_focus_task,"%s",text);
}

public U0 TaskEnter()
{//The newline that submits what was typed.

//A command of its own because a bridge line ends at a newline, so a newline
//cannot be sent as the text of one.
  if (sys_focus_task)
    XTalk(sys_focus_task,"\n");
}

public U0 TaskReboot()
{/*Restart the machine, because the player asked.

Reboot() is a hardware reset (Kernel/KMain.HC:122-133): interrupts off, the
other cores halted, the warm-boot flag cleared, and then the keyboard
controller's reset line pulled. Nothing is saved and nothing is asked, which is
why the launcher puts a confirmation in front of it rather than a button.

It comes back at the boot loader waiting for a keypress. The launcher answers
that over the frame connection, which survives the guest restarting because it
belongs to the emulator and not to the machine inside it.
*/
  "$$RED$$Restarting.$$FG$$\n";
  Sleep(200);
  Reboot;
}

U0 TaskOnLoad(U8 *id)   { TaskLoad(id); }
U0 TaskOnReboot()       { TaskReboot; }
U0 TaskOnType(U8 *text) { TaskType(text); }
U0 TaskOnEnter()        { TaskEnter; }
U0 TaskOnReset(U8 *id)  { TaskReset(id); }
U0 TaskOnResetAll()     { TaskResetAll; }
U0 TaskOnCheck(U8 *id)  { TaskCheck(id); }
U0 TaskOnHint(U8 *id,I64 level) { TaskHint(id,level); }

public U0 TaskRunnerInit()
{
  MemSet(&task_state,0,sizeof(CTaskState));
  TasksInit;
  eb_on_load_task  = &TaskOnLoad;
  eb_on_reset_task = &TaskOnReset;
  eb_on_type       = &TaskOnType;
  eb_on_enter      = &TaskOnEnter;
  eb_on_reboot     = &TaskOnReboot;
  eb_on_reset_home = &TaskOnResetAll;
  eb_on_check_task = &TaskOnCheck;
  eb_on_hint       = &TaskOnHint;
  "TaskRunner: %d task(s).\n",TASK_CNT;
}

public U0 TaskRep()
{//Where the player is. Useful when debugging, and honest about hints.
  "$$LTBLUE$$TaskRunner$$FG$$\n";
  "  current : %s\n",task_state.cur;
  "  checks  : %d\n",task_state.checks;
  "  passes  : %d\n",task_state.passes;
  "  hinted  : %d\n",task_state.hinted!=0;
}
