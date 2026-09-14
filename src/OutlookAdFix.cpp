// OutlookAdFix - provider AppVerifier per olk.exe
// 1) aggancia CreateCoreWebView2EnvironmentWithOptions (IAT di nh.dll)
// 2) incatena i vtable degli handler WebView2 fino al controller
// 3) inietta il payload JS/CSS letto da %LOCALAPPDATA%\Remove-OutlookAds\inject.js
#include <windows.h>
#include <tlhelp32.h>
#include <wrl.h>
#include <string>
#include "WebView2.h"

using namespace Microsoft::WRL;

// ------------------------------------------------------------------ log
static void LogLine(const wchar_t* text) {
    wchar_t path[MAX_PATH] = {0};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", path, MAX_PATH)) return;
    lstrcatW(path, L"\\Remove-OutlookAds\\adfix.log");
    HANDLE h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    SetFilePointer(h, 0, NULL, FILE_END);
    WriteFile(h, text, (DWORD)(lstrlenW(text) * sizeof(wchar_t)), &written, NULL);
    WriteFile(h, L"\r\n", 4, &written, NULL);
    CloseHandle(h);
}

// ------------------------------------------------------------------ payload
static std::wstring LoadPayload(void) {
    wchar_t path[MAX_PATH] = {0};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", path, MAX_PATH)) return L"";
    lstrcatW(path, L"\\Remove-OutlookAds\\inject.js");
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { LogLine(L"inject.js non trovato"); return L""; }
    DWORD size = GetFileSize(h, NULL);
    if (size == INVALID_FILE_SIZE || size == 0 || size > 512 * 1024) { CloseHandle(h); return L""; }
    char* buf = (char*)LocalAlloc(LPTR, size + 1);
    if (!buf) { CloseHandle(h); return L""; }
    DWORD read = 0;
    ReadFile(h, buf, size, &read, NULL);
    CloseHandle(h);
    buf[read] = 0;
    int wlen = MultiByteToWideChar(CP_UTF8, 0, buf, -1, NULL, 0);
    std::wstring out;
    if (wlen > 0) {
        wchar_t* w = (wchar_t*)LocalAlloc(LPTR, (SIZE_T)wlen * sizeof(wchar_t));
        if (w) { MultiByteToWideChar(CP_UTF8, 0, buf, -1, w, wlen); out = w; LocalFree(w); }
    }
    LocalFree(buf);
    return out;
}

// ------------------------------------------------------------------ IAT
static bool PatchIAT(HMODULE hMod, const char* libName, const char* funcName, void* newFunc, void** oldFunc) {
    if (!hMod) return false;
    BYTE* base = (BYTE*)hMod;
    IMAGE_DOS_HEADER* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    IMAGE_NT_HEADERS* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return false;
    DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!rva) return false;
    IMAGE_IMPORT_DESCRIPTOR* imp = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + rva);
    for (; imp->Name; ++imp) {
        const char* dll = (const char*)(base + imp->Name);
        if (_stricmp(dll, libName) != 0) continue;
        if (!imp->OriginalFirstThunk) continue;
        IMAGE_THUNK_DATA* oft = reinterpret_cast<IMAGE_THUNK_DATA*>(base + imp->OriginalFirstThunk);
        IMAGE_THUNK_DATA* ft = reinterpret_cast<IMAGE_THUNK_DATA*>(base + imp->FirstThunk);
        for (; oft->u1.Function; ++oft, ++ft) {
            if (oft->u1.Ordinal & IMAGE_ORDINAL_FLAG) continue;
            IMAGE_IMPORT_BY_NAME* ibn = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + oft->u1.AddressOfData);
            if (strcmp((const char*)ibn->Name, funcName) != 0) continue;
            DWORD oldProt = 0;
            if (!VirtualProtect(&ft->u1.Function, sizeof(void*), PAGE_READWRITE, &oldProt)) return false;
            if (oldFunc && !*oldFunc) *oldFunc = (void*)ft->u1.Function;
            ft->u1.Function = (ULONG_PTR)newFunc;
            VirtualProtect(&ft->u1.Function, sizeof(void*), oldProt, &oldProt);
            return true;
        }
    }
    return false;
}

static bool PatchVtbl(void** vtbl, int index, void* newFunc, void** oldFunc) {
    if (!vtbl) return false;
    DWORD oldProt = 0;
    if (!VirtualProtect(&vtbl[index], sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProt)) return false;
    if (oldFunc && !*oldFunc) *oldFunc = vtbl[index];
    vtbl[index] = newFunc;
    VirtualProtect(&vtbl[index], sizeof(void*), oldProt, &oldProt);
    return true;
}

// ------------------------------------------------------------------ hook
typedef HRESULT(STDMETHODCALLTYPE* PFN_InvokeEnv)(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*, HRESULT, ICoreWebView2Environment*);
typedef HRESULT(STDMETHODCALLTYPE* PFN_CreateCtrl)(ICoreWebView2Environment*, HWND, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*);
typedef HRESULT(STDMETHODCALLTYPE* PFN_InvokeCtrl)(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*, HRESULT, ICoreWebView2Controller*);
typedef HRESULT(STDAPICALLTYPE* PFN_CreateEnv)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);

static PFN_InvokeEnv  g_origInvokeEnv = NULL;
static PFN_CreateCtrl g_origCreateCtrl = NULL;
static PFN_InvokeCtrl g_origInvokeCtrl = NULL;
static PFN_CreateEnv  g_origCreateEnv = NULL;
static volatile LONG  g_injected = 0;

static HRESULT STDMETHODCALLTYPE Hook_InvokeCtrl(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* _this, HRESULT hr, ICoreWebView2Controller* controller);

static HRESULT STDMETHODCALLTYPE Hook_CreateCtrl(ICoreWebView2Environment* env, HWND hwnd, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* handler) {
    if (handler) {
        void** vt = *(void***)handler;
        if (vt && vt[3] != (void*)Hook_InvokeCtrl) {
            if (PatchVtbl(vt, 3, (void*)Hook_InvokeCtrl, (void**)&g_origInvokeCtrl)) { LogLine(L"hook: controller handler agganciato"); }
        }
    }
    if (!g_origCreateCtrl) return E_FAIL;
    return g_origCreateCtrl(env, hwnd, handler);
}

static HRESULT STDMETHODCALLTYPE Hook_InvokeCtrl(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* _this, HRESULT hr, ICoreWebView2Controller* controller) {
    if (SUCCEEDED(hr) && controller) {
        ComPtr<ICoreWebView2> webview;
        if (SUCCEEDED(controller->get_CoreWebView2(&webview)) && webview) {
            if (InterlockedIncrement(&g_injected) <= 8) {
                std::wstring js = LoadPayload();
                if (!js.empty()) {
                    HRESULT a = webview->AddScriptToExecuteOnDocumentCreated(js.c_str(), NULL);
                    HRESULT b = webview->ExecuteScript(js.c_str(), NULL);
                    LogLine(a == S_OK ? L"iniezione: AddScriptToExecuteOnDocumentCreated OK" : L"iniezione: AddScriptToExecuteOnDocumentCreated FALLITA");
                    LogLine(b == S_OK ? L"iniezione: ExecuteScript OK" : L"iniezione: ExecuteScript FALLITA");
                }
            }
        }
    }
    if (!g_origInvokeCtrl) return S_OK;
    return g_origInvokeCtrl(_this, hr, controller);
}

static HRESULT STDMETHODCALLTYPE Hook_InvokeEnv(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* _this, HRESULT hr, ICoreWebView2Environment* env) {
    if (SUCCEEDED(hr) && env) {
        void** vt = *(void***)env;
        if (vt && vt[3] != (void*)Hook_CreateCtrl) {
            if (PatchVtbl(vt, 3, (void*)Hook_CreateCtrl, (void**)&g_origCreateCtrl)) { LogLine(L"hook: environment agganciato"); }
        }
    }
    if (!g_origInvokeEnv) return S_OK;
    return g_origInvokeEnv(_this, hr, env);
}

static HRESULT STDAPICALLTYPE Hook_CreateEnv(PCWSTR browserFolder, PCWSTR userDataFolder, ICoreWebView2EnvironmentOptions* options,
                                             ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* handler) {
    if (!g_origCreateEnv) {
        HMODULE h = GetModuleHandleW(L"WebView2Loader.dll");
        if (h) g_origCreateEnv = (PFN_CreateEnv)GetProcAddress(h, "CreateCoreWebView2EnvironmentWithOptions");
    }
    if (handler) {
        void** vt = *(void***)handler;
        if (vt && vt[3] != (void*)Hook_InvokeEnv) {
            if (PatchVtbl(vt, 3, (void*)Hook_InvokeEnv, (void**)&g_origInvokeEnv)) { LogLine(L"hook: environment handler agganciato"); }
        }
    }
    if (!g_origCreateEnv) { LogLine(L"hook: funzione originale non trovata"); return E_FAIL; }
    return g_origCreateEnv(browserFolder, userDataFolder, options, handler);
}

// ------------------------------------------------------------------ thread
static bool PatchAllModules(void) {
    bool any = false;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
    if (snap == INVALID_HANDLE_VALUE) return false;
    MODULEENTRY32W me;
    ZeroMemory(&me, sizeof(me));
    me.dwSize = sizeof(me);
    if (Module32FirstW(snap, &me)) {
        do {
            if (PatchIAT(me.hModule, "WebView2Loader.dll", "CreateCoreWebView2EnvironmentWithOptions",
                         (void*)Hook_CreateEnv, (void**)&g_origCreateEnv)) {
                any = true;
            }
        } while (Module32NextW(snap, &me));
    }
    CloseHandle(snap);
    return any;
}

static DWORD WINAPI Worker(LPVOID) {
    for (int i = 0; i < 240; i++) {
        if (PatchAllModules()) {
            LogLine(L"IAT agganciata (CreateCoreWebView2EnvironmentWithOptions)");
            return 0;
        }
        Sleep(250);
    }
    LogLine(L"IAT NON agganciata: import non trovato");
    return 0;
}

// ------------------------------------------------------------------ AppVerifier
typedef struct _RTL_VERIFIER_THUNK_DESCRIPTOR {
    PCHAR ThunkName;
    PVOID ThunkOldAddress;
    PVOID ThunkNewAddress;
} RTL_VERIFIER_THUNK_DESCRIPTOR, *PRTL_VERIFIER_THUNK_DESCRIPTOR;

typedef struct _RTL_VERIFIER_DLL_DESCRIPTOR {
    PWCHAR DllName;
    ULONG  DllFlags;
    PVOID  DllAddress;
    PRTL_VERIFIER_THUNK_DESCRIPTOR DllThunks;
} RTL_VERIFIER_DLL_DESCRIPTOR, *PRTL_VERIFIER_DLL_DESCRIPTOR;

typedef void (NTAPI* RTL_VERIFIER_DLL_LOAD_CALLBACK)(PWSTR, PVOID, SIZE_T, PVOID);
typedef void (NTAPI* RTL_VERIFIER_DLL_UNLOAD_CALLBACK)(PWSTR, PVOID, SIZE_T, PVOID);
typedef void (NTAPI* RTL_VERIFIER_NTDLLHEAPFREE_CALLBACK)(PVOID, SIZE_T);

typedef struct _RTL_VERIFIER_PROVIDER_DESCRIPTOR {
    ULONG Length;
    PRTL_VERIFIER_DLL_DESCRIPTOR ProviderDlls;
    RTL_VERIFIER_DLL_LOAD_CALLBACK ProviderDllLoadCallback;
    RTL_VERIFIER_DLL_UNLOAD_CALLBACK ProviderDllUnloadCallback;
    PWSTR VerifierImage;
    ULONG VerifierFlags;
    ULONG VerifierDebug;
    PVOID RtlpGetStackTraceAddress;
    PVOID RtlpDebugPageHeapCreate;
    PVOID RtlpDebugPageHeapDestroy;
    RTL_VERIFIER_NTDLLHEAPFREE_CALLBACK ProviderNtdllHeapFreeCallback;
} RTL_VERIFIER_PROVIDER_DESCRIPTOR, *PRTL_VERIFIER_PROVIDER_DESCRIPTOR;

#ifndef DLL_PROCESS_VERIFIER
#define DLL_PROCESS_VERIFIER 4
#endif

static RTL_VERIFIER_DLL_DESCRIPTOR g_noHooks = {0};
static RTL_VERIFIER_PROVIDER_DESCRIPTOR g_desc = {
    sizeof(RTL_VERIFIER_PROVIDER_DESCRIPTOR),
    &g_noHooks,
    [](PWSTR, PVOID, SIZE_T, PVOID) {},
    [](PWSTR, PVOID, SIZE_T, PVOID) {},
    NULL, 0, 0,
    NULL, NULL, NULL,
    [](PVOID, SIZE_T) {}
};

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    switch (fdwReason) {
    case DLL_PROCESS_ATTACH: {
        ::DisableThreadLibraryCalls(hinstDLL);
        LogLine(L"=== OutlookAdFix caricata ===");
        HANDLE t = ::CreateThread(NULL, 0, Worker, NULL, 0, NULL);
        if (t) ::CloseHandle(t);
        break;
    }
    case DLL_PROCESS_VERIFIER:
        if (lpvReserved) { *(PVOID*)lpvReserved = &g_desc; }
        break;
    default:
        break;
    }
    return TRUE;
}
