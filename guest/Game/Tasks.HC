// /Game/Tasks.HC - generated, do not edit.
//
// Source:     data/tasks (the json files)
// Regenerate: python tools/gen_tasks.py
//
// The JSON is what the host and CI read. This is the same facts in a form
// the guest can compile, because TempleOS has no JSON parser and does not
// need one to hold a handful of integers.

#help_index "Game/Tasks"

#define TASK_ID_MAX	32
#define TASK_NAME_MAX	32
#define TASK_PATH_MAX	64
#define TASK_MAX_CASES	8
#define TASK_CNT	3

class CTaskCase
{//Named arg/want rather than in/out. `in` and `out` as member names wedge
 //the compiler outright - no diagnostic, the terminal simply stops running
 //what you type. They are x86 instruction mnemonics, and the OS sources
 //never name a member `in` or `out` either.
  I64	arg,
	want;
};

class CTaskDef
{
  U8	id[TASK_ID_MAX],
	fun[TASK_NAME_MAX],
	start_file[TASK_PATH_MAX];
  I64	case_cnt;
  CTaskCase cases[TASK_MAX_CASES];
};

CTaskDef task_defs[TASK_CNT];

U0 TasksInit()
{//Filled in by code rather than by an initialiser list: HolyC has no
 //designated initialisers, and a table written out longhand is easier to
 //diff when a task changes.
  CTaskDef *t;

  //hc_fib - chapter 2, Fibonacci
  t=&task_defs[0];
  MemSet(t,0,sizeof(CTaskDef));
  StrCpy(t->id,"hc_fib");
  StrCpy(t->fun,"Fib");
  StrCpy(t->start_file,"/Home/Fib.HC");
  t->case_cnt=4;
  t->cases[0].arg=0;  t->cases[0].want=0;
  t->cases[1].arg=1;  t->cases[1].want=1;
  t->cases[2].arg=10;  t->cases[2].want=55;
  t->cases[3].arg=40;  t->cases[3].want=102334155;

  //hc_prime - chapter 2, Prime
  t=&task_defs[1];
  MemSet(t,0,sizeof(CTaskDef));
  StrCpy(t->id,"hc_prime");
  StrCpy(t->fun,"IsPrime");
  StrCpy(t->start_file,"/Home/Prime.HC");
  t->case_cnt=5;
  t->cases[0].arg=1;  t->cases[0].want=0;
  t->cases[1].arg=2;  t->cases[1].want=1;
  t->cases[2].arg=17;  t->cases[2].want=1;
  t->cases[3].arg=21;  t->cases[3].want=0;
  t->cases[4].arg=7919;  t->cases[4].want=1;

  //hc_switch_range - chapter 2, case 1...5
  t=&task_defs[2];
  MemSet(t,0,sizeof(CTaskDef));
  StrCpy(t->id,"hc_switch_range");
  StrCpy(t->fun,"Classify");
  StrCpy(t->start_file,"/Home/Classify.HC");
  t->case_cnt=6;
  t->cases[0].arg=3;  t->cases[0].want=1;
  t->cases[1].arg=5;  t->cases[1].want=1;
  t->cases[2].arg=6;  t->cases[2].want=2;
  t->cases[3].arg=10;  t->cases[3].want=2;
  t->cases[4].arg=15;  t->cases[4].want=3;
  t->cases[5].arg=50;  t->cases[5].want=0;
}
