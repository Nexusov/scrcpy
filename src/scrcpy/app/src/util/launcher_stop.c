#include "launcher_stop.h"

#ifdef _WIN32
# include <SDL3/SDL_events.h>
# include "events.h"
# include "log.h"

// Translate the owning launcher's request into the normal native quit path.
static int
sc_launcher_stop_wait(void *userdata) {
    struct sc_launcher_stop *stop = userdata;
    HANDLE events[] = {stop->cancelled, stop->requested};
    DWORD result = WaitForMultipleObjects(2, events, FALSE, INFINITE);

    if (result == WAIT_OBJECT_0 + 1) {
        sc_push_event(SDL_EVENT_QUIT);
    } else if (result == WAIT_FAILED) {
        LOGE("Could not wait for launcher stop event: %lu", GetLastError());
    }

    return 0;
}
#endif

// Standalone and non-Windows clients do not create a stop observer.
bool
sc_launcher_stop_init(struct sc_launcher_stop *stop) {
    stop->started = false;
#ifdef _WIN32
    enum { capacity = 128 };
    wchar_t name[capacity];
    DWORD length = GetEnvironmentVariableW(L"SCRCPY_STOP_EVENT", name, capacity);

    if (!length) {
        return true;
    }

    if (length >= capacity) {
        LOGE("Launcher stop event name is too long");
        return false;
    }

    stop->requested = OpenEventW(SYNCHRONIZE, FALSE, name);

    if (!stop->requested) {
        LOGE("Could not open launcher stop event: %lu", GetLastError());
        return false;
    }

    stop->cancelled = CreateEventW(NULL, TRUE, FALSE, NULL);

    if (!stop->cancelled) {
        LOGE("Could not create launcher cancellation event: %lu", GetLastError());
        CloseHandle(stop->requested);
        return false;
    }

    if (!sc_thread_create(&stop->thread, sc_launcher_stop_wait,
                          "launcher-stop", stop)) {
        CloseHandle(stop->cancelled);
        CloseHandle(stop->requested);
        return false;
    }

    stop->started = true;
#endif
    return true;
}

// Release only this observer's handles; the launcher owns the named event.
void
sc_launcher_stop_destroy(struct sc_launcher_stop *stop) {
#ifdef _WIN32
    if (stop->started) {
        SetEvent(stop->cancelled);
        sc_thread_join(&stop->thread, NULL);
        CloseHandle(stop->cancelled);
        CloseHandle(stop->requested);
        stop->started = false;
    }
#else
    (void) stop;
#endif
}
