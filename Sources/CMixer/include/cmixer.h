#ifndef CMIXER_H
#define CMIXER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A request to start one voice. Produced on the main thread, consumed on the
/// real-time audio thread through a lock-free single-producer queue.
typedef struct {
    int32_t sample;   ///< id returned by cm_sample_add
    float rate;       ///< playback rate multiplier (1 = original pitch)
    float gainL;
    float gainR;
    float delayL;     ///< inter-aural delay in output frames (3-D mode)
    float delayR;
    float shadowL;    ///< 0..1 head-shadow low-pass amount per ear
    float shadowR;
} cm_trigger_t;

/// Copies the sample data. `right` may be NULL for mono. Main thread only.
/// Returns an id >= 0, or -1 when the sample table is full.
int32_t cm_sample_add(const float *left, const float *right, uint32_t frames, double sampleRate);

/// Marks a sample for removal; voices using it are stopped on the next render.
void cm_sample_retire(int32_t sample);

/// Frees retired samples that the render thread has released. Main thread only.
void cm_collect(void);

void cm_set_output_rate(double sampleRate);
void cm_set_master_gain(float gain);
void cm_stop_all(void);

/// Main thread only (single producer).
void cm_trigger(const cm_trigger_t *trigger);

/// Real-time thread only. Writes (not accumulates) `frames` samples.
void cm_render(float *outL, float *outR, uint32_t frames);

/// Number of voices currently sounding (approximate, for diagnostics).
int32_t cm_active_voices(void);

#ifdef __cplusplus
}
#endif

#endif
