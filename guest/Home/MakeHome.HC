Cd(__DIR__);;

//If these are not present in /Home, it uses the version in the root dir.  You
//can make your own, modified, version of these files in your /Home directory.
#include "~/HomeLocalize"
#include "/Adam/Opt/Boot/MakeBoot"
#include "/Adam/Opt/Utils/MakeUtils"
#include "~/HomeWrappers"
MapFileLoad("::/Kernel/Kernel");
MapFileLoad("::/Compiler/Compiler");
#include "~/HomeKeyPlugIns"
#include "~/HomeSys"
//---- Temple game layer -------------------------------------------------
//StartOS.HC ends with #include "~/MakeHome", so the OS hands control here on
//the way up. This one line is the entire hook: nothing under /Kernel or /Adam
//is touched. If /Game is absent, or no host is listening on COM1, the layer
//stays quiet and the OS is exactly stock.
if (FileFind("/Game/GameInit.HC"))
  #include "/Game/GameInit"
Cd("..");;
