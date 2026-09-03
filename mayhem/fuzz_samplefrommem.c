#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

#include <SDL3/SDL.h>
#include <SDL3_sound/SDL_sound.h>

#define READ_BUFF_SIZE 4096
bool lib_init = false;

void init_lib() {
    if (!Sound_Init())
        exit(0);
    lib_init = true;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!lib_init)
        init_lib();

    Sound_Sample *sample = Sound_NewSampleFromMem(data, size, NULL, NULL, READ_BUFF_SIZE);

    if (sample) {
        Sound_DecodeAll(sample);
        Sound_FreeSample(sample);
    }

    return 0;
}
