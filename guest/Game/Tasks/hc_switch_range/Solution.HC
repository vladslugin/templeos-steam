/* Task hc_switch_range - reference solution.

One label per band. `case 1...5:` is a real HolyC range, not a typo for two
dots, and it is how the OS reads scan codes and digits - Adam/DolDoc/DocPutKey.HC
uses `case SC_F1...SC_F10:` and `case '0'...'9':`.

No break statements: each arm returns, which leaves the switch and the function
together.
*/

I64 Classify(I64 n)
{
  switch (n) {
    case 1...5:
      return 1;
    case 6...10:
      return 2;
    case 11...20:
      return 3;
    default:
      return 0;
  }
}
