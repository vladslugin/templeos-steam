/* /Game/Novice.HC - meeting a newcomer halfway, by as much as they asked for.

TempleOS is not unfriendly. It is unexplained. Three things stop a newcomer in
the first minute and none of them is difficulty:

  - The prompt is the compiler. `ls` is not an unknown command, it is an
    undefined identifier, and the machine says so in those words.
  - Nothing on the screen says what to type instead.
  - When something does not compile, the message names the token the parser was
    holding, which is often several characters after the one that is wrong.

The third one is worth dwelling on, because it is the one that makes people
give up. A file whose first four characters went missing reports "Undefined
identifier" and points at the filename - true, unhelpful, and indistinguishable
from a real error in the file. The message is never wrong. It is answering a
question about the parser, and the reader is asking a question about their code.

None of this is fixed by making the OS smaller. It is fixed by adding the names
it does not have, a card that lists them, and a second opinion on the errors -
and by being able to turn all of it off, because someone who came here for
TempleOS 5.03 should be able to have TempleOS 5.03. That is what /Game/Level.HC
is for, and why it is a #define: at level 0 this file is not compiled at all,
so `ls` really is undefined again.

WHAT IS NOT TOUCHED

Nothing under /Kernel or /Adam. The names below are new functions that call the
OS's own; the card is a document; and the error watcher reads a log the OS
already keeps for its own reasons - LexExcept copies every compiler error to
the Adam task with AdamErr (Compiler/CExcept.HC:88), which is how one task's
mistake reaches the machine's log at all. We read that log. The player's own
terminal is never written to and never diverted, so the original message is
always there, exactly as Terry wrote it.

Public domain.
*/

#help_index "Game/Novice"

#define NOV_STOCK	0
#define NOV_LEARNER	1
#define NOV_GUIDED	2

//One bit per name, so a name explains itself once and then gets out of the way.
I64	nov_taught = 0;

U0 NovSay(I64 bit, U8 *friendly, U8 *real)
{/*Say what this name stands for, the first time it is used.

Only at the guided level, and only once each. The point is that the player
leaves knowing the real name - a crutch that never mentions the leg is not
teaching anyone anything.
*/
  if (GAME_LEVEL >= NOV_GUIDED && !LBts(&nov_taught, bit))
    "$$LTGREEN$$%s$$FG$$ here is $$LTGREEN$$%s$$FG$$. Both work.\n", friendly, real;
}

/* The names people try first.

Each one hands straight over to the OS function it stands for, keeping that
function's own defaults, so `ls;` and `Dir;` are the same call and there is
nothing to unlearn later.
*/

public I64 ls(U8 *files_find_mask="*", Bool full=FALSE)
{//What is in this directory.
  NovSay(0, "ls", "Dir");
  return Dir(files_find_mask, full);
}

public I64 dir(U8 *files_find_mask="*", Bool full=FALSE)
{//The other name people try first.
  NovSay(0, "dir", "Dir");
  return Dir(files_find_mask, full);
}

public Bool cd(U8 *dirname=NULL, Bool make_dirs=FALSE)
{//Go somewhere. Needs the quotes: cd("/Home");
  NovSay(1, "cd", "Cd");
  return Cd(dirname, make_dirs);
}

public U0 pwd()
{//Where am I.
  NovSay(2, "pwd", "DirCur");
  "%s\n", DirCur;
}

public Bool cat(U8 *filename, I64 trailing_new_lines=1)
{//Read a file without opening the editor.
  NovSay(3, "cat", "Type");
  return Type(filename, trailing_new_lines);
}

public Bool edit(U8 *link_st, I64 edf_dof_flags=0)
{//Write one. Esc saves and leaves, Shift-Esc leaves without saving.
  NovSay(4, "edit", "Ed");
  return Ed(link_st, edf_dof_flags);
}

public I64 run(U8 *name, I64 ccf_flags=0)
{//Compile a file and run it.
  NovSay(5, "run", "ExeFile");
  return ExeFile(name, ccf_flags);
}

public U0 clear()
{//Empty this window.
  NovSay(6, "clear", "DocClear");
  DocClear;
}

public I64 rm(U8 *files_find_mask, Bool make_mask=FALSE, Bool del_dir=FALSE)
{//Delete. There is no undo, and no bin to fish it back out of.
  NovSay(7, "rm", "Del");
  return Del(files_find_mask, make_mask, del_dir);
}

public Bool cp(U8 *src_files_find_mask, U8 *dst_files_find_mask=".")
{
  NovSay(8, "cp", "Copy");
  return Copy(src_files_find_mask, dst_files_find_mask);
}

public Bool mv(U8 *f1, U8 *f2)
{
  NovSay(9, "mv", "Move");
  return Move(f1, f2);
}

public U0 help(U8 *topic=NULL)
{/*The card, or the OS's own manual page for one name.

Written to be read once and remembered, so it is short and every line is
something the player will need in the first ten minutes. The real names are in
the right-hand column rather than hidden, for the reason in NovSay.

Keys are quoted from analysis/04_keymap.md, where each was traced to the
handler that implements it rather than to documentation about it. Ctrl-Alt-C is
described as breaking execution and not as killing a task, because that is what
it does (Kernel/Sched.HC:236-262 substitutes the focused task's rip with
&Break, and KExcept.HC:117-129 throws) - a task that is wedged with interrupts
off is not reachable by it.
*/
  if (topic) {
    Man(topic);
    return;
  }

  "\n$$LTBLUE$$This prompt is the compiler.$$FG$$ Whatever you type is HolyC and\n";
  "ends in a semicolon. $$LTGREEN$$2+2;$$FG$$ answers 4. $$LTGREEN$$Dir;$$FG$$ lists the directory.\n";
  "There is no separate shell language to learn - this is the language.\n\n";

  "$$LTBLUE$$Getting around$$FG$$                              $$LTGRAY$$the OS calls it$$FG$$\n";
  "  $$LTGREEN$$ls;$$FG$$                    what is in here          $$LTGRAY$$Dir$$FG$$\n";
  "  $$LTGREEN$$cd(\"/Home\");$$FG$$           go somewhere             $$LTGRAY$$Cd$$FG$$\n";
  "  $$LTGREEN$$pwd;$$FG$$                   where am I               $$LTGRAY$$DirCur$$FG$$\n";
  "  $$LTGREEN$$cat(\"Fib.HC\");$$FG$$         read a file              $$LTGRAY$$Type$$FG$$\n";
  "  $$LTGREEN$$edit(\"Fib.HC\");$$FG$$        write one                $$LTGRAY$$Ed$$FG$$\n";
  "  $$LTGREEN$$run(\"Fib.HC\");$$FG$$         compile it and run it    $$LTGRAY$$ExeFile$$FG$$\n";
  "  $$LTGREEN$$clear;$$FG$$                 empty this window        $$LTGRAY$$DocClear$$FG$$\n";
  "  $$LTGREEN$$help(\"Dir\");$$FG$$           the manual on one name   $$LTGRAY$$Man$$FG$$\n\n";

  "$$LTBLUE$$Keys$$FG$$\n";
  "  $$LTGREEN$$Esc$$FG$$              in the editor: save and leave\n";
  "  $$LTGREEN$$Shift-Esc$$FG$$        leave without saving\n";
  "  $$LTGREEN$$Ctrl-Alt-C$$FG$$       break whatever is running\n";
  "  $$LTGREEN$$Ctrl-Alt-T$$FG$$       another terminal window\n";
  "  $$LTGREEN$$Ctrl-Alt-N$$FG$$       move to the next window\n\n";

  "Type $$LTGREEN$$help;$$FG$$ again whenever you want this back.\n\n";
}

/* Reading the error off the screen it is already on.

The obvious source is the machine's own log: LexExcept copies every compiler
error to the Adam task with AdamErr (Compiler/CExcept.HC:88), which would give
one document to watch instead of one per terminal. It does not work here, and
the reason is worth recording so nobody tries it twice. AdamErr forwards to
Adam only `else if (!IsSingleUser)` (Kernel/Job.HC) - and a machine with one
person at it is single user, so on the machine this game runs on that branch
never fires and the log stays empty.

So we read the document the message is actually in: the focused task's, which
is the terminal the player just typed into. PrintErr has already put it there
(Kernel/StrPrint.HC:906-912) prefixed with ST_ERR_ST, which is why "ERROR:" is
what we look for (KernelA.HH:3459).

Reading another task's document needs its lock. DocLock spins with Yield until
it has it (Adam/DolDoc/DocNew.HC:3-14), which in a cooperative OS is a wait and
not a spin, and without it a document being rewritten underneath the walk is a
freed pointer followed by a machine that needs restarting.

What goes to the host is the message verbatim. The catalogue that explains it -
149 messages, with the likely cause and what to do - lives on the host in
data/errors/compiler_messages.json and stays there: it is 135KB of JSON, the
guest has no JSON parser and does not need one, and the explanation belongs
beside the original in the launcher rather than on top of it here.
*/

#define NOV_ERR_MARK	"ERROR:"
#define NOV_ERR_MAX	200		//characters of message worth carrying
#define NOV_ERR_MIN	8		//shorter than this is a scrap, not a message
#define NOV_WALK_MAX	64		//document entries to look back through

Bool	nov_watch_on = FALSE;
CDoc	*nov_doc = NULL;	//the document we were looking at last time
I64	nov_updates = 0;	//and its updates_cnt then
U8	nov_last_err[NOV_ERR_MAX];
//The entries messages have already been reported from. Comparing entries
//rather than text is what makes "is this a new error" an exact question: the
//same mistake typed twice is two prints and two entries, while a screen that
//has not changed is the same entry however many times it is looked at - and it
//is looked at often, because a blinking cursor moves updates_cnt on its own.
//
//A ring rather than one, because one mistake can print more than one message:
//`I64 x = ;` gives "Missing expression" and then "Compiler Parse Error", the
//second being the parser giving up rather than a second thing being wrong. The
//first is the one worth explaining, so the first is what gets sent and the
//rest of that burst are marked seen without being sent.
#define NOV_SEEN_MAX	16
CDocEntryBase *nov_seen[NOV_SEEN_MAX];
I64	nov_seen_n = 0;

Bool NovSeen(CDocEntryBase *e)
{//Has a message from this entry already gone to the host?
  I64 i;
  for (i = 0; i < NOV_SEEN_MAX; i++)
    if (nov_seen[i] == e)
      return TRUE;
  return FALSE;
}

U0 NovMarkSeen(CDocEntryBase *e)
{
  if (!NovSeen(e)) {
    nov_seen[nov_seen_n] = e;
    nov_seen_n = (nov_seen_n + 1) % NOV_SEEN_MAX;
  }
}

I64 NovCollect(CDoc *doc, U8 *buf, CDocEntryBase **_err_entry)
{/*Gather the end of a document, and find the message worth explaining in it.

Returns where in buf that message's marker starts, or -1 when there is nothing
new. The entry it came from goes back through _err_entry, because that - and
not the text - is what makes "already reported" an exact question.

DolDoc holds a line as several entries: a colour command, a run of text,
another colour command (KernelA.HH:1169-1190; a doubly linked list with the
last of them at head.last). So the text has to be gathered rather than read,
and walking backwards then copying forwards is the short way to the end of a
list when only the end is known.
*/
  CDocEntryBase *e, *stack[NOV_WALK_MAX];
  I64 n = 0, i, len = 0, l, at = -1;
  U8 *hit;

  buf[0] = 0;
  *_err_entry = NULL;
  e = doc->head.last;
  while (e && e != &doc->head && n < NOV_WALK_MAX) {
    stack[n++] = e;
    e = e->last;
  }

  for (i = n - 1; i >= 0; i--) {
    //Only the hard one. A soft break is the window being narrow, not the text
    //ending - cutting there took the position and the offending source off the
    //end of every message and left just "Undefined identifier", which is the
    //half that was already useless.
    if (stack[i]->type_u8 == DOCT_NEW_LINE) {
      if (len < NOV_ERR_MAX - 2) {
	buf[len++] = '\n';
	buf[len] = 0;
      }
    } else if (stack[i]->type_u8 == DOCT_TEXT && stack[i]->tag) {
      hit = StrFind(NOV_ERR_MARK, stack[i]->tag);
      if (hit) {
	//The earliest unsent marker wins and every other one in the window is
	//written off unsent. One mistake can print more than one message -
	//`I64 x = ;` gives "Missing expression" and then "Compiler Parse
	//Error", the second being the parser giving up rather than a second
	//thing being wrong - and the first is the one worth explaining.
	if (at < 0 && !NovSeen(stack[i])) {
	  at = len + hit - stack[i]->tag;
	  *_err_entry = stack[i];
	} else
	  NovMarkSeen(stack[i]);
      }
      l = StrLen(stack[i]->tag);
      if (len + l < NOV_ERR_MAX - 1) {
	MemCpy(buf + len, stack[i]->tag, l);
	len += l;
	buf[len] = 0;
      } else
	i = 0;		//no room for the rest, and no HolyC `continue` to skip it
    }
  }
  return at;
}

U0 NovWatchTask(I64)
{/*Notice a new error in front of the player and pass it to the host.

updates_cnt does not move while the document does not, so a still screen costs
one comparison every quarter second. What does move it, on a screen nobody is
touching, is the cursor blinking - which is why the guard against repeating
oneself is the entry the message was printed into rather than the text of it.
*/
  CDoc *doc;
  CTask *t;
  CDocEntryBase *err_entry;
  U8 buf[NOV_ERR_MAX], *mark, *at;
  I64 found;
  Bool unlock;

  while (nov_watch_on) {
    Sleep(250);
    t = sys_focus_task;
    if (t) {
      doc = t->put_doc;
      if (doc && (doc != nov_doc || doc->updates_cnt != nov_updates)) {
	nov_doc = doc;
	nov_updates = doc->updates_cnt;

	unlock = DocLock(doc);
	found = NovCollect(doc, buf, &err_entry);
	if (unlock)
	  DocUnlock(doc);

	if (found >= 0) {
	  mark = buf + found + StrLen(NOV_ERR_MARK);
	  while (*mark == ' ')
	    mark++;
	  //One line, which is the message. What follows it is the compiler's
	  //backtrace: addresses inside the compiler, a true and complete
	  //answer to a question nobody asked.
	  //
	  //A message with no line break after it has not finished being
	  //written. Sending it anyway is how half of them arrived truncated at
	  //wherever the poll happened to land, and since the entry is then
	  //written off as reported, the finished version 250ms later is never
	  //sent at all. So: wait for the newline.
	  at = StrFind("\n", mark);
	  if (at) {
	    *at = 0;
	    if (StrLen(mark) >= NOV_ERR_MIN) {
	      NovMarkSeen(err_entry);
	      StrCpy(nov_last_err, mark);
	      EvLog("!err %s", mark);
	    }
	  }
	}
      }
    }
  }
}

public U0 NoviceWatch(Bool on=TRUE)
{//Start or stop reporting compiler errors to the host.
  if (on && !nov_watch_on) {
    nov_watch_on = TRUE;
    nov_last_err[0] = 0;
    MemSet(nov_seen, 0, sizeof(nov_seen));
    nov_seen_n = 0;
    nov_doc = NULL;
    Spawn(&NovWatchTask, NULL, "Novice watch");
  } else if (!on)
    nov_watch_on = FALSE;
}

U0 NovOnLevel(I64 n)
{//The host asking what is installed, or turning the watcher off.
  NoviceWatch(n > NOV_STOCK);
}

U0 NoviceInit()
{
  eb_on_level = &NovOnLevel;
  NoviceWatch;
  "  Type $$LTGREEN$$help;$$FG$$ for the short version of this machine.\n";
}
