/* Task hc_fib - reference solution.

Iterative on purpose. The obvious recursive version,

    if (n < 2) return n;
    return Fib(n - 1) + Fib(n - 2);

is correct and recomputes the same values over and over: Fib(40) costs
331,160,281 calls, which under emulation looks exactly like a hang. Same answer,
same arithmetic, different amount of work - and the check asks for 40 precisely
so the difference shows up rather than being explained.
*/

I64 Fib(I64 n)
{
  I64 a=0,b=1,t,i;

  if (n<2)
    return n;

  for (i=2;i<=n;i++) {
    t=a+b;
    a=b;
    b=t;
  }
  return b;
}
