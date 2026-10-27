/* Dungeons for Mac: stand-in for Steam's steamwebhelper.exe.
 *
 * Steam's interface is Chromium (CEF). Its compositor normally runs in a separate
 * GPU process; under Wine on macOS that process can crash, after which Chromium
 * falls back to a software path that never reaches the window: Steam's window stays
 * black. Started as the browser (no --type= switch), this runs the real helper,
 * renamed steamwebhelper_real.exe, with the compositor and rendering in its own
 * process. Chromium starts its children from the real helper's path, so they never
 * pass through here; a --type= launch is passed on unchanged anyway.
 *
 * x86_64-w64-mingw32-gcc -O2 -municode -mwindows -s -o steamwebhelper.exe webhelper-wrapper.c
 */
#include <windows.h>
#include <wchar.h>

static const wchar_t MARK[] = L"DFM-STEAMWEBHELPER-WRAPPER-1";
static const wchar_t FLAGS[] = L" --disable-gpu --disable-gpu-compositing --in-process-gpu --single-process";

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR args, int show)
{
    wchar_t self[MAX_PATH], real[MAX_PATH], *slash, *cmd, *orig, *rest;
    size_t n;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    int child;

    (void)inst; (void)prev; (void)args; (void)show; (void)MARK;
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) return 1;
    wcscpy(real, self);
    slash = wcsrchr(real, L'\\');
    if (!slash) return 1;
    wcscpy(slash + 1, L"steamwebhelper_real.exe");

    /* the arguments after our own program name, as Steam wrote them */
    orig = GetCommandLineW();
    rest = orig;
    if (*rest == L'"') { rest++; while (*rest && *rest != L'"') rest++; if (*rest) rest++; }
    else { while (*rest && *rest != L' ' && *rest != L'\t') rest++; }

    child = wcsstr(rest, L"--type=") != NULL;
    n = wcslen(real) + wcslen(rest) + wcslen(FLAGS) + 8;
    cmd = HeapAlloc(GetProcessHeap(), 0, n * sizeof(wchar_t));
    if (!cmd) return 1;
    wcscpy(cmd, L"\""); wcscat(cmd, real); wcscat(cmd, L"\"");
    wcscat(cmd, rest);
    if (!child) wcscat(cmd, FLAGS);

    ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
    GetStartupInfoW(&si);
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessW(real, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return (int)code;
}
