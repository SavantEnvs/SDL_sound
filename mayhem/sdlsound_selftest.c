/*
 * mayhem/sdlsound_selftest.c — functional known-answer test for SDL_sound.
 *
 * Decodes the bundled corpus files (one per supported format) through the public
 * SDL_sound API and ASSERTS observable decode results: that a decoder was selected,
 * the audio format/channels/rate are sane, and a non-trivial amount of PCM was
 * produced with the stream reaching EOF and no decode error. This is a behavioral
 * oracle — a patch that neuters the library to a no-op / exit(0) fails it.
 *
 * Usage: sdlsound_selftest <corpus-dir>
 * Exits 0 iff every expectation passes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <SDL3/SDL.h>
#include <SDL3_sound/SDL_sound.h>

#define BUF_SIZE 65536

typedef struct {
    const char *file;   /* corpus file name */
    const char *ext;    /* extension hint for the decoder */
    int min_channels;   /* expected channels (lower bound) */
    int max_channels;
} case_t;

/* The corpus shipped in mayhem/corpus — one representative file per decoder. */
static const case_t CASES[] = {
    { "StarWars3.wav",                                          "wav",  1, 2 },
    { "flac_r22k_1c_24b.flac",                                  "flac", 1, 2 },
    { "ogg_440hz_sine.ogg",                                     "ogg",  1, 2 },
    { "pcm_mulaw.au",                                           "au",   1, 2 },
    /* NOTE: mp3_mpg321_*.mp3 is a deliberately-corrupt fuzz SEED (no valid MP3 frame
     * sync / ID3 header) — kept in the fuzz corpus to exercise the decoder's reject path,
     * but it is NOT a clean decodable file, so it is not a known-answer test case here.
     * The MPEG decoder's success path is covered by the .mp1 and .mp2 cases below. */
    { "test22.mp1",                                             "mp1",  1, 2 },
    { "mp2_test30.mp2",                                         "mp2",  1, 2 },
};
#define NCASES ((int)(sizeof(CASES)/sizeof(CASES[0])))

static uint8_t *slurp(const char *path, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return NULL; }
    uint8_t *buf = (uint8_t *)malloc((size_t)n);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) { free(buf); return NULL; }
    *out_len = got;
    return buf;
}

int main(int argc, char **argv)
{
    const char *dir = (argc > 1) ? argv[1] : "mayhem/corpus";

    /* Decode without touching a real audio device. */
    SDL_setenv_unsafe("SDL_AUDIODRIVER", "dummy", 1);

    if (!Sound_Init()) {
        fprintf(stderr, "Sound_Init() failed: %s\n", Sound_GetError());
        return 2;
    }

    int passed = 0, failed = 0;

    for (int i = 0; i < NCASES; i++) {
        const case_t *c = &CASES[i];
        char path[1024];
        snprintf(path, sizeof(path), "%s/%s", dir, c->file);

        size_t len = 0;
        uint8_t *data = slurp(path, &len);
        if (!data) {
            fprintf(stderr, "FAIL %-12s could not read %s\n", c->ext, path);
            failed++;
            continue;
        }

        Sound_Sample *s = Sound_NewSampleFromMem(data, (Uint32)len, c->ext, NULL, BUF_SIZE);
        if (!s) {
            fprintf(stderr, "FAIL %-12s Sound_NewSampleFromMem: %s\n", c->ext, Sound_GetError());
            free(data);
            failed++;
            continue;
        }

        int ok = 1;
        char why[256] = "";

        if (!s->decoder || !s->decoder->description) {
            ok = 0; snprintf(why, sizeof(why), "no decoder selected");
        } else if (s->actual.channels < c->min_channels || s->actual.channels > c->max_channels) {
            ok = 0; snprintf(why, sizeof(why), "channels=%d out of [%d,%d]",
                             s->actual.channels, c->min_channels, c->max_channels);
        } else if (s->actual.freq <= 0) {
            ok = 0; snprintf(why, sizeof(why), "freq=%d", s->actual.freq);
        } else {
            Uint32 total = Sound_DecodeAll(s);
            if (s->flags & SOUND_SAMPLEFLAG_ERROR) {
                ok = 0; snprintf(why, sizeof(why), "decode error flag set");
            } else if (total == 0) {
                ok = 0; snprintf(why, sizeof(why), "decoded 0 bytes");
            } else if (!(s->flags & SOUND_SAMPLEFLAG_EOF)) {
                ok = 0; snprintf(why, sizeof(why), "did not reach EOF");
            } else {
                printf("PASS %-12s decoder=%s ch=%d freq=%d bytes=%u\n",
                       c->ext, s->decoder->description, s->actual.channels,
                       s->actual.freq, total);
            }
        }

        if (!ok) {
            fprintf(stderr, "FAIL %-12s %s\n", c->ext, why);
            failed++;
        } else {
            passed++;
        }

        Sound_FreeSample(s);
        free(data);
    }

    Sound_Quit();

    printf("SELFTEST passed=%d failed=%d total=%d\n", passed, failed, NCASES);
    return failed == 0 ? 0 : 1;
}
