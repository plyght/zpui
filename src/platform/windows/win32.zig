//! Minimal hand-written Win32 bindings for the Windows backend (no external packages):
//! user32 / kernel32 / gdi32 / shell32 / advapi32 / dwmapi / ole32 / uxtheme / comctl32 /
//! imm32 / shcore, plus the COM base (`IUnknown`, GUIDs) and DirectComposition.
//!
//! COM interfaces are `extern struct { vtbl: *const VTable }`; vtables list every method
//! in declaration order (inherited ones first) so slot offsets match the SDK headers, with
//! `*const anyopaque` placeholders for methods zpui never calls.

const std = @import("std");

pub const WINAPI: std.builtin.CallingConvention = .winapi;

pub const BOOL = i32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const UINT = u32;
pub const INT = i32;
pub const LONG = i32;
pub const ULONG = u32;
pub const WCHAR = u16;
pub const HRESULT = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LONG_PTR = isize;
pub const ATOM = u16;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;

pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMODULE = HINSTANCE;
pub const HMENU = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = HICON;
pub const HBRUSH = *opaque {};
pub const HMONITOR = *opaque {};
pub const HDC = *opaque {};
pub const HBITMAP = *opaque {};
pub const HGDIOBJ = *anyopaque;
pub const HGLOBAL = *anyopaque;
pub const HHOOK = *opaque {};
pub const HWINEVENTHOOK = *opaque {};
pub const HKEY = *opaque {};
pub const HIMC = *opaque {};
pub const HFONT = *opaque {};
pub const DPI_AWARENESS_CONTEXT = isize;

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}
pub fn FAILED(hr: HRESULT) bool {
    return hr < 0;
}
pub const Error = error{ComFailed};
/// `hr` as a Zig error (logged once at debug level by the caller if it cares).
pub fn check(hr: HRESULT) Error!void {
    if (hr < 0) {
        last_hresult = hr;
        return error.ComFailed;
    }
}
/// The HRESULT behind the most recent `error.ComFailed` from `check` (diagnostics).
pub threadlocal var last_hresult: HRESULT = 0;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    /// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" at comptime.
    pub fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(10000);
        const hex = struct {
            fn byte(comptime t: []const u8) u8 {
                return std.fmt.parseInt(u8, t, 16) catch unreachable;
            }
        };
        return .{
            .data1 = std.fmt.parseInt(u32, s[0..8], 16) catch unreachable,
            .data2 = std.fmt.parseInt(u16, s[9..13], 16) catch unreachable,
            .data3 = std.fmt.parseInt(u16, s[14..18], 16) catch unreachable,
            .data4 = .{
                hex.byte(s[19..21]), hex.byte(s[21..23]), hex.byte(s[24..26]), hex.byte(s[26..28]),
                hex.byte(s[28..30]), hex.byte(s[30..32]), hex.byte(s[32..34]), hex.byte(s[34..36]),
            },
        };
    }
};

pub const POINT = extern struct { x: LONG = 0, y: LONG = 0 };
pub const SIZE = extern struct { cx: LONG = 0, cy: LONG = 0 };
pub const RECT = extern struct {
    left: LONG = 0,
    top: LONG = 0,
    right: LONG = 0,
    bottom: LONG = 0,
    pub fn width(r: RECT) LONG {
        return r.right - r.left;
    }
    pub fn height(r: RECT) LONG {
        return r.bottom - r.top;
    }
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD = 0,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: LONG,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: DWORD,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const MONITORINFOEXW = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFOEXW),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
    szDevice: [32]WCHAR = @splat(0),
};
pub const MONITORINFOF_PRIMARY: DWORD = 1;

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: ?HWND,
    dwHoverTime: DWORD = 0,
};
pub const TME_LEAVE: DWORD = 0x2;

pub const WINDOWPOS = extern struct {
    hwnd: ?HWND,
    hwndInsertAfter: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: UINT,
};

pub const KBDLLHOOKSTRUCT = extern struct {
    vkCode: DWORD,
    scanCode: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};
pub const MSLLHOOKSTRUCT = extern struct {
    pt: POINT,
    mouseData: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};
pub const LLKHF_EXTENDED: DWORD = 0x01;
pub const LLKHF_INJECTED: DWORD = 0x10;
pub const LLKHF_UP: DWORD = 0x80;

pub const HOOKPROC = *const fn (code: i32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub const WINEVENTPROC = *const fn (hook: ?HWINEVENTHOOK, event: DWORD, hwnd: ?HWND, id_object: LONG, id_child: LONG, thread: DWORD, time: DWORD) callconv(WINAPI) void;
pub const MONITORENUMPROC = *const fn (HMONITOR, ?HDC, *RECT, LPARAM) callconv(WINAPI) BOOL;
pub const TIMERPROC = *const fn (?HWND, UINT, usize, DWORD) callconv(WINAPI) void;

pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT = 0,
    uFlags: UINT = 0,
    uCallbackMessage: UINT = 0,
    hIcon: ?HICON = null,
    szTip: [128]WCHAR = @splat(0),
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]WCHAR = @splat(0),
    uVersion: UINT = 0,
    szInfoTitle: [64]WCHAR = @splat(0),
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = std.mem.zeroes(GUID),
    hBalloonIcon: ?HICON = null,
};
pub const NIM_ADD: DWORD = 0;
pub const NIM_MODIFY: DWORD = 1;
pub const NIM_DELETE: DWORD = 2;
pub const NIM_SETVERSION: DWORD = 4;
pub const NIF_MESSAGE: UINT = 0x1;
pub const NIF_ICON: UINT = 0x2;
pub const NIF_TIP: UINT = 0x4;
pub const NIF_SHOWTIP: UINT = 0x80;
pub const NOTIFYICON_VERSION_4: UINT = 4;
pub const NIN_SELECT: UINT = WM_USER + 0;
pub const NIN_KEYSELECT: UINT = NIN_SELECT | 1;

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD = 1,
    biBitCount: WORD = 32,
    biCompression: DWORD = 0, // BI_RGB
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: LONG = 0,
    biYPelsPerMeter: LONG = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};
pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]DWORD = .{0},
};
pub const ICONINFO = extern struct {
    fIcon: BOOL,
    xHotspot: DWORD = 0,
    yHotspot: DWORD = 0,
    hbmMask: ?HBITMAP,
    hbmColor: ?HBITMAP,
};

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: DWORD = @sizeOf(INITCOMMONCONTROLSEX),
    dwICC: DWORD,
};
pub const ICC_STANDARD_CLASSES: DWORD = 0x4000;
pub const ICC_BAR_CLASSES: DWORD = 0x4;
pub const ICC_UPDOWN_CLASS: DWORD = 0x10;

pub const NMHDR = extern struct {
    hwndFrom: ?HWND,
    idFrom: usize,
    code: i32,
};

pub const MARGINS = extern struct { left: i32, right: i32, top: i32, bottom: i32 };

pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};
pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD,
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};
pub const CFS_POINT: DWORD = 0x2;
pub const CFS_EXCLUDE: DWORD = 0x80;

pub const ACTCTXW = extern struct {
    cbSize: ULONG = @sizeOf(ACTCTXW),
    dwFlags: DWORD = 0,
    lpSource: ?LPCWSTR = null,
    wProcessorArchitecture: u16 = 0,
    wLangId: u16 = 0,
    lpAssemblyDirectory: ?LPCWSTR = null,
    lpResourceName: ?LPCWSTR = null,
    lpApplicationName: ?LPCWSTR = null,
    hModule: ?HMODULE = null,
};
pub const ACTCTX_FLAG_RESOURCE_NAME_VALID: DWORD = 0x8;
pub const ACTCTX_FLAG_ASSEMBLY_DIRECTORY_VALID: DWORD = 0x4;
pub const MAX_PATH: usize = 260;

pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
pub const CONDITION_VARIABLE = extern struct { ptr: ?*anyopaque = null };

// ---- window messages ----------------------------------------------------------------------

pub const WM_NULL: UINT = 0x0000;
pub const WM_CREATE: UINT = 0x0001;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_MOVE: UINT = 0x0003;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_SHOWWINDOW: UINT = 0x0018;
pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const WM_ACTIVATEAPP: UINT = 0x001C;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_MOUSEACTIVATE: UINT = 0x0021;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_WINDOWPOSCHANGED: UINT = 0x0047;
pub const WM_NOTIFY: UINT = 0x004E;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_NCDESTROY: UINT = 0x0082;
pub const WM_NCCALCSIZE: UINT = 0x0083;
pub const WM_NCHITTEST: UINT = 0x0084;
pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_DEADCHAR: UINT = 0x0103;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;
pub const WM_UNICHAR: UINT = 0x0109;
pub const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
pub const WM_IME_COMPOSITION: UINT = 0x010F;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_SYSCOMMAND: UINT = 0x0112;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_HSCROLL: UINT = 0x0114;
pub const WM_VSCROLL: UINT = 0x0115;
pub const WM_INITMENUPOPUP: UINT = 0x0117;
pub const WM_CTLCOLORBTN: UINT = 0x0135;
pub const WM_CTLCOLORSTATIC: UINT = 0x0138;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_CAPTURECHANGED: UINT = 0x0215;
pub const WM_ENTERSIZEMOVE: UINT = 0x0231;
pub const WM_EXITSIZEMOVE: UINT = 0x0232;
pub const WM_DROPFILES: UINT = 0x0233;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_CLIPBOARDUPDATE: UINT = 0x031D;
pub const WM_DWMCOMPOSITIONCHANGED: UINT = 0x031E;
pub const WM_THEMECHANGED: UINT = 0x031A;
pub const WM_USER: UINT = 0x0400;
pub const WM_DISPLAYCHANGE: UINT = 0x007E;
pub const WM_CONTEXTMENU: UINT = 0x007B;
pub const WM_STYLECHANGED: UINT = 0x007D;
pub const WM_INPUTLANGCHANGE: UINT = 0x0051;
pub const WM_ENTERMENULOOP: UINT = 0x0211;
pub const WM_EXITMENULOOP: UINT = 0x0212;
pub const WM_IME_SETCONTEXT: UINT = 0x0281;
pub const WM_IME_NOTIFY: UINT = 0x0282;
pub const WM_GETDLGCODE: UINT = 0x0087;
pub const WM_NCMOUSEMOVE: UINT = 0x00A0;
pub const WM_CTLCOLOREDIT: UINT = 0x0133;
pub const WM_CTLCOLORLISTBOX: UINT = 0x0134;
pub const WM_SYSCOLORCHANGE: UINT = 0x0015;
pub const WM_NCPOINTERUPDATE: UINT = 0x0241;
pub const WM_APP: UINT = 0x8000;

pub const MK_LBUTTON: WPARAM = 0x1;
pub const MK_RBUTTON: WPARAM = 0x2;
pub const MK_MBUTTON: WPARAM = 0x10;
pub const MK_XBUTTON1: WPARAM = 0x20;
pub const MK_XBUTTON2: WPARAM = 0x40;
pub const XBUTTON1: u16 = 1;
pub const WHEEL_DELTA: i32 = 120;

pub const HTTRANSPARENT: LRESULT = -1;
pub const HTCLIENT: LRESULT = 1;
pub const HTCAPTION: LRESULT = 2;
pub const HTNOWHERE: LRESULT = 0;
pub const HTLEFT: LRESULT = 10;
pub const HTRIGHT: LRESULT = 11;
pub const HTTOP: LRESULT = 12;
pub const HTTOPLEFT: LRESULT = 13;
pub const HTTOPRIGHT: LRESULT = 14;
pub const HTBOTTOM: LRESULT = 15;
pub const HTBOTTOMLEFT: LRESULT = 16;
pub const HTBOTTOMRIGHT: LRESULT = 17;
pub const MA_ACTIVATE: LRESULT = 1;
pub const GCS_COMPSTR: LPARAM = 0x8;
pub const GCS_RESULTSTR: LPARAM = 0x800;
pub const GCS_CURSORPOS: LPARAM = 0x80;
pub const SPI_GETWHEELSCROLLLINES: UINT = 0x0068;
pub const SPI_GETWHEELSCROLLCHARS: UINT = 0x006C;
pub const SWP_NOCOPYBITS: UINT = 0x0100;
pub const SWP_NOSENDCHANGING: UINT = 0x0400;
pub const RDW_INVALIDATE: UINT = 0x1;
pub const WM_CHANGEUISTATE: UINT = 0x0127;
pub const MA_NOACTIVATE: LRESULT = 3;
pub const WA_INACTIVE: WPARAM = 0;
pub const SIZE_MINIMIZED: WPARAM = 1;
pub const SIZE_MAXIMIZED: WPARAM = 2;
pub const SC_MINIMIZE: WPARAM = 0xF020;
pub const SC_MAXIMIZE: WPARAM = 0xF030;
pub const SC_RESTORE: WPARAM = 0xF120;

// ---- styles -------------------------------------------------------------------------------

pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_MINIMIZE: DWORD = 0x20000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_MAXIMIZE: DWORD = 0x01000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_GROUP: DWORD = 0x00020000;
pub const WS_TABSTOP: DWORD = 0x00010000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_OVERLAPPEDWINDOW: DWORD = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_ACCEPTFILES: DWORD = 0x00000010;
pub const WS_EX_TRANSPARENT: DWORD = 0x00000020;
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;
pub const WS_EX_NOACTIVATE: DWORD = 0x08000000;

pub const CS_VREDRAW: UINT = 0x1;
pub const CS_HREDRAW: UINT = 0x2;
pub const CS_DBLCLKS: UINT = 0x8;
pub const CS_OWNDC: UINT = 0x20;

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const GWLP_USERDATA: i32 = -21;
pub const GWLP_WNDPROC: i32 = -4;
pub const HWND_MESSAGE: isize = -3;
pub const HWND_TOPMOST: isize = -1;
pub const HWND_NOTOPMOST: isize = -2;
pub const HWND_TOP: isize = 0;

pub const SW_HIDE: i32 = 0;
pub const SW_SHOWNORMAL: i32 = 1;
pub const SW_SHOWMINIMIZED: i32 = 2;
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_SHOWNOACTIVATE: i32 = 4;
pub const SW_SHOW: i32 = 5;
pub const SW_MINIMIZE: i32 = 6;
pub const SW_SHOWNA: i32 = 8;
pub const SW_RESTORE: i32 = 9;

pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOREDRAW: UINT = 0x0008;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_SHOWWINDOW: UINT = 0x0040;
pub const SWP_HIDEWINDOW: UINT = 0x0080;
pub const SWP_NOOWNERZORDER: UINT = 0x0200;
pub const SWP_ASYNCWINDOWPOS: UINT = 0x4000;

pub const PM_REMOVE: UINT = 0x1;
pub const QS_ALLINPUT: DWORD = 0x04FF;
pub const MWMO_INPUTAVAILABLE: DWORD = 0x4;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const USER_TIMER_MINIMUM: UINT = 0xA;

pub const MONITOR_DEFAULTTONULL: DWORD = 0;
pub const MONITOR_DEFAULTTOPRIMARY: DWORD = 1;
pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;
pub const MDT_EFFECTIVE_DPI: i32 = 0;
pub const USER_DEFAULT_SCREEN_DPI: u32 = 96;
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT = -4;
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE: DPI_AWARENESS_CONTEXT = -3;

// Cursors (MAKEINTRESOURCE ids).
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDI_APPLICATION: usize = 32512;

// Virtual keys.
pub const VK_BACK: u32 = 0x08;
pub const VK_TAB: u32 = 0x09;
pub const VK_CLEAR: u32 = 0x0C;
pub const VK_RETURN: u32 = 0x0D;
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = 0x11;
pub const VK_MENU: u32 = 0x12;
pub const VK_PAUSE: u32 = 0x13;
pub const VK_CAPITAL: u32 = 0x14;
pub const VK_ESCAPE: u32 = 0x1B;
pub const VK_SPACE: u32 = 0x20;
pub const VK_PRIOR: u32 = 0x21;
pub const VK_NEXT: u32 = 0x22;
pub const VK_END: u32 = 0x23;
pub const VK_HOME: u32 = 0x24;
pub const VK_LEFT: u32 = 0x25;
pub const VK_UP: u32 = 0x26;
pub const VK_RIGHT: u32 = 0x27;
pub const VK_DOWN: u32 = 0x28;
pub const VK_SNAPSHOT: u32 = 0x2C;
pub const VK_INSERT: u32 = 0x2D;
pub const VK_DELETE: u32 = 0x2E;
pub const VK_LWIN: u32 = 0x5B;
pub const VK_RWIN: u32 = 0x5C;
pub const VK_APPS: u32 = 0x5D;
pub const VK_NUMPAD0: u32 = 0x60;
pub const VK_MULTIPLY: u32 = 0x6A;
pub const VK_ADD: u32 = 0x6B;
pub const VK_SEPARATOR: u32 = 0x6C;
pub const VK_SUBTRACT: u32 = 0x6D;
pub const VK_DECIMAL: u32 = 0x6E;
pub const VK_DIVIDE: u32 = 0x6F;
pub const VK_F1: u32 = 0x70;
pub const VK_F24: u32 = 0x87;
pub const VK_NUMLOCK: u32 = 0x90;
pub const VK_LSHIFT: u32 = 0xA0;
pub const VK_RSHIFT: u32 = 0xA1;
pub const VK_LCONTROL: u32 = 0xA2;
pub const VK_RCONTROL: u32 = 0xA3;
pub const VK_LMENU: u32 = 0xA4;
pub const VK_RMENU: u32 = 0xA5;
pub const VK_OEM_1: u32 = 0xBA;
pub const VK_OEM_PLUS: u32 = 0xBB;
pub const VK_OEM_COMMA: u32 = 0xBC;
pub const VK_OEM_MINUS: u32 = 0xBD;
pub const VK_OEM_PERIOD: u32 = 0xBE;
pub const VK_OEM_2: u32 = 0xBF;
pub const VK_OEM_3: u32 = 0xC0;
pub const VK_OEM_4: u32 = 0xDB;
pub const VK_OEM_5: u32 = 0xDC;
pub const VK_OEM_6: u32 = 0xDD;
pub const VK_OEM_7: u32 = 0xDE;
pub const MAPVK_VK_TO_CHAR: UINT = 2;
pub const MAPVK_VSC_TO_VK_EX: UINT = 3;

// Hooks / win events.
pub const WH_KEYBOARD_LL: i32 = 13;
pub const WH_MOUSE_LL: i32 = 14;
pub const HC_ACTION: i32 = 0;
pub const EVENT_SYSTEM_FOREGROUND: DWORD = 0x0003;
pub const WINEVENT_OUTOFCONTEXT: DWORD = 0x0000;
pub const WINEVENT_SKIPOWNPROCESS: DWORD = 0x0002;

// Menus.
pub const MF_STRING: UINT = 0x0;
pub const MF_GRAYED: UINT = 0x1;
pub const MF_DISABLED: UINT = 0x2;
pub const MF_CHECKED: UINT = 0x8;
pub const MF_POPUP: UINT = 0x10;
pub const MF_SEPARATOR: UINT = 0x800;
pub const TPM_LEFTALIGN: UINT = 0x0;
pub const TPM_RIGHTBUTTON: UINT = 0x2;
pub const TPM_BOTTOMALIGN: UINT = 0x20;
pub const TPM_RETURNCMD: UINT = 0x100;
pub const TPM_NONOTIFY: UINT = 0x80;

// Clipboard.
pub const CF_UNICODETEXT: UINT = 13;
pub const CF_DIB: UINT = 8;
pub const GMEM_MOVEABLE: UINT = 0x2;

// Registry.
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const KEY_QUERY_VALUE: DWORD = 0x1;
pub const KEY_SET_VALUE: DWORD = 0x2;
pub const KEY_NOTIFY: DWORD = 0x10;
pub const KEY_READ: DWORD = 0x20019;
pub const REG_SZ: DWORD = 1;
pub const REG_DWORD: DWORD = 4;
pub const RRF_RT_REG_DWORD: DWORD = 0x10;
pub const RRF_RT_REG_SZ: DWORD = 0x2;
pub const ERROR_SUCCESS: LONG = 0;

// Processes.
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

// SystemParametersInfo.
pub const SPI_GETCLIENTAREAANIMATION: UINT = 0x1042;
pub const SPI_GETWORKAREA: UINT = 0x0030;
pub const SM_CXDOUBLECLK: i32 = 36;
pub const SM_CYDOUBLECLK: i32 = 37;

// DWM.
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub const DWMWA_WINDOW_CORNER_PREFERENCE: DWORD = 33;
pub const DWMWA_SYSTEMBACKDROP_TYPE: DWORD = 38;
pub const DWMSBT_NONE: u32 = 1;
pub const DWMSBT_MAINWINDOW: u32 = 2; // Mica
pub const DWMSBT_TRANSIENTWINDOW: u32 = 3; // Acrylic

// Layered windows.
pub const LWA_ALPHA: DWORD = 0x2;

// Buttons / common controls.
pub const BS_PUSHBUTTON: DWORD = 0x0;
pub const BS_AUTOCHECKBOX: DWORD = 0x3;
pub const BS_AUTORADIOBUTTON: DWORD = 0x9;
pub const BS_PUSHLIKE: DWORD = 0x1000;
pub const BM_GETCHECK: UINT = 0x00F0;
pub const BM_SETCHECK: UINT = 0x00F1;
pub const BST_UNCHECKED: WPARAM = 0;
pub const BST_CHECKED: WPARAM = 1;
pub const BST_INDETERMINATE: WPARAM = 2;
pub const BN_CLICKED: u16 = 0;
pub const CBS_DROPDOWNLIST: DWORD = 0x3;
pub const CBS_HASSTRINGS: DWORD = 0x200;
pub const CB_ADDSTRING: UINT = 0x0143;
pub const CB_GETCURSEL: UINT = 0x0147;
pub const CB_RESETCONTENT: UINT = 0x014B;
pub const CB_SETCURSEL: UINT = 0x014E;
pub const CB_GETITEMHEIGHT: UINT = 0x0154;
pub const CBN_SELCHANGE: u16 = 1;
pub const TBS_HORZ: DWORD = 0x0;
pub const TBS_AUTOTICKS: DWORD = 0x1;
pub const TBS_NOTICKS: DWORD = 0x10;
pub const TBS_BOTH: DWORD = 0x8;
pub const TBM_GETPOS: UINT = WM_USER;
pub const TBM_SETPOS: UINT = WM_USER + 5;
pub const TBM_SETRANGEMIN: UINT = WM_USER + 7;
pub const TBM_SETRANGEMAX: UINT = WM_USER + 8;
pub const TBM_SETTICFREQ: UINT = WM_USER + 20;
pub const TBM_SETPAGESIZE: UINT = WM_USER + 21;
pub const UDS_SETBUDDYINT: DWORD = 0x2;
pub const UDS_ALIGNRIGHT: DWORD = 0x4;
pub const UDS_ARROWKEYS: DWORD = 0x20;
pub const UDS_HORZ: DWORD = 0x40;
pub const UDS_NOTHOUSANDS: DWORD = 0x80;
pub const UDM_SETRANGE32: UINT = WM_USER + 111;
pub const UDM_SETPOS32: UINT = WM_USER + 113;
pub const UDM_GETPOS32: UINT = WM_USER + 114;
pub const UDN_DELTAPOS: i32 = -722;
pub const NMUPDOWN = extern struct { hdr: NMHDR, iPos: i32, iDelta: i32 };
pub const WM_SETFONT: UINT = 0x0030;
pub const WM_GETFONT: UINT = 0x0031;
pub const DEFAULT_GUI_FONT: i32 = 17;
pub const BLACK_BRUSH: i32 = 4;
pub const NULL_BRUSH: i32 = 5;
pub const TRANSPARENT: i32 = 1;

pub const NONCLIENTMETRICSW = extern struct {
    cbSize: UINT = @sizeOf(NONCLIENTMETRICSW),
    iBorderWidth: i32 = 0,
    iScrollWidth: i32 = 0,
    iScrollHeight: i32 = 0,
    iCaptionWidth: i32 = 0,
    iCaptionHeight: i32 = 0,
    lfCaptionFont: LOGFONTW = .{},
    iSmCaptionWidth: i32 = 0,
    iSmCaptionHeight: i32 = 0,
    lfSmCaptionFont: LOGFONTW = .{},
    iMenuWidth: i32 = 0,
    iMenuHeight: i32 = 0,
    lfMenuFont: LOGFONTW = .{},
    lfStatusFont: LOGFONTW = .{},
    lfMessageFont: LOGFONTW = .{},
    iPaddedBorderWidth: i32 = 0,
};
pub const LOGFONTW = extern struct {
    lfHeight: LONG = 0,
    lfWidth: LONG = 0,
    lfEscapement: LONG = 0,
    lfOrientation: LONG = 0,
    lfWeight: LONG = 0,
    lfItalic: BYTE = 0,
    lfUnderline: BYTE = 0,
    lfStrikeOut: BYTE = 0,
    lfCharSet: BYTE = 0,
    lfOutPrecision: BYTE = 0,
    lfClipPrecision: BYTE = 0,
    lfQuality: BYTE = 0,
    lfPitchAndFamily: BYTE = 0,
    lfFaceName: [32]WCHAR = @splat(0),
};
pub const SPI_GETNONCLIENTMETRICS: UINT = 0x0029;

// COM.
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;

// ---- functions ----------------------------------------------------------------------------

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) ATOM;
pub extern "user32" fn UnregisterClassW(LPCWSTR, ?HINSTANCE) callconv(WINAPI) BOOL;
pub extern "user32" fn CreateWindowExW(ex_style: DWORD, class: LPCWSTR, name: ?LPCWSTR, style: DWORD, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?HMENU, instance: ?HINSTANCE, param: ?*anyopaque) callconv(WINAPI) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn CallWindowProcW(WNDPROC, HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(WINAPI) BOOL;
pub extern "user32" fn IsWindowVisible(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
pub extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn PostThreadMessageW(DWORD, UINT, WPARAM, LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn PostQuitMessage(i32) callconv(WINAPI) void;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(count: DWORD, handles: ?[*]const HANDLE, ms: DWORD, wake_mask: DWORD, flags: DWORD) callconv(WINAPI) DWORD;
pub extern "user32" fn SetWindowLongPtrW(HWND, i32, LONG_PTR) callconv(WINAPI) LONG_PTR;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(WINAPI) LONG_PTR;
pub extern "user32" fn SetWindowPos(HWND, insert_after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn MoveWindow(HWND, x: i32, y: i32, w: i32, h: i32, repaint: BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, usize) callconv(WINAPI) ?HICON;
pub extern "user32" fn SetTimer(?HWND, usize, UINT, ?TIMERPROC) callconv(WINAPI) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(WINAPI) BOOL;
pub extern "user32" fn GetKeyState(i32) callconv(WINAPI) i16;
pub extern "user32" fn GetKeyboardState(*[256]u8) callconv(WINAPI) BOOL;
pub extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(WINAPI) UINT;
pub extern "user32" fn ToUnicode(vk: UINT, scan: UINT, state: *const [256]u8, buf: [*]u16, len: i32, flags: UINT) callconv(WINAPI) i32;
pub extern "user32" fn SetWindowTextW(HWND, LPCWSTR) callconv(WINAPI) BOOL;
pub extern "user32" fn EnumDisplayMonitors(?HDC, ?*const RECT, MONITORENUMPROC, LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFOEXW) callconv(WINAPI) BOOL;
pub extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(WINAPI) ?HMONITOR;
pub extern "user32" fn MonitorFromPoint(POINT, DWORD) callconv(WINAPI) ?HMONITOR;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(WINAPI) UINT;
pub extern "user32" fn GetDpiForSystem() callconv(WINAPI) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT) callconv(WINAPI) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, BOOL, DWORD, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetCapture(HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(WINAPI) BOOL;
pub extern "user32" fn GetCapture() callconv(WINAPI) ?HWND;
pub extern "user32" fn GetForegroundWindow() callconv(WINAPI) ?HWND;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(WINAPI) DWORD;
pub extern "user32" fn IsZoomed(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetFocus(?HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn GetFocus() callconv(WINAPI) ?HWND;
pub extern "user32" fn OpenClipboard(?HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn SetClipboardData(UINT, ?HANDLE) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn GetClipboardData(UINT) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn RegisterClipboardFormatW(LPCWSTR) callconv(WINAPI) UINT;
pub extern "user32" fn SetWindowsHookExW(i32, HOOKPROC, ?HINSTANCE, DWORD) callconv(WINAPI) ?HHOOK;
pub extern "user32" fn UnhookWindowsHookEx(HHOOK) callconv(WINAPI) BOOL;
pub extern "user32" fn CallNextHookEx(?HHOOK, i32, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn SetWinEventHook(DWORD, DWORD, ?HMODULE, WINEVENTPROC, DWORD, DWORD, DWORD) callconv(WINAPI) ?HWINEVENTHOOK;
pub extern "user32" fn UnhookWinEvent(HWINEVENTHOOK) callconv(WINAPI) BOOL;
pub extern "user32" fn CreatePopupMenu() callconv(WINAPI) ?HMENU;
pub extern "user32" fn AppendMenuW(HMENU, UINT, usize, ?LPCWSTR) callconv(WINAPI) BOOL;
pub extern "user32" fn TrackPopupMenu(HMENU, UINT, i32, i32, i32, HWND, ?*const RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn DestroyMenu(HMENU) callconv(WINAPI) BOOL;
pub extern "user32" fn CreateIconIndirect(*const ICONINFO) callconv(WINAPI) ?HICON;
pub extern "user32" fn DestroyIcon(HICON) callconv(WINAPI) BOOL;
pub extern "user32" fn SystemParametersInfoW(UINT, UINT, ?*anyopaque, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn SystemParametersInfoForDpi(UINT, UINT, ?*anyopaque, UINT, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetDC(?HWND) callconv(WINAPI) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(WINAPI) i32;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn ValidateRect(?HWND, ?*const RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetSystemMetrics(i32) callconv(WINAPI) i32;
pub extern "user32" fn GetSystemMetricsForDpi(i32, UINT) callconv(WINAPI) i32;
pub extern "user32" fn GetDoubleClickTime() callconv(WINAPI) UINT;
pub extern "user32" fn SetLayeredWindowAttributes(HWND, DWORD, BYTE, DWORD) callconv(WINAPI) BOOL;
pub extern "user32" fn EnableWindow(HWND, BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn SetParent(HWND, ?HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(WINAPI) i32;
pub extern "user32" fn SetWindowRgn(HWND, ?*anyopaque, BOOL) callconv(WINAPI) i32;
pub extern "user32" fn WindowFromPoint(POINT) callconv(WINAPI) ?HWND;
pub extern "user32" fn GetAncestor(HWND, UINT) callconv(WINAPI) ?HWND;
pub extern "user32" fn RegisterWindowMessageW(LPCWSTR) callconv(WINAPI) UINT;
pub extern "user32" fn GetMessageTime() callconv(WINAPI) LONG;
pub extern "user32" fn IsWindow(?HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn GetParent(HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn PtInRect(*const RECT, POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn MonitorFromRect(*const RECT, DWORD) callconv(WINAPI) ?HMONITOR;
pub extern "user32" fn DestroyCursor(HCURSOR) callconv(WINAPI) BOOL;
pub extern "user32" fn GetClassNameW(HWND, [*]u16, i32) callconv(WINAPI) i32;
pub extern "user32" fn MapWindowPoints(?HWND, ?HWND, [*]POINT, UINT) callconv(WINAPI) i32;
pub extern "user32" fn RedrawWindow(HWND, ?*const RECT, ?*anyopaque, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetSysColor(i32) callconv(WINAPI) DWORD;
pub extern "user32" fn BringWindowToTop(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn ReplyMessage(LRESULT) callconv(WINAPI) BOOL;

pub extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(WINAPI) ?HMODULE;
pub extern "kernel32" fn GetModuleFileNameW(?HMODULE, [*]u16, DWORD) callconv(WINAPI) DWORD;
pub extern "kernel32" fn LoadLibraryW(LPCWSTR) callconv(WINAPI) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(HMODULE, [*:0]const u8) callconv(WINAPI) ?*const anyopaque;
pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(WINAPI) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetCurrentThreadId() callconv(WINAPI) DWORD;
pub extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) DWORD;
pub extern "kernel32" fn CreateEventW(?*anyopaque, manual_reset: BOOL, initial: BOOL, name: ?LPCWSTR) callconv(WINAPI) ?HANDLE;
pub extern "kernel32" fn SetEvent(HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(WINAPI) DWORD;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn Sleep(DWORD) callconv(WINAPI) void;
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(WINAPI) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(HGLOBAL) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HGLOBAL) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GlobalFree(HGLOBAL) callconv(WINAPI) ?HGLOBAL;
pub extern "kernel32" fn GlobalSize(HGLOBAL) callconv(WINAPI) usize;
pub extern "kernel32" fn OpenProcess(DWORD, BOOL, DWORD) callconv(WINAPI) ?HANDLE;
pub extern "kernel32" fn QueryFullProcessImageNameW(HANDLE, DWORD, [*]u16, *DWORD) callconv(WINAPI) BOOL;
pub extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(WINAPI) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(WINAPI) void;
pub extern "kernel32" fn SleepConditionVariableSRW(*CONDITION_VARIABLE, *SRWLOCK, DWORD, ULONG) callconv(WINAPI) BOOL;
pub extern "kernel32" fn WakeConditionVariable(*CONDITION_VARIABLE) callconv(WINAPI) void;
pub extern "kernel32" fn WakeAllConditionVariable(*CONDITION_VARIABLE) callconv(WINAPI) void;
pub extern "kernel32" fn CreateActCtxW(*const ACTCTXW) callconv(WINAPI) HANDLE;
pub extern "kernel32" fn ActivateActCtx(HANDLE, *usize) callconv(WINAPI) BOOL;
pub extern "kernel32" fn SetThreadPriority(HANDLE, i32) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetCurrentThread() callconv(WINAPI) HANDLE;
pub extern "kernel32" fn GetEnvironmentVariableW(LPCWSTR, ?[*]u16, DWORD) callconv(WINAPI) DWORD;
pub extern "kernel32" fn CreateFileW(LPCWSTR, DWORD, DWORD, ?*anyopaque, DWORD, DWORD, ?HANDLE) callconv(WINAPI) HANDLE;
pub extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, ?*DWORD, ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetFileSizeEx(HANDLE, *i64) callconv(WINAPI) BOOL;
pub extern "kernel32" fn CreateDirectoryW(LPCWSTR, ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn MoveFileExW(LPCWSTR, LPCWSTR, DWORD) callconv(WINAPI) BOOL;
pub extern "kernel32" fn DeleteFileW(LPCWSTR) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;
pub extern "kernel32" fn ResetEvent(HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetSystemDirectoryW([*]u16, UINT) callconv(WINAPI) UINT;
pub extern "kernel32" fn DeactivateActCtx(DWORD, usize) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetTickCount64() callconv(WINAPI) u64;
pub extern "kernel32" fn GetCurrentProcess() callconv(WINAPI) HANDLE;
/// FILETIMEs as u64 (100 ns units).
pub extern "kernel32" fn GetProcessTimes(HANDLE, *u64, *u64, *u64, *u64) callconv(WINAPI) BOOL;

pub extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFO, UINT, *?*anyopaque, ?HANDLE, DWORD) callconv(WINAPI) ?HBITMAP;
pub extern "gdi32" fn CreateBitmap(i32, i32, UINT, UINT, ?*const anyopaque) callconv(WINAPI) ?HBITMAP;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(WINAPI) BOOL;
pub extern "gdi32" fn GetStockObject(i32) callconv(WINAPI) ?HGDIOBJ;
pub extern "gdi32" fn CreateSolidBrush(DWORD) callconv(WINAPI) ?HBRUSH;
pub extern "gdi32" fn CreateFontIndirectW(*const LOGFONTW) callconv(WINAPI) ?HFONT;
pub extern "gdi32" fn SetBkMode(HDC, i32) callconv(WINAPI) i32;
pub extern "gdi32" fn SetTextColor(HDC, DWORD) callconv(WINAPI) DWORD;
pub extern "gdi32" fn SetBkColor(HDC, DWORD) callconv(WINAPI) DWORD;
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(WINAPI) ?HGDIOBJ;
pub extern "gdi32" fn GetTextExtentPoint32W(HDC, [*]const u16, i32, *SIZE) callconv(WINAPI) BOOL;
pub extern "gdi32" fn CreateRectRgn(i32, i32, i32, i32) callconv(WINAPI) ?*anyopaque;
pub extern "gdi32" fn CreateRoundRectRgn(i32, i32, i32, i32, i32, i32) callconv(WINAPI) ?*anyopaque;
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(WINAPI) ?HDC;
pub extern "gdi32" fn DeleteDC(HDC) callconv(WINAPI) BOOL;
pub extern "gdi32" fn BitBlt(HDC, i32, i32, i32, i32, ?HDC, i32, i32, DWORD) callconv(WINAPI) BOOL;
pub extern "gdi32" fn GetDIBits(HDC, HBITMAP, UINT, UINT, ?*anyopaque, *BITMAPINFO, UINT) callconv(WINAPI) i32;
pub const SRCCOPY: DWORD = 0x00CC0020;
pub const CAPTUREBLT: DWORD = 0x40000000;

pub extern "shell32" fn Shell_NotifyIconW(DWORD, *NOTIFYICONDATAW) callconv(WINAPI) BOOL;
pub extern "shell32" fn ShellExecuteW(?HWND, ?LPCWSTR, LPCWSTR, ?LPCWSTR, ?LPCWSTR, i32) callconv(WINAPI) ?HINSTANCE;
pub extern "shell32" fn DragQueryFileW(*anyopaque, UINT, ?[*]u16, UINT) callconv(WINAPI) UINT;
pub extern "shell32" fn DragQueryPoint(*anyopaque, *POINT) callconv(WINAPI) BOOL;
pub extern "shell32" fn DragFinish(*anyopaque) callconv(WINAPI) void;
pub extern "shell32" fn DragAcceptFiles(HWND, BOOL) callconv(WINAPI) void;

pub extern "advapi32" fn RegGetValueW(HKEY, ?LPCWSTR, ?LPCWSTR, DWORD, ?*DWORD, ?*anyopaque, ?*DWORD) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegCreateKeyExW(HKEY, LPCWSTR, DWORD, ?LPWSTR, DWORD, DWORD, ?*anyopaque, *?HKEY, ?*DWORD) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegSetValueExW(HKEY, ?LPCWSTR, DWORD, DWORD, ?[*]const u8, DWORD) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegDeleteValueW(HKEY, ?LPCWSTR) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegCloseKey(HKEY) callconv(WINAPI) LONG;

pub extern "dwmapi" fn DwmFlush() callconv(WINAPI) HRESULT;
pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(WINAPI) HRESULT;
pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(HWND, *const MARGINS) callconv(WINAPI) HRESULT;

pub extern "ole32" fn CoInitializeEx(?*anyopaque, DWORD) callconv(WINAPI) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(WINAPI) void;

pub extern "uxtheme" fn SetWindowTheme(HWND, ?LPCWSTR, ?LPCWSTR) callconv(WINAPI) HRESULT;

pub extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(WINAPI) BOOL;

pub extern "imm32" fn ImmGetContext(HWND) callconv(WINAPI) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmSetCompositionWindow(HIMC, *const COMPOSITIONFORM) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(HIMC, *const CANDIDATEFORM) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(HIMC, DWORD, ?*anyopaque, DWORD) callconv(WINAPI) LONG;

pub extern "shcore" fn GetDpiForMonitor(HMONITOR, i32, *UINT, *UINT) callconv(WINAPI) HRESULT;

pub extern "version" fn GetFileVersionInfoSizeW(LPCWSTR, ?*DWORD) callconv(WINAPI) DWORD;
pub extern "version" fn GetFileVersionInfoW(LPCWSTR, DWORD, DWORD, *anyopaque) callconv(WINAPI) BOOL;
pub extern "version" fn VerQueryValueW(*const anyopaque, LPCWSTR, *?*anyopaque, *UINT) callconv(WINAPI) BOOL;

// ---- helpers ------------------------------------------------------------------------------

pub fn loword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(@as(isize, @intCast(v)))));
}
pub fn hiword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(@as(isize, @intCast(v)))) >> 16);
}
/// GET_X_LPARAM / GET_Y_LPARAM (signed: multi-monitor coordinates can be negative).
pub fn xParam(l: LPARAM) i32 {
    return @as(i16, @bitCast(loword(l)));
}
pub fn yParam(l: LPARAM) i32 {
    return @as(i16, @bitCast(hiword(l)));
}
pub fn makeIntResource(id: usize) LPCWSTR {
    return @ptrFromInt(id);
}
pub fn hwndFromInt(v: isize) HWND {
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// UTF-8 -> NUL-terminated UTF-16 (invalid sequences become U+FFFD). Caller frees.
pub fn utf8ToWide(gpa: std.mem.Allocator, s: []const u8) ![:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len + 1);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.append(gpa, 0xFFFD);
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            try out.append(gpa, 0xFFFD);
            break;
        }
        const cp = std.unicode.utf8Decode(s[i..][0..n]) catch {
            try out.append(gpa, 0xFFFD);
            i += 1;
            continue;
        };
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try out.append(gpa, @intCast(0xD800 + (v >> 10)));
            try out.append(gpa, @intCast(0xDC00 + (v & 0x3FF)));
        } else try out.append(gpa, @intCast(cp));
        i += n;
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// Stack-buffer UTF-8 -> UTF-16 for short strings (truncates).
pub fn wideBuf(buf: []u16, s: []const u8) [:0]const u16 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            if (n + 3 > buf.len) break;
            const v = cp - 0x10000;
            buf[n] = @intCast(0xD800 + (v >> 10));
            buf[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        } else {
            if (n + 2 > buf.len) break;
            buf[n] = @intCast(cp);
            n += 1;
        }
    }
    buf[n] = 0;
    return buf[0..n :0];
}

/// UTF-16 -> UTF-8 into `out` (unpaired surrogates become U+FFFD); returns the written slice.
pub fn wideToUtf8Buf(out: []u8, w: []const u16) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < w.len) : (i += 1) {
        var cp: u21 = w[i];
        if (cp >= 0xD800 and cp < 0xDC00 and i + 1 < w.len and w[i + 1] >= 0xDC00 and w[i + 1] < 0xE000) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (w[i + 1] - 0xDC00);
            i += 1;
        } else if (cp >= 0xD800 and cp < 0xE000) cp = 0xFFFD;
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (n + len > out.len) break;
        @memcpy(out[n..][0..len], tmp[0..len]);
        n += len;
    }
    return out[0..n];
}

pub fn wideToUtf8Alloc(gpa: std.mem.Allocator, w: []const u16) ![]u8 {
    const buf = try gpa.alloc(u8, w.len * 3);
    errdefer gpa.free(buf);
    const n = wideToUtf8Buf(buf, w).len;
    return gpa.realloc(buf, n);
}

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

/// Whether environment variable `name` is set (non-empty).
pub fn hasEnv(comptime name: []const u8) bool {
    var buf: [4]u16 = undefined;
    return GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), &buf, buf.len) != 0;
}

/// Environment variable `name` as UTF-8 in `out` (null when unset or too long).
pub fn getEnv(comptime name: []const u8, out: []u8) ?[]u8 {
    var buf: [512]u16 = undefined;
    const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), &buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    return wideToUtf8Buf(out, buf[0..n]);
}

/// Whole file (at most `max` bytes) or null.
pub fn readFileAlloc(gpa: std.mem.Allocator, path: LPCWSTR, max: usize) ?[]u8 {
    const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size <= 0 or size > max) return null;
    const buf = gpa.alloc(u8, @intCast(size)) catch return null;
    var got: DWORD = 0;
    if (ReadFile(h, buf.ptr, @intCast(buf.len), &got, null) == 0 or got != buf.len) {
        gpa.free(buf);
        return null;
    }
    return buf;
}

/// Best-effort atomic write (temp file + rename), creating missing parent directories.
pub fn writeFileCreatingDirs(path: [:0]const u16, data: []const u8) void {
    var dir_buf: [1024]u16 = undefined;
    if (path.len >= dir_buf.len - 8) return;
    // Create every ancestor directory (CreateDirectoryW fails harmlessly when it exists).
    for (path, 0..) |ch, i| if (ch == '\\' and i > 2) {
        @memcpy(dir_buf[0..i], path[0..i]);
        dir_buf[i] = 0;
        _ = CreateDirectoryW(dir_buf[0..i :0], null);
    };
    @memcpy(dir_buf[0..path.len], path);
    for (std.unicode.utf8ToUtf16LeStringLiteral(".tmp"), 0..) |ch, i| dir_buf[path.len + i] = ch;
    dir_buf[path.len + 4] = 0;
    const tmp = dir_buf[0 .. path.len + 4 :0];
    const h = CreateFileW(tmp, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE_VALUE) return;
    var put: DWORD = 0;
    const ok = WriteFile(h, data.ptr, @intCast(data.len), &put, null) != 0 and put == data.len;
    _ = CloseHandle(h);
    if (!ok or MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING) == 0) _ = DeleteFileW(tmp);
}

// ---- COM ----------------------------------------------------------------------------------

pub const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");

/// The three IUnknown slots every COM vtable starts with.
pub fn IUnknownMethods(comptime Self: type) type {
    return extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (*Self) callconv(WINAPI) ULONG,
        Release: *const fn (*Self) callconv(WINAPI) ULONG,
    };
}

pub const IUnknown = extern struct {
    vtbl: *const IUnknownMethods(IUnknown),
};

/// Release a COM object (any interface whose vtable starts with IUnknown).
pub fn release(obj: anytype) void {
    const T = @TypeOf(obj);
    switch (@typeInfo(T)) {
        .optional => if (obj) |o| release(o),
        else => {
            const unk: *IUnknown = @ptrCast(obj);
            _ = unk.vtbl.Release(unk);
        },
    }
}

/// Release and null out a `?*Interface` field.
pub fn releaseOpt(p: anytype) void {
    if (p.*) |o| release(o);
    p.* = null;
}

pub fn queryInterface(obj: anytype, comptime T: type) ?*T {
    const unk: *IUnknown = @ptrCast(obj);
    var out: ?*anyopaque = null;
    if (unk.vtbl.QueryInterface(unk, &T.iid, &out) < 0) return null;
    return @ptrCast(@alignCast(out));
}

/// `QueryInterface` for an explicit IID (newer interface revisions sharing one vtable type).
pub fn queryInterfaceIid(obj: anytype, iid: *const GUID, comptime T: type) ?*T {
    const unk: *IUnknown = @ptrCast(obj);
    var out: ?*anyopaque = null;
    if (unk.vtbl.QueryInterface(unk, iid, &out) < 0) return null;
    return @ptrCast(@alignCast(out));
}

/// A vtable slot zpui never calls.
pub const Unused = *const anyopaque;

// ---- DirectComposition --------------------------------------------------------------------

pub const IDCompositionDevice = extern struct {
    vtbl: *const VTable,
    pub const iid = GUID.parse("c37ea93a-e7aa-450d-b16f-9746cb0407f3");
    pub const VTable = extern struct {
        base: IUnknownMethods(IDCompositionDevice),
        Commit: *const fn (*IDCompositionDevice) callconv(WINAPI) HRESULT,
        WaitForCommitCompletion: Unused,
        GetFrameStatistics: Unused,
        CreateTargetForHwnd: *const fn (*IDCompositionDevice, HWND, BOOL, *?*IDCompositionTarget) callconv(WINAPI) HRESULT,
        CreateVisual: *const fn (*IDCompositionDevice, *?*IDCompositionVisual) callconv(WINAPI) HRESULT,
        // ... further factory methods unused
    };
    pub fn commit(self: *IDCompositionDevice) HRESULT {
        return self.vtbl.Commit(self);
    }
};

pub const IDCompositionTarget = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        base: IUnknownMethods(IDCompositionTarget),
        SetRoot: *const fn (*IDCompositionTarget, ?*IDCompositionVisual) callconv(WINAPI) HRESULT,
    };
};

pub const IDCompositionVisual = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        base: IUnknownMethods(IDCompositionVisual),
        SetOffsetX_anim: Unused,
        SetOffsetX: Unused,
        SetOffsetY_anim: Unused,
        SetOffsetY: Unused,
        SetTransform_anim: Unused,
        SetTransform: Unused,
        SetTransformParent: Unused,
        SetEffect: Unused,
        SetBitmapInterpolationMode: Unused,
        SetBorderMode: Unused,
        SetClip_anim: Unused,
        SetClip: Unused,
        SetContent: *const fn (*IDCompositionVisual, ?*IUnknown) callconv(WINAPI) HRESULT,
    };
};

pub extern "dcomp" fn DCompositionCreateDevice(dxgi_device: ?*IUnknown, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT;
