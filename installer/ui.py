"""Console prompts shared by the Windows and Linux installers."""
import os, sys

def enable_color():
    if not sys.stdout.isatty() or 'NO_COLOR' in os.environ:return False
    if os.name=='nt':
        import ctypes
        from ctypes import wintypes
        kernel=ctypes.windll.kernel32
        kernel.GetStdHandle.restype=wintypes.HANDLE
        kernel.GetConsoleMode.argtypes=[wintypes.HANDLE,ctypes.POINTER(wintypes.DWORD)]
        kernel.SetConsoleMode.argtypes=[wintypes.HANDLE,wintypes.DWORD]
        handle=kernel.GetStdHandle(-11);mode=wintypes.DWORD()
        if not kernel.GetConsoleMode(handle,ctypes.byref(mode)):return False
        if not kernel.SetConsoleMode(handle,mode.value|4):return False
    return True

COLOR=enable_color()
COLORS={'info':'36','success':'32','warning':'33','error':'31'}

def styled(message,kind='info'):
    return f'\033[{COLORS[kind]}m{message}\033[0m' if COLOR else message

def say(message,kind='info'):
    print(styled(message,kind))

def ask(message):return input(styled(message))

def confirm(message):
    while True:
        answer=ask(message+' [y/N]: ').strip().lower()
        if answer in ['y','yes']:return True
        if answer in ['','n','no']:return False
        say('Enter y or n.','warning')

def choose(message,items):
    for number,item in enumerate(items,1):print(styled(f'{number}:')+' '+item)
    while True:
        answer=ask(message+' [1]: ').strip() or '1'
        if answer.isascii() and answer.isdecimal() and 1<=int(answer)<=len(items):return int(answer)
        say(f'Enter a number from 1 to {len(items)}.','warning')
