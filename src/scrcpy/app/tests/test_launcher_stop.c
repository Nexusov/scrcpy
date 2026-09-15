#include <assert.h>
#include <wchar.h>
#include <SDL3/SDL.h>
#include "util/launcher_stop.h"

// Exercise real Windows events and the production SDL quit bridge.
int
main(void) {
    assert(SDL_Init(SDL_INIT_EVENTS));
    struct sc_launcher_stop stop;
#ifdef _WIN32
    assert(SetEnvironmentVariableW(L"SCRCPY_STOP_EVENT", NULL));
    assert(sc_launcher_stop_init(&stop));
    assert(!stop.started);
    sc_launcher_stop_destroy(&stop);

    wchar_t name[128];
    swprintf(name, 128, L"Local\\scrcpy-stop-test-%lu", GetCurrentProcessId());
    HANDLE requested = CreateEventW(NULL, TRUE, FALSE, name);
    assert(requested);
    assert(SetEnvironmentVariableW(L"SCRCPY_STOP_EVENT", name));
    assert(sc_launcher_stop_init(&stop));
    assert(stop.started);
    assert(SetEvent(requested));
    SDL_Event event;
    assert(SDL_WaitEventTimeout(&event, 3000));
    assert(event.type == SDL_EVENT_QUIT);
    sc_launcher_stop_destroy(&stop);
    assert(!stop.started);

    // Cancellation must wake and join a monitor even when no stop was requested.
    assert(ResetEvent(requested));
    assert(sc_launcher_stop_init(&stop));
    sc_launcher_stop_destroy(&stop);
    assert(!SDL_PollEvent(&event));
    CloseHandle(requested);

    // An invalid inherited event must fail explicitly rather than silently ignore Stop.
    assert(!sc_launcher_stop_init(&stop));
    assert(SetEnvironmentVariableW(L"SCRCPY_STOP_EVENT", NULL));
#else
    assert(sc_launcher_stop_init(&stop));
    sc_launcher_stop_destroy(&stop);
#endif
    SDL_Quit();
    return 0;
}
