#pragma once

#include <sys/mman.h>

#include <cstddef>

namespace srv {

class BlockPool {
public:
    static constexpr size_t kBlockSize = 64 * 1024;

    explicit BlockPool(size_t max_blocks) : max_(max_blocks) {
        void *mem = mmap(nullptr, max_blocks * kBlockSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        base_ = mem == MAP_FAILED ? nullptr : static_cast<char *>(mem);
        if (!base_) max_ = 0;
    }

    ~BlockPool() {
        if (base_) munmap(base_, max_blocks_bytes());
    }

    BlockPool(const BlockPool &) = delete;
    BlockPool &operator=(const BlockPool &) = delete;

    char *take() {
        if (free_) {
            char *block = free_;
            free_ = *reinterpret_cast<char **>(block);
            ++in_use_;
            return block;
        }
        if (next_ < max_) {
            ++in_use_;
            return base_ + (next_++) * kBlockSize;
        }
        return nullptr;
    }

    void give(char *block) {
        *reinterpret_cast<char **>(block) = free_;
        free_ = block;
        --in_use_;
    }

    size_t in_use() const { return in_use_; }

private:
    size_t max_blocks_bytes() const { return max_ * kBlockSize; }

    char *base_ = nullptr;
    size_t max_ = 0;
    size_t next_ = 0;
    size_t in_use_ = 0;
    char *free_ = nullptr;
};

}
