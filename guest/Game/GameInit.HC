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

#define GAME_LAYER_VER	"0.1.0"

#include "/Game/Comm"
#include "/Game/Pointer"
#include "/Game/EventBridge"
#include "/Game/TaskRunner"
//#include "/Game/Tutor"

U0 GameInit()
{
  "$$LTBLUE$$Temple game layer$$FG$$ %s  (public domain)\n",GAME_LAYER_VER;

  PointerInit;
  EvBridgeInit;
  TaskRunnerInit;

  if (CommIsEnabled(1))
    "  EventBridge: COM1 up.  $$LK,\"EvBridgeRep\",A=\"MN:EvBridgeRep\"$$\n";
  else
    "  EventBridge: off - standalone sandbox.\n";
}

GameInit;
