/* gsp_io_win.c - File Activity and Network instruments on Windows.

   Hooks (through the import tables, see gsp_heap_win.c) the kernel32 file
   functions (CreateFile, ReadFile, WriteFile, FlushFileBuffers,
   CloseHandle) and the winsock calls (socket, connect, accept, send,
   recv, WSASend, WSARecv, closesocket).  The C runtime's stdio and
   low-level I/O end in the kernel32 functions through ucrtbase's import
   table, so fopen/fread are recorded there.

   Handles are classified once and cached, like file descriptors on Linux:
   disk files are file activity, sockets (known from socket/accept) are
   network traffic, and pipes or consoles are left out.  A handle value
   is recorded in the fd field.

   Overlapped operations that are still pending when the call returns are
   not recorded (their size is not known yet).  The agent does not link
   ws2_32: the winsock helpers it needs are looked up when the hooks are
   first used, which only happens in programs that import winsock.  */

#include <winsock2.h>
#include <ws2tcpip.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "GSPerformance/gsp_format.h"
#include "gsp_agent_win.h"

static bool files_on, net_on;

void
gspw_io_start(bool files, bool network)
{
  files_on = files;
  net_on = network;
}

bool
gspw_io_enabled(void)
{
  return files_on || net_on;
}

/* ------------------------------------------------------------------ */
/* handle kinds                                                        */

enum { K_UNKNOWN = 0, K_FILE = 1, K_SOCKET = 2, K_OTHER = 3 };
#define KIND_TABLE 65536
static volatile uint8_t kinds[KIND_TABLE];

static inline size_t
kind_slot(uintptr_t h)
{
  return (size_t)(h >> 2);
}

static void
set_kind(uintptr_t h, int k)
{
  if (kind_slot(h) < KIND_TABLE)
    kinds[kind_slot(h)] = (uint8_t)k;
}

static int
cached_kind(uintptr_t h)
{
  return kind_slot(h) < KIND_TABLE ? kinds[kind_slot(h)] : K_UNKNOWN;
}

static int
kind_of(HANDLE h)
{
  int k = cached_kind((uintptr_t)h);
  if (k != K_UNKNOWN)
    return k;
  DWORD e = GetLastError();
  k = GetFileType(h) == FILE_TYPE_DISK ? K_FILE : K_OTHER;
  SetLastError(e);
  set_kind((uintptr_t)h, k);
  return k;
}

/* ------------------------------------------------------------------ */
/* records                                                             */

static void
emit_io(int op, uintptr_t h, int64_t result, uint64_t start, const char *name,
        uint32_t flags)
{
  gsp_io_payload p;
  uint64_t end = gspw_now();

  p.result = result;
  p.duration = end > start ? end - start : 0;
  p.fd = (int32_t)h;
  p.name = name ? gspw_intern(name) : 0;
  p.stack = gspw_caller_stack();
  p.flags = flags;
  gspw_emit(GSP_REC_IO, (uint32_t)op, 0, start, GetCurrentThreadId(), &p, sizeof(p),
            NULL, 0);
}

static void
wide_to_utf8(LPCWSTR w, char *out, int cap)
{
  out[0] = 0;
  if (w && WideCharToMultiByte(CP_UTF8, 0, w, -1, out, cap, NULL, NULL) == 0)
    out[0] = 0;
}

/* ------------------------------------------------------------------ */
/* files                                                               */

static HANDLE (WINAPI *real_CreateFileW)(LPCWSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES,
                                          DWORD, DWORD, HANDLE);
static HANDLE (WINAPI *real_CreateFileA)(LPCSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES,
                                          DWORD, DWORD, HANDLE);
static BOOL (WINAPI *real_ReadFile)(HANDLE, LPVOID, DWORD, LPDWORD, LPOVERLAPPED);
static BOOL (WINAPI *real_WriteFile)(HANDLE, LPCVOID, DWORD, LPDWORD, LPOVERLAPPED);
static BOOL (WINAPI *real_FlushFileBuffers)(HANDLE);
static BOOL (WINAPI *real_CloseHandle)(HANDLE);

static HANDLE
after_create(HANDLE h, const char *path, DWORD access, uint64_t start)
{
  DWORD err = GetLastError();
  int k = K_FILE;
  if (h != INVALID_HANDLE_VALUE)
    {
      set_kind((uintptr_t)h, K_UNKNOWN);
      k = kind_of(h);
    }
  if (k == K_FILE)
    emit_io(GSP_IO_OPEN, h == INVALID_HANDLE_VALUE ? (uintptr_t)-1 : (uintptr_t)h,
            h == INVALID_HANDLE_VALUE ? -(int64_t)err : (int64_t)(uintptr_t)h,
            start, path, access);
  SetLastError(err);
  return h;
}

static HANDLE WINAPI
hook_CreateFileW(LPCWSTR name, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES sa,
                 DWORD disposition, DWORD flags, HANDLE templ)
{
  if (!files_on || !gspw_guard_enter())
    return real_CreateFileW(name, access, share, sa, disposition, flags, templ);
  uint64_t start = gspw_now();
  HANDLE h = real_CreateFileW(name, access, share, sa, disposition, flags, templ);
  char path[MAX_PATH * 3];
  DWORD err = GetLastError();
  wide_to_utf8(name, path, sizeof(path));
  SetLastError(err);
  after_create(h, path, access, start);
  gspw_guard_leave();
  return h;
}

static HANDLE WINAPI
hook_CreateFileA(LPCSTR name, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES sa,
                 DWORD disposition, DWORD flags, HANDLE templ)
{
  if (!files_on || !gspw_guard_enter())
    return real_CreateFileA(name, access, share, sa, disposition, flags, templ);
  uint64_t start = gspw_now();
  HANDLE h = real_CreateFileA(name, access, share, sa, disposition, flags, templ);
  after_create(h, name, access, start);
  gspw_guard_leave();
  return h;
}

/* Records a read or write on a handle, as file or network traffic.  */
static void
data_op(HANDLE h, bool is_write, BOOL ok, DWORD done, uint64_t start, bool pending)
{
  DWORD err = GetLastError();
  int k = kind_of(h);
  if (!pending)
    {
      int64_t res = ok ? (int64_t)done : -(int64_t)err;
      if (k == K_FILE && files_on)
        emit_io(is_write ? GSP_IO_WRITE : GSP_IO_READ, (uintptr_t)h, res, start, NULL, 0);
      else if (k == K_SOCKET && net_on)
        emit_io(is_write ? GSP_IO_SEND : GSP_IO_RECV, (uintptr_t)h, res, start, NULL, 0);
    }
  SetLastError(err);
}

static BOOL WINAPI
hook_ReadFile(HANDLE h, LPVOID buf, DWORD n, LPDWORD got, LPOVERLAPPED ov)
{
  if (!gspw_io_enabled() || !gspw_guard_enter())
    return real_ReadFile(h, buf, n, got, ov);
  DWORD local = 0;
  uint64_t start = gspw_now();
  BOOL ok = real_ReadFile(h, buf, n, got ? got : (ov ? NULL : &local), ov);
  bool pending = !ok && GetLastError() == ERROR_IO_PENDING;
  data_op(h, false, ok, got ? *got : local, start, pending || (ov && !got));
  gspw_guard_leave();
  return ok;
}

static BOOL WINAPI
hook_WriteFile(HANDLE h, LPCVOID buf, DWORD n, LPDWORD put, LPOVERLAPPED ov)
{
  if (!gspw_io_enabled() || !gspw_guard_enter())
    return real_WriteFile(h, buf, n, put, ov);
  DWORD local = 0;
  uint64_t start = gspw_now();
  BOOL ok = real_WriteFile(h, buf, n, put ? put : (ov ? NULL : &local), ov);
  bool pending = !ok && GetLastError() == ERROR_IO_PENDING;
  data_op(h, true, ok, put ? *put : local, start, pending || (ov && !put));
  gspw_guard_leave();
  return ok;
}

static BOOL WINAPI
hook_FlushFileBuffers(HANDLE h)
{
  if (!files_on || !gspw_guard_enter())
    return real_FlushFileBuffers(h);
  uint64_t start = gspw_now();
  BOOL ok = real_FlushFileBuffers(h);
  DWORD err = GetLastError();
  if (kind_of(h) == K_FILE)
    emit_io(GSP_IO_SYNC, (uintptr_t)h, ok ? 0 : -(int64_t)err, start, NULL, 0);
  SetLastError(err);
  gspw_guard_leave();
  return ok;
}

/* Only handles already known as files or sockets are recorded: most
   handles closed are threads, events and the like.  */
static BOOL WINAPI
hook_CloseHandle(HANDLE h)
{
  int k = cached_kind((uintptr_t)h);
  if ((k != K_FILE && k != K_SOCKET) || !gspw_guard_enter())
    {
      set_kind((uintptr_t)h, K_UNKNOWN);
      return real_CloseHandle(h);
    }
  uint64_t start = gspw_now();
  BOOL ok = real_CloseHandle(h);
  DWORD err = GetLastError();
  set_kind((uintptr_t)h, K_UNKNOWN);
  if ((k == K_FILE && files_on) || (k == K_SOCKET && net_on))
    emit_io(GSP_IO_CLOSE, (uintptr_t)h, ok ? 0 : -(int64_t)err, start, NULL,
            k == K_SOCKET ? GSP_IO_SOCKET : 0);
  SetLastError(err);
  gspw_guard_leave();
  return ok;
}

/* ------------------------------------------------------------------ */
/* sockets                                                             */

static SOCKET (WSAAPI *real_socket)(int, int, int);
static SOCKET (WSAAPI *real_WSASocketW)(int, int, int, LPWSAPROTOCOL_INFOW, GROUP, DWORD);
static SOCKET (WSAAPI *real_WSASocketA)(int, int, int, LPWSAPROTOCOL_INFOA, GROUP, DWORD);
static int (WSAAPI *real_connect)(SOCKET, const struct sockaddr *, int);
static SOCKET (WSAAPI *real_accept)(SOCKET, struct sockaddr *, int *);
static int (WSAAPI *real_send)(SOCKET, const char *, int, int);
static int (WSAAPI *real_recv)(SOCKET, char *, int, int);
static int (WSAAPI *real_sendto)(SOCKET, const char *, int, int, const struct sockaddr *, int);
static int (WSAAPI *real_recvfrom)(SOCKET, char *, int, int, struct sockaddr *, int *);
static int (WSAAPI *real_WSASend)(SOCKET, LPWSABUF, DWORD, LPDWORD, DWORD,
                                   LPWSAOVERLAPPED, LPWSAOVERLAPPED_COMPLETION_ROUTINE);
static int (WSAAPI *real_WSARecv)(SOCKET, LPWSABUF, DWORD, LPDWORD, LPDWORD,
                                   LPWSAOVERLAPPED, LPWSAOVERLAPPED_COMPLETION_ROUTINE);
static int (WSAAPI *real_closesocket)(SOCKET);

static PCSTR (WSAAPI *p_inet_ntop)(INT, const VOID *, PSTR, size_t);
static int (WSAAPI *p_getpeername)(SOCKET, struct sockaddr *, int *);

static void
resolve_winsock(void)
{
  if (p_inet_ntop)
    return;
  HMODULE ws = GetModuleHandleA("ws2_32.dll");
  if (ws == NULL)
    return;
  p_getpeername = (void *)GetProcAddress(ws, "getpeername");
  p_inet_ntop = (void *)GetProcAddress(ws, "inet_ntop");
}

static uint16_t
port_of(uint16_t net)
{
  return (uint16_t)((net >> 8) | (net << 8));
}

static void
format_peer(const struct sockaddr *sa, int len, char *out, size_t cap)
{
  char a[64];
  out[0] = 0;
  resolve_winsock();
  if (sa == NULL || p_inet_ntop == NULL)
    return;
  if (sa->sa_family == AF_INET && len >= (int)sizeof(struct sockaddr_in))
    {
      const struct sockaddr_in *in = (const struct sockaddr_in *)sa;
      if (p_inet_ntop(AF_INET, &in->sin_addr, a, sizeof(a)))
        snprintf(out, cap, "%s:%u", a, port_of(in->sin_port));
    }
  else if (sa->sa_family == AF_INET6 && len >= (int)sizeof(struct sockaddr_in6))
    {
      const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)sa;
      if (p_inet_ntop(AF_INET6, &in6->sin6_addr, a, sizeof(a)))
        snprintf(out, cap, "[%s]:%u", a, port_of(in6->sin6_port));
    }
  else
    snprintf(out, cap, "family %d", sa->sa_family);
}

static SOCKET WSAAPI
hook_socket(int af, int type, int proto)
{
  SOCKET s = real_socket(af, type, proto);
  if (s != INVALID_SOCKET)
    set_kind((uintptr_t)s, K_SOCKET);
  return s;
}

static SOCKET WSAAPI
hook_WSASocketW(int af, int type, int proto, LPWSAPROTOCOL_INFOW info, GROUP g, DWORD flags)
{
  SOCKET s = real_WSASocketW(af, type, proto, info, g, flags);
  if (s != INVALID_SOCKET)
    set_kind((uintptr_t)s, K_SOCKET);
  return s;
}

static SOCKET WSAAPI
hook_WSASocketA(int af, int type, int proto, LPWSAPROTOCOL_INFOA info, GROUP g, DWORD flags)
{
  SOCKET s = real_WSASocketA(af, type, proto, info, g, flags);
  if (s != INVALID_SOCKET)
    set_kind((uintptr_t)s, K_SOCKET);
  return s;
}

static int WSAAPI
hook_connect(SOCKET s, const struct sockaddr *name, int len)
{
  set_kind((uintptr_t)s, K_SOCKET);
  if (!net_on || !gspw_guard_enter())
    return real_connect(s, name, len);
  uint64_t start = gspw_now();
  int r = real_connect(s, name, len);
  DWORD err = GetLastError();
  char peer[128];
  format_peer(name, len, peer, sizeof(peer));
  emit_io(GSP_IO_CONNECT, (uintptr_t)s, r == 0 ? 0 : -(int64_t)err, start, peer, 0);
  SetLastError(err);
  gspw_guard_leave();
  return r;
}

static SOCKET WSAAPI
hook_accept(SOCKET s, struct sockaddr *addr, int *len)
{
  if (!net_on || !gspw_guard_enter())
    {
      SOCKET c = real_accept(s, addr, len);
      if (c != INVALID_SOCKET)
        set_kind((uintptr_t)c, K_SOCKET);
      return c;
    }
  uint64_t start = gspw_now();
  SOCKET c = real_accept(s, addr, len);
  DWORD err = GetLastError();
  char peer[128] = "";
  if (c != INVALID_SOCKET)
    {
      struct sockaddr_storage ss;
      int sl = sizeof(ss);
      set_kind((uintptr_t)c, K_SOCKET);
      resolve_winsock();
      if (p_getpeername && p_getpeername(c, (struct sockaddr *)&ss, &sl) == 0)
        format_peer((struct sockaddr *)&ss, sl, peer, sizeof(peer));
    }
  emit_io(GSP_IO_ACCEPT, c == INVALID_SOCKET ? (uintptr_t)-1 : (uintptr_t)c,
          c == INVALID_SOCKET ? -(int64_t)err : (int64_t)c, start, peer[0] ? peer : NULL, 0);
  SetLastError(err);
  gspw_guard_leave();
  return c;
}

static void
net_op(SOCKET s, bool is_send, int r, uint64_t start)
{
  DWORD err = GetLastError();
  set_kind((uintptr_t)s, K_SOCKET);
  emit_io(is_send ? GSP_IO_SEND : GSP_IO_RECV, (uintptr_t)s,
          r == SOCKET_ERROR ? -(int64_t)err : (int64_t)r, start, NULL, 0);
  SetLastError(err);
}

static int WSAAPI
hook_send(SOCKET s, const char *buf, int len, int flags)
{
  if (!net_on || !gspw_guard_enter())
    return real_send(s, buf, len, flags);
  uint64_t start = gspw_now();
  int r = real_send(s, buf, len, flags);
  net_op(s, true, r, start);
  gspw_guard_leave();
  return r;
}

static int WSAAPI
hook_recv(SOCKET s, char *buf, int len, int flags)
{
  if (!net_on || !gspw_guard_enter())
    return real_recv(s, buf, len, flags);
  uint64_t start = gspw_now();
  int r = real_recv(s, buf, len, flags);
  net_op(s, false, r, start);
  gspw_guard_leave();
  return r;
}

static int WSAAPI
hook_sendto(SOCKET s, const char *buf, int len, int flags, const struct sockaddr *to, int tolen)
{
  if (!net_on || !gspw_guard_enter())
    return real_sendto(s, buf, len, flags, to, tolen);
  uint64_t start = gspw_now();
  int r = real_sendto(s, buf, len, flags, to, tolen);
  net_op(s, true, r, start);
  gspw_guard_leave();
  return r;
}

static int WSAAPI
hook_recvfrom(SOCKET s, char *buf, int len, int flags, struct sockaddr *from, int *fromlen)
{
  if (!net_on || !gspw_guard_enter())
    return real_recvfrom(s, buf, len, flags, from, fromlen);
  uint64_t start = gspw_now();
  int r = real_recvfrom(s, buf, len, flags, from, fromlen);
  net_op(s, false, r, start);
  gspw_guard_leave();
  return r;
}

static int WSAAPI
hook_WSASend(SOCKET s, LPWSABUF bufs, DWORD n, LPDWORD sent, DWORD flags,
             LPWSAOVERLAPPED ov, LPWSAOVERLAPPED_COMPLETION_ROUTINE done)
{
  if (!net_on || !gspw_guard_enter())
    return real_WSASend(s, bufs, n, sent, flags, ov, done);
  uint64_t start = gspw_now();
  int r = real_WSASend(s, bufs, n, sent, flags, ov, done);
  DWORD err = GetLastError();
  if (!(r == SOCKET_ERROR && err == WSA_IO_PENDING) && (r == SOCKET_ERROR || sent))
    net_op(s, true, r == SOCKET_ERROR ? r : (int)*sent, start);
  SetLastError(err);
  gspw_guard_leave();
  return r;
}

static int WSAAPI
hook_WSARecv(SOCKET s, LPWSABUF bufs, DWORD n, LPDWORD got, LPDWORD flags,
             LPWSAOVERLAPPED ov, LPWSAOVERLAPPED_COMPLETION_ROUTINE done)
{
  if (!net_on || !gspw_guard_enter())
    return real_WSARecv(s, bufs, n, got, flags, ov, done);
  uint64_t start = gspw_now();
  int r = real_WSARecv(s, bufs, n, got, flags, ov, done);
  DWORD err = GetLastError();
  if (!(r == SOCKET_ERROR && err == WSA_IO_PENDING) && (r == SOCKET_ERROR || got))
    net_op(s, false, r == SOCKET_ERROR ? r : (int)*got, start);
  SetLastError(err);
  gspw_guard_leave();
  return r;
}

static int WSAAPI
hook_closesocket(SOCKET s)
{
  if (!net_on || !gspw_guard_enter())
    {
      set_kind((uintptr_t)s, K_UNKNOWN);
      return real_closesocket(s);
    }
  uint64_t start = gspw_now();
  int r = real_closesocket(s);
  DWORD err = GetLastError();
  set_kind((uintptr_t)s, K_UNKNOWN);
  emit_io(GSP_IO_CLOSE, (uintptr_t)s, r == 0 ? 0 : -(int64_t)err, start, NULL, GSP_IO_SOCKET);
  SetLastError(err);
  gspw_guard_leave();
  return r;
}

/* ------------------------------------------------------------------ */

#define HOOK(n, lib, fn) { #n, lib, (void *)fn, (void **)&real_##n }
gspw_hook gspw_io_hooks[] = {
  HOOK(CreateFileW, GSPW_LIB_KERNEL, hook_CreateFileW),
  HOOK(CreateFileA, GSPW_LIB_KERNEL, hook_CreateFileA),
  HOOK(ReadFile, GSPW_LIB_KERNEL, hook_ReadFile),
  HOOK(WriteFile, GSPW_LIB_KERNEL, hook_WriteFile),
  HOOK(FlushFileBuffers, GSPW_LIB_KERNEL, hook_FlushFileBuffers),
  HOOK(CloseHandle, GSPW_LIB_KERNEL, hook_CloseHandle),
  HOOK(socket, GSPW_LIB_NET, hook_socket),
  HOOK(WSASocketW, GSPW_LIB_NET, hook_WSASocketW),
  HOOK(WSASocketA, GSPW_LIB_NET, hook_WSASocketA),
  HOOK(connect, GSPW_LIB_NET, hook_connect),
  HOOK(accept, GSPW_LIB_NET, hook_accept),
  HOOK(send, GSPW_LIB_NET, hook_send),
  HOOK(recv, GSPW_LIB_NET, hook_recv),
  HOOK(sendto, GSPW_LIB_NET, hook_sendto),
  HOOK(recvfrom, GSPW_LIB_NET, hook_recvfrom),
  HOOK(WSASend, GSPW_LIB_NET, hook_WSASend),
  HOOK(WSARecv, GSPW_LIB_NET, hook_WSARecv),
  HOOK(closesocket, GSPW_LIB_NET, hook_closesocket),
};
const size_t gspw_io_hook_count = sizeof(gspw_io_hooks) / sizeof(gspw_io_hooks[0]);
