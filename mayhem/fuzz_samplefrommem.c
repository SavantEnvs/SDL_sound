/*
 * mayhem/fuzz_samplefrommem.c - libFuzzer target: decode one in-memory input through SDL_sound's
 * public API (Sound_NewSampleFromMem -> Sound_DecodeAll -> Sound_FreeSample). No extension hint is
 * passed, so every built-in decoder probes the input.
 *
 * Known-answer report for mayhem/test.sh. test.sh runs THIS binary (the one PoV replay runs) once
 * per known-answer input with MAYHEM_SDLSOUND_KAT naming a file. The harness then also writes what
 * it decoded: the decoder, the output format and the sample flags go to that file, and the decoded
 * PCM goes to "<file>.pcm". test.sh compares both with mayhem/sdl-sound-kat.expected itself.
 * Fuzzing and PoV replay never set the variable, so they run the same code without the report.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

#include <SDL3/SDL.h>
#include <SDL3_sound/SDL_sound.h>

#define READ_BUFF_SIZE 4096
bool lib_init = false;
static const char *kat_path = NULL;

void init_lib() {
    if (!Sound_Init())
        exit(0);
    kat_path = getenv("MAYHEM_SDLSOUND_KAT");
    lib_init = true;
}

static void kat_report(const Sound_Sample *sample, Uint32 decoded) {
    char pcm_path[4096];
    FILE *f;

    if (snprintf(pcm_path, sizeof(pcm_path), "%s.pcm", kat_path) >= (int) sizeof(pcm_path))
        return;

    f = fopen(pcm_path, "wb");
    if (f) {
        if (decoded)
            fwrite(sample->buffer, 1, decoded, f);
        fclose(f);
    }

    f = fopen(kat_path, "w");
    if (f) {
        const Sound_DecoderInfo *d = sample->decoder;
        fprintf(f, "decoder=%s\n", (d && d->extensions && d->extensions[0]) ? d->extensions[0] : "-");
        fprintf(f, "format=0x%04x\n", (unsigned) sample->actual.format);
        fprintf(f, "channels=%d\n", (int) sample->actual.channels);
        fprintf(f, "rate=%d\n", (int) sample->actual.freq);
        fprintf(f, "eof=%d\n", (sample->flags & SOUND_SAMPLEFLAG_EOF) ? 1 : 0);
        fprintf(f, "error=%d\n", (sample->flags & SOUND_SAMPLEFLAG_ERROR) ? 1 : 0);
        fclose(f);
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!lib_init)
        init_lib();

    Sound_Sample *sample = Sound_NewSampleFromMem(data, size, NULL, NULL, READ_BUFF_SIZE);

    if (sample) {
        Uint32 decoded = Sound_DecodeAll(sample);
        if (kat_path && *kat_path)
            kat_report(sample, decoded);
        Sound_FreeSample(sample);
    }

    return 0;
}
