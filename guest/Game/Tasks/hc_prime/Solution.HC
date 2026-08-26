/* Task hc_prime - reference solution.

Stops at the square root. If n = a * b and both a and b were larger than the
square root of n, their product would exceed n - so any composite number has a
divisor at or below it, and finding none means there is none at all.

i * i <= n rather than a square root call: it stays in integers, so there is no
rounding to argue about at the boundary.
*/

Bool IsPrime(I64 n)
{
  I64 i;

  if (n < 2)
    return FALSE;

  for (i = 2; i * i <= n; i++)
    if (!(n % i))
      return FALSE;

  return TRUE;
}
