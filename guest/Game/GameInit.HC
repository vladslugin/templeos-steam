/* /Game/GameInit.HC - entry point for the game layer inside the OS.

No kernel patch needed to get here. Stock StartOS.HC, the script the Adam task
runs at boot, ends with:

    #include "~/MakeHome"

so the OS already hands control to a user file on the way up. Putting

    #include "/Game/GameInit"

in /Home/MakeHome.HC is the entire hook. Nothing under /Kernel or /Adam is
touched to start the layer.

If the host is not there, this prints one line and gets out of the way.

Public domain.
*/

#help_index "Game"

#define GAME_LAYER_VER	"0.2.0"

#include "/Game/Comm"
#include "/Game/Pointer"
#include "/Game/EventBridge"
//After EventBridge, which declares the handler pointer it fills in. The
//compiler reads these in order and will not take a symbol it has not seen.
#include "/Game/Clock"
#include "/Game/MsBridge"
#include "/Game/Fps"
#include "/Game/TaskRunner"
//How much of the machine meets the player halfway. At level 0 this include is
//skipped outright, so the friendly names are not merely inert - they are not
//defined, and the shell answers `ls` the way stock TempleOS answers it.
#include "/Game/Level"
#ifdef GAME_NOVICE
#include "/Game/Novice"
#endif
//#include "/Game/Tutor"

U0 GameInit()
{
  "$$LTBLUE$$Temple game layer$$FG$$ %s  (public domain)\n",GAME_LAYER_VER;

  ClockInit;
  PointerInit;
  EvBridgeInit;
  MsBridgeInit;
  FpsInit;
  TaskRunnerInit;
#ifdef GAME_NOVICE
  NoviceInit;
#endif

  if (CommIsEnabled(1))
    "  EventBridge: COM1 up.  $$LK,\"EvBridgeRep\",A=\"MN:EvBridgeRep\"$$\n";
  else
    "  EventBridge: off - standalone sandbox.\n";
}

GameInit;
