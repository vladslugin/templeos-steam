/* /Game/Level.HC - how much of the machine meets the player halfway.

Rewritten on the disk before the machine starts, by tools/set_level.py, which
the launcher calls. It is a #define rather than a runtime setting on purpose:
at level 0 the friendly names must not merely be inert, they must not be
defined at all, or the shell answers `ls` and the claim to be stock TempleOS
5.03 is not true. A compile-time switch is the only way to mean it.

Changing it therefore takes a restart, which is the right shape anyway - this
is a mode the machine is in, not a button.

  0  stock     Nothing is added. The OS as Terry left it.
  1  learner   Familiar names, a card that lists them, errors explained on the
               host beside the original.
  2  guided    And each alias says what it stands for the first time it is
               used, so the player leaves knowing the real name.

See /Game/Novice.HC for what each of those actually installs.

Public domain.
*/

#define GAME_LEVEL	1

//Defined only above level 0. The include in GameInit turns on #ifdef rather
//than on a comparison: #ifdef asks the compiler whether it has heard of a
//symbol, which is a question its lexer answers directly (Compiler/Lex.HC:887),
//and there is then nothing to be wrong about.
#define GAME_NOVICE
