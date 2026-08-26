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

/* Command handlers, wired into the bridge so the host can drive the campaign. */

U0 TaskOnLoad(U8 *id)   { TaskLoad(id); }
U0 TaskOnCheck(U8 *id)  { TaskCheck(id); }
U0 TaskOnHint(U8 *id,I64 level) { TaskHint(id,level); }

public U0 TaskRunnerInit()
{
  MemSet(&task_state,0,sizeof(CTaskState));
  TasksInit;
  eb_on_load_task  = &TaskOnLoad;
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
