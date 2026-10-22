#include <cstddef>
#include <new>

void *operator new[](size_t size, const char *, int, unsigned, const char *, int) {
    return ::operator new[](size);
}

void *operator new[](size_t size, size_t alignment, size_t, const char *, int, unsigned, const char *, int) {
    return ::operator new[](size, std::align_val_t(alignment));
}
