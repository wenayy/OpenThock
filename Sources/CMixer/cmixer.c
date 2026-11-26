#include "cmixer.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static inline float clampf_(float x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }

#define MAX_SAMPLES 4096
#define MAX_VOICES 96
#define QUEUE_SIZE 512 /* power of two */

enum { SLOT_FREE = 0, SLOT_LIVE = 1, SLOT_RETIRING = 2, SLOT_RELEASED = 3 };

typedef struct {
    float *left;
    float *right; /* == left for mono */
    uint32_t frames;
    double sampleRate;
    _Atomic int state;
} slot_t;

typedef struct {
    int active;
    int32_t sample;
    double pos;
    double step;
    float gainL, gainR;
    float delayL, delayR;
    float coefL, coefR; /* one-pole low-pass coefficients */
    float zL, zR;
    uint64_t age;
} voice_t;

static slot_t slots[MAX_SAMPLES];
static voice_t voices[MAX_VOICES];
static cm_trigger_t queue[QUEUE_SIZE];
static _Atomic uint32_t queueHead; /* written by producer */
static _Atomic uint32_t queueTail; /* written by consumer */
static _Atomic double outputRate = 48000.0;
static _Atomic float masterTarget = 1.0f;
static _Atomic int stopAllRequested;
static _Atomic int32_t activeVoices;
static float masterCurrent = 1.0f;
static _Atomic float softnessTarget = 0.0f;
static float softnessApplied = -1.0f;
static double softnessRate = 0.0;
static float lpB0 = 1, lpB1 = 0, lpB2 = 0, lpA1 = 0, lpA2 = 0;
static float lpZ[2][2];
static uint64_t voiceClock;

int32_t cm_sample_add(const float *left, const float *right, uint32_t frames, double sampleRate) {
    if (!left || frames < 2 || sampleRate <= 0) return -1;
    for (int32_t i = 0; i < MAX_SAMPLES; i++) {
        slot_t *s = &slots[i];
        if (atomic_load_explicit(&s->state, memory_order_acquire) != SLOT_FREE) continue;
        float *l = malloc(sizeof(float) * frames);
        if (!l) return -1;
        memcpy(l, left, sizeof(float) * frames);
        float *r = l;
        if (right) {
            r = malloc(sizeof(float) * frames);
            if (!r) { free(l); return -1; }
            memcpy(r, right, sizeof(float) * frames);
        }
        s->left = l;
        s->right = r;
        s->frames = frames;
        s->sampleRate = sampleRate;
        atomic_store_explicit(&s->state, SLOT_LIVE, memory_order_release);
        return i;
    }
    return -1;
}

void cm_sample_retire(int32_t sample) {
    if (sample < 0 || sample >= MAX_SAMPLES) return;
    int expected = SLOT_LIVE;
    atomic_compare_exchange_strong(&slots[sample].state, &expected, SLOT_RETIRING);
}

void cm_collect(void) {
    for (int32_t i = 0; i < MAX_SAMPLES; i++) {
        slot_t *s = &slots[i];
        if (atomic_load_explicit(&s->state, memory_order_acquire) != SLOT_RELEASED) continue;
        if (s->right != s->left) free(s->right);
        free(s->left);
        s->left = s->right = NULL;
        s->frames = 0;
        atomic_store_explicit(&s->state, SLOT_FREE, memory_order_release);
    }
}

void cm_set_output_rate(double sampleRate) {
    if (sampleRate > 0) atomic_store(&outputRate, sampleRate);
}

void cm_set_master_gain(float gain) { atomic_store(&masterTarget, gain); }

void cm_set_softness(float softness) { atomic_store(&softnessTarget, clampf_(softness)); }

/* Softness 0 leaves the sound alone; 1 rolls the top end off from about 3 kHz. */
static void update_lowpass(double outRate) {
    float s = atomic_load(&softnessTarget);
    if (s == softnessApplied && outRate == softnessRate) return;
    softnessApplied = s;
    softnessRate = outRate;
    if (s <= 0.001f) { lpB0 = 1; lpB1 = lpB2 = lpA1 = lpA2 = 0; return; }
    double cutoff = 18000.0 * pow(3000.0 / 18000.0, s);
    if (cutoff > outRate * 0.45) cutoff = outRate * 0.45;
    double w = 2.0 * M_PI * cutoff / outRate, cw = cos(w), alpha = sin(w) / (2.0 * 0.7071);
    double a0 = 1.0 + alpha;
    lpB0 = (float)((1.0 - cw) / 2.0 / a0);
    lpB1 = (float)((1.0 - cw) / a0);
    lpB2 = lpB0;
    lpA1 = (float)(-2.0 * cw / a0);
    lpA2 = (float)((1.0 - alpha) / a0);
}

void cm_stop_all(void) { atomic_store(&stopAllRequested, 1); }

void cm_trigger(const cm_trigger_t *trigger) {
    uint32_t head = atomic_load_explicit(&queueHead, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&queueTail, memory_order_acquire);
    if (head - tail >= QUEUE_SIZE) return; /* full: drop rather than block */
    queue[head & (QUEUE_SIZE - 1)] = *trigger;
    atomic_store_explicit(&queueHead, head + 1, memory_order_release);
}

int32_t cm_active_voices(void) { return atomic_load(&activeVoices); }

static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

static void start_voice(const cm_trigger_t *t, double outRate) {
    if (t->sample < 0 || t->sample >= MAX_SAMPLES) return;
    slot_t *s = &slots[t->sample];
    if (atomic_load_explicit(&s->state, memory_order_acquire) != SLOT_LIVE) return;

    voice_t *v = NULL;
    for (int i = 0; i < MAX_VOICES; i++) {
        if (!voices[i].active) { v = &voices[i]; break; }
    }
    if (!v) { /* steal the oldest voice */
        v = &voices[0];
        for (int i = 1; i < MAX_VOICES; i++) if (voices[i].age < v->age) v = &voices[i];
    }
    v->active = 1;
    v->sample = t->sample;
    v->pos = 0;
    v->step = (double)clampf(t->rate, 0.25f, 4.0f) * s->sampleRate / outRate;
    v->gainL = t->gainL;
    v->gainR = t->gainR;
    v->delayL = t->delayL > 0 ? t->delayL : 0;
    v->delayR = t->delayR > 0 ? t->delayR : 0;
    v->coefL = 1.0f - 0.85f * clampf(t->shadowL, 0, 1);
    v->coefR = 1.0f - 0.85f * clampf(t->shadowR, 0, 1);
    v->zL = v->zR = 0;
    v->age = ++voiceClock;
}

static inline float at(const float *data, uint32_t frames, int64_t i) {
    return (i < 0 || i >= (int64_t)frames) ? 0.0f : data[i];
}

/* 4-point Hermite: keeps more of the click's top end than linear interpolation when the rate jitters. */
static inline float read_interp(const float *data, uint32_t frames, double pos) {
    if (pos < 0 || pos >= (double)(frames - 1)) return 0.0f;
    int64_t i = (int64_t)pos;
    float t = (float)(pos - (double)i);
    float xm1 = at(data, frames, i - 1), x0 = data[i], x1 = data[i + 1], x2 = at(data, frames, i + 2);
    float c1 = 0.5f * (x1 - xm1);
    float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
    float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

void cm_render(float *outL, float *outR, uint32_t frames) {
    memset(outL, 0, sizeof(float) * frames);
    if (outR) memset(outR, 0, sizeof(float) * frames);

    /* 1. Acknowledge retirements before any sample data is touched this block. */
    for (int32_t i = 0; i < MAX_SAMPLES; i++) {
        if (atomic_load_explicit(&slots[i].state, memory_order_acquire) != SLOT_RETIRING) continue;
        for (int v = 0; v < MAX_VOICES; v++) {
            if (voices[v].active && voices[v].sample == i) voices[v].active = 0;
        }
        atomic_store_explicit(&slots[i].state, SLOT_RELEASED, memory_order_release);
    }
    if (atomic_exchange(&stopAllRequested, 0)) {
        for (int v = 0; v < MAX_VOICES; v++) voices[v].active = 0;
    }

    /* 2. Drain trigger queue. */
    double outRate = atomic_load(&outputRate);
    uint32_t tail = atomic_load_explicit(&queueTail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&queueHead, memory_order_acquire);
    while (tail != head) {
        start_voice(&queue[tail & (QUEUE_SIZE - 1)], outRate);
        tail++;
    }
    atomic_store_explicit(&queueTail, tail, memory_order_release);

    /* 3. Mix voices. */
    int32_t count = 0;
    for (int vi = 0; vi < MAX_VOICES; vi++) {
        voice_t *v = &voices[vi];
        if (!v->active) continue;
        const slot_t *s = &slots[v->sample];
        const float *L = s->left, *R = s->right;
        const uint32_t n = s->frames;
        const double end = (double)n + (v->delayL > v->delayR ? v->delayL : v->delayR);
        for (uint32_t i = 0; i < frames; i++) {
            float xl = read_interp(L, n, v->pos - v->delayL);
            float xr = read_interp(R, n, v->pos - v->delayR);
            v->zL += v->coefL * (xl - v->zL);
            v->zR += v->coefR * (xr - v->zR);
            if (outR) {
                outL[i] += v->zL * v->gainL;
                outR[i] += v->zR * v->gainR;
            } else {
                outL[i] += 0.5f * (v->zL * v->gainL + v->zR * v->gainR);
            }
            v->pos += v->step;
            if (v->pos >= end) { v->active = 0; break; }
        }
        if (v->active) count++;
    }
    atomic_store(&activeVoices, count);

    /* 4. Softness low-pass, master gain (smoothed) and a soft knee so chords never hard-clip. */
    update_lowpass(outRate);
    float target = atomic_load(&masterTarget);
    for (uint32_t i = 0; i < frames; i++) {
        masterCurrent += (target - masterCurrent) * 0.002f;
        for (int c = 0; c < 2; c++) {
            float *buf = c == 0 ? outL : outR;
            if (!buf) continue;
            float in = buf[i];
            float y = lpB0 * in + lpZ[c][0];
            lpZ[c][0] = lpB1 * in - lpA1 * y + lpZ[c][1];
            lpZ[c][1] = lpB2 * in - lpA2 * y;
            float x = y * masterCurrent;
            float ax = fabsf(x);
            if (ax > 0.8f) x = copysignf(0.8f + 0.2f * tanhf((ax - 0.8f) / 0.2f), x);
            buf[i] = x;
        }
    }
}
