#ifndef SC_LAUNCHER_STOP_H
#define SC_LAUNCHER_STOP_H

#include "common.h"

#include <stdbool.h>
#ifdef _WIN32
# include <windows.h>
# include "thread.h"
#endif

struct sc_launcher_stop {
#ifdef _WIN32
    HANDLE requested;
    HANDLE cancelled;
    sc_thread thread;
#endif
    bool started;
};

// Observe an optional launcher-owned stop event after SDL events are initialized.
bool
sc_launcher_stop_init(struct sc_launcher_stop *stop);

// Cancel and join the observer before destroying the SDL event subsystem.
void
sc_launcher_stop_destroy(struct sc_launcher_stop *stop);

#endif
