/* /Game/Comm.HC - serial port driver for the host bridge.

Based on /Doc/Comm.HC, which ships with stock TempleOS 5.03 but is never
compiled at boot. Terry left instructions at the top of that file:

    "RS232 serial ports no longer exist.
     Be sure to Adam Include this by placing
     it in your start-up scripts."

So that is what we do. The rest of the OS has no serial support at all -
Kernel/SerialDev is PS/2 keyboard and mouse, not RS232, and 0x3F8 appears
nowhere in the kernel.

Two changes from the original, both forced:

 1) Dropped the Sleep(10) from CommPutChar. Terry's own comment on that line
    read "!!! Remove this line!!! Linux echo_socket is too slow." At 10ms per
    byte a 240 byte protocol line takes 2.4 seconds, which makes a one second
    heartbeat impossible. We poll the THRE bit in LSR instead.

 2) Added receive. The original fills RX_fifo from the interrupt handler but
    never exposes a way to read it, so host->guest traffic was not possible.

Everything else - init, IRQ wiring, FIFOs, port map - is his.

Public domain, same as the original.

Not yet run on hardware or in a VM.
*/

#help_index "Comm"

#define UART_THR	0	//Transmit Holding Register (W)
#define UART_RDR	0	//Receive Data Register (R)
#define UART_BRDL	0	//Baud Rate Divisor, low
#define UART_IER	1	//Interrupt Enable Register
#define UART_BRDH	1	//Baud Rate Divisor, high
#define UART_IIR	2	//Interrupt Identification Register
#define UART_LCR	3	//Line Control Register
#define UART_MCR	4	//Modem Control Register
#define UART_LSR	5	//Line Status Register
#define UART_MSR	6	//Modem Status Register

#define UART_LSR_THRE	0x20	//Transmit Holding Register Empty
#define UART_LSR_DR	0x01	//Data Ready

#define COMf_ENABLED	0

class CComm
{
  I64	base,
	flags;
  CFifoU8 *RX_fifo;
  CFifoU8 *TX_fifo;
} comm_ports[5];

U0 CommHndlr(I64 port)
{
  CComm *c=&comm_ports[port];
  I64 b=0,stat;
  if (Bt(&c->flags,COMf_ENABLED)) {
    stat=InU8(c->base+UART_IIR);
    if (stat & 4)	//RX
      FifoU8Ins(c->RX_fifo,InU8(c->base+UART_RDR));
    if (stat & 2) {	//TX
      if (FifoU8Rem(c->TX_fifo,&b))
	OutU8(c->base+UART_THR,b);
      else
	OutU8(c->base+UART_IER,1); //RX but no THR empty
    }
  }
}

interrupt U0 IRQComm3()
{
  CommHndlr(2);
  CommHndlr(4);
  OutU8(0x20,0x20);
}

interrupt U0 IRQComm4()
{
  CommHndlr(1);
  CommHndlr(3);
  OutU8(0x20,0x20);
}

U0 CommInit()
{
  MemSet(&comm_ports,0,sizeof(comm_ports));
  comm_ports[1].base=0x3F8;	//COM1, the one the bridge uses
  comm_ports[2].base=0x2F8;
  comm_ports[3].base=0x3E8;
  comm_ports[4].base=0x2E8;
  IntEntrySet(0x23,&IRQComm3);
  IntEntrySet(0x24,&IRQComm4);
}
CommInit;

public CComm *CommInit8n1(I64 port,I64 baud)
{//8 data bits, no parity, 1 stop bit.
  CComm *c=&comm_ports[port];

  PUSHFD
  CLI
  if (LBts(&c->flags,COMf_ENABLED)) {
    FifoU8Del(c->RX_fifo);
    FifoU8Del(c->TX_fifo);
  }
  c->RX_fifo=FifoU8New(256);
  c->TX_fifo=FifoU8New(256);
  OutU8(c->base+UART_LCR,0);	//Set for IER
  OutU8(c->base+UART_IER,0);	//Disable all IRQ
  OutU8(c->base+UART_LCR,0x80);	//Enable baud rate control
  OutU8(c->base+UART_BRDL,(0x180/(baud/300)) & 0xFF);	//LSB
  OutU8(c->base+UART_BRDH,(0x180/(baud/300)) / 256);	//MSB
  OutU8(c->base+UART_LCR,3);	//8-none-1

  InU8(c->base+UART_RDR);	//read garbage
  InU8(c->base+UART_LSR);

  OutU8(c->base+UART_MCR,4);
  OutU8(c->base+UART_IER,0);	//Disable all IRQ
  OutU8(c->base+UART_MCR,0xA);	//out2 and rts
  OutU8(0x21,InU8(0x21) & (0xFF-0x18));	//Enable 8259 IRQ 3 & 4
  OutU8(c->base+UART_IER,1);	//RX but no THR empty
  POPFD

  return c;
}

public U0 CommPutChar(I64 port,U8 b)
{/*Wait for the transmitter, then queue one byte.

Yield inside the wait loop, not a spin: scheduling is cooperative, so a bare
spin here would lock up the whole machine. The guard count is there so a host
that stopped draining its end of the pipe cannot hang the guest forever - we
drop the byte and move on.
*/
  CComm *c=&comm_ports[port];
  I64 guard=0;

  while (!(InU8(c->base+UART_LSR) & UART_LSR_THRE)) {
    if (++guard>100000) return;
    Yield;
  }

  PUSHFD
  CLI
  FifoU8Ins(c->TX_fifo,b);
  OutU8(c->base+UART_IER,3);	//RX and THR empty
  POPFD
}

public U0 CommPutS(I64 port,U8 *st)
{
  I64 b;
  while (b=*st++)
    CommPutChar(port,b);
}

public U0 CommPutBlk(I64 port,U8 *buf,I64 cnt)
{
  while (cnt--)
    CommPutChar(port,*buf++);
}

public U0 CommPrint(I64 port,U8 *fmt,...)
{
  U8 *buf=StrPrintJoin(NULL,fmt,argc,argv);
  CommPutS(port,buf);
  Free(buf);
}

/* Receive side. None of this is in /Doc/Comm.HC. */

public Bool CommGetChar(I64 port,U8 *_b)
{//FALSE when the receive FIFO is empty. Never blocks.
  CComm *c=&comm_ports[port];
  Bool res;
  PUSHFD
  CLI
  res=FifoU8Rem(c->RX_fifo,_b);
  POPFD
  return res;
}

#define COMM_LINE_MAX	256	//matches the RX FIFO size

class CCommLine
{
  U8	buf[COMM_LINE_MAX];
  I64	len;
} comm_line[5];

public Bool CommGetLine(I64 port,U8 *dst,I64 dst_size)
{/*Accumulate bytes until LF. FALSE while the line is still incomplete.

Partial line state lives per port rather than in a static inside the function.
TaskRunner and the tutor both poll this, and with cooperative scheduling a
shared static would interleave their bytes.

On overflow we hand back what we have instead of swallowing the terminator.
The protocol caps lines at 240 bytes, so an overflow already means something
is wrong upstream and it is better to see the garbage than to lose sync.
*/
  CCommLine *l=&comm_line[port];
  U8 b;

  //No `continue` below, and not for style: HolyC has no such keyword. `break`
  //exists, `continue` does not - the compiler reports it as an undefined
  //identifier, and it appears nowhere in the OS sources either.
  while (CommGetChar(port,&b)) {
    if (b=='\n' || b=='\r') {
      if (l->len) {			//bare terminators are not empty lines
	l->buf[l->len]=0;
	StrCpy(dst,l->buf);
	l->len=0;
	return TRUE;
      }
    } else if (l->len<COMM_LINE_MAX-1 && l->len<dst_size-1)
      l->buf[l->len++]=b;
    else {
      l->buf[l->len]=0;
      StrCpy(dst,l->buf);
      l->len=0;
      return TRUE;
    }
  }
  return FALSE;
}

public Bool CommIsEnabled(I64 port)
{//The host may not be there at all. Sandbox runs stand alone.
  return Bt(&comm_ports[port].flags,COMf_ENABLED);
}
