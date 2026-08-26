/* Task hc_switch_range - case 1...5

Classify(n) sorts a number into a band:

    1 to 5    ->  1
    6 to 10   ->  2
    11 to 20  ->  3
    anything else -> 0

C makes you write one label per value. HolyC does not: a single case can span a
range. Look at /Demo/SubSwitch.HC, and at how the OS itself uses it.

    TaskCheck("hc_switch_range");

For a nudge:  TaskHint("hc_switch_range",1);
*/

I64 Classify(I64 n)
{
  //Your code goes here. Returning 0 is right for the out-of-range case only.
  return 0;
}
