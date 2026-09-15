#include "common.h"

#include <assert.h>
#include <limits.h>
#include <stddef.h>
#include <SDL3/SDL_init.h>
#include <SDL3/SDL_mutex.h>

#include "util/thread.h"

/* Exercise the production implementation with deterministic clock/wait inputs.
 * Include SDL headers first so the substitutions do not alter SDL declarations.
 * All other thread operations retain their real SDL implementation. */
static sc_tick test_tick_now(void);
static bool test_wait_timeout(SDL_Condition *condition, SDL_Mutex *mutex,
                              Sint32 timeout_ms);

#define sc_tick_now test_tick_now
#define SDL_WaitConditionTimeout test_wait_timeout
#include "../src/util/thread.c"
#undef SDL_WaitConditionTimeout
#undef sc_tick_now

struct wait_step {
    Sint32 timeout_ms;
    sc_tick elapsed;
    bool signaled;
};

static sc_tick current_tick;
static const struct wait_step *wait_steps;
static size_t wait_step_count;
static size_t wait_step_index;
static sc_mutex test_mutex;
static sc_cond test_condition;

/* Check that each retry has restored the mutex owner before reading time. */
static sc_tick
test_tick_now(void) {
    assert(sc_mutex_held(&test_mutex));
    return current_tick;
}

/* Simulate another thread owning the released mutex before SDL reacquires it. */
static bool
test_wait_timeout(SDL_Condition *condition, SDL_Mutex *mutex, Sint32 timeout_ms) {
    assert(condition == test_condition.cond);
    assert(mutex == test_mutex.mutex);
    assert(sc_mutex_held(&test_mutex));
    assert(wait_step_index < wait_step_count);

    const struct wait_step *step = &wait_steps[wait_step_index++];
    assert(timeout_ms == step->timeout_ms);
    assert(timeout_ms > 0);
    current_tick += step->elapsed;
    atomic_store_explicit(&test_mutex.locker, 0, memory_order_relaxed);
    return step->signaled;
}

/* Run a scripted wait and verify both the result and lock bookkeeping. */
static void
check_wait(sc_tick remaining, const struct wait_step *steps, size_t step_count,
           bool expected_signaled) {
    current_tick = SC_TICK_FROM_SEC(1);
    wait_steps = steps;
    wait_step_count = step_count;
    wait_step_index = 0;
    atomic_init(&test_mutex.locker, sc_thread_get_id());

    bool signaled = sc_cond_timedwait(&test_condition, &test_mutex,
                                     current_tick + remaining);
    assert(signaled == expected_signaled);
    assert(wait_step_index == step_count);
    assert(sc_mutex_held(&test_mutex));
}

/* Early SDL timeouts must retry, rounding any fractional millisecond upwards. */
static void
test_early_timeouts(void) {
    const struct wait_step steps[] = {
        {3, SC_TICK_FROM_US(600), false},
        {2, SC_TICK_FROM_US(1000), false},
        {1, SC_TICK_FROM_US(901), false},
    };
    check_wait(SC_TICK_FROM_US(2501), steps, ARRAY_LEN(steps), false);
}

/* A signal returns immediately, including after a premature timeout. */
static void
test_signals(void) {
    const struct wait_step immediate[] = {
        {2, 0, true},
    };
    check_wait(SC_TICK_FROM_MS(2), immediate, ARRAY_LEN(immediate), true);

    const struct wait_step retried[] = {
        {2, SC_TICK_FROM_US(500), false},
        {2, SC_TICK_FROM_US(500), true},
    };
    check_wait(SC_TICK_FROM_MS(2), retried, ARRAY_LEN(retried), true);
}

/* Already expired deadlines must not release the mutex or call SDL. */
static void
test_expired_deadlines(void) {
    check_wait(0, NULL, 0, false);
    check_wait(-SC_TICK_FROM_US(1), NULL, 0, false);
}

/* Sub-millisecond waits remain positive and can expire after oversleeping. */
static void
test_submillisecond_deadline(void) {
    const struct wait_step steps[] = {
        {1, SC_TICK_FROM_US(2), false},
    };
    check_wait(SC_TICK_FROM_US(1), steps, ARRAY_LEN(steps), false);
}

/* Long waits must not overflow SDL's signed timeout into an infinite wait. */
static void
test_timeout_clamping(void) {
    const struct wait_step steps[] = {
        {INT32_MAX, SC_TICK_FROM_MS(INT32_MAX), false},
        {1, SC_TICK_FROM_US(1), false},
    };
    check_wait(SC_TICK_FROM_MS(INT32_MAX) + SC_TICK_FROM_US(1), steps, ARRAY_LEN(steps), false);
}

/* Keep this test in a debug build, matching scrcpy's assertion-based suite. */
int
main(void) {
    test_early_timeouts();
    test_signals();
    test_expired_deadlines();
    test_submillisecond_deadline();
    test_timeout_clamping();
    return 0;
}
