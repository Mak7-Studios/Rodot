#include <windows.h>
#include <wincred.h>
#include <cstdio>
#include <cwchar>
#include <cstring>
#include <string>

static bool valid_scope(const wchar_t* scope) {
    if (std::wcslen(scope) != 64) return false;
    for (const wchar_t* p = scope; *p; ++p) {
        if (!(*p >= L'0' && *p <= L'9') && !(*p >= L'a' && *p <= L'f')) return false;
    }
    return true;
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 3 || !valid_scope(argv[2])) return 1;
    const std::wstring target = L"Rodot:Supabase:" + std::wstring(argv[2]);
    if (std::wcscmp(argv[1], L"read") == 0) {
        PCREDENTIALW entry = nullptr;
        if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &entry)) {
            std::puts(GetLastError() == ERROR_NOT_FOUND ? "missing" : "error");
            return 0;
        }
        std::printf("ok:%.*s\n", static_cast<int>(entry->CredentialBlobSize), reinterpret_cast<const char*>(entry->CredentialBlob));
        SecureZeroMemory(entry->CredentialBlob, entry->CredentialBlobSize);
        CredFree(entry);
        return 0;
    }
    if (std::wcscmp(argv[1], L"write") == 0) {
        char key[CRED_MAX_CREDENTIAL_BLOB_SIZE + 3] = {};
        if (!std::fgets(key, sizeof(key), stdin)) return 1;
        const size_t length = std::strcspn(key, "\r\n");
        CREDENTIALW entry = {};
        entry.Type = CRED_TYPE_GENERIC;
        entry.TargetName = const_cast<wchar_t*>(target.c_str());
        entry.CredentialBlobSize = static_cast<DWORD>(length);
        entry.CredentialBlob = reinterpret_cast<LPBYTE>(key);
        entry.Persist = CRED_PERSIST_LOCAL_MACHINE;
        const bool written = length > 0 && length <= 2048 && key[length] != '\0' && CredWriteW(&entry, 0);
        SecureZeroMemory(key, sizeof(key));
        std::puts(written ? "ok" : "error");
        return 0;
    }
    if (std::wcscmp(argv[1], L"forget") == 0) {
        const bool deleted = CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND;
        std::puts(deleted ? "ok" : "error");
        return 0;
    }
    return 1;
}
