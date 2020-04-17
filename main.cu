#pragma clang diagnostic push
#pragma ide diagnostic ignored "hicpp-signed-bitwise"
//#define __JETBRAINS_IDE__
// IDE indexing
#ifdef __JETBRAINS_IDE__
#define __host__
#define __device__
#define __constant__
#define __global__
#define __CUDACC__
#include <device_functions.h>
#include <__clang_cuda_builtin_vars.h>
#include <__clang_cuda_intrinsics.h>
#include <__clang_cuda_math_forward_declares.h>
#include <__clang_cuda_complex_builtins.h>
#include <__clang_cuda_cmath.h>
#endif

#ifdef __INTELLISENSE__

#include <cuda.h>
#include <cuda_runtime_api.h>
#include <cuda_runtime.h>
#define __CUDACC__ //fixes function defenition in ide
//void __syncthreads();

#include <device_launch_parameters.h>
#include <device_functions.h>
#include <device_atomic_functions.h>

#endif

#include <chrono>
#include <cstdint>
#include <thread>
#include <vector>
#include <mutex>
#include <atomic>
#include <iostream>
#include <iomanip>

#include "generator.h"

#define WRITE_BUFFER_SIZE 2048
#define MAX_NUMBER_LEN (21 + 1)
#define WRITE_BUFFER_USED (writeBufCur - writeBuffer)

#define RANDOM_MULTIPLIER_LONG 0x5DEECE66DULL

#define Random uint64_t
#define RANDOM_MULTIPLIER RANDOM_MULTIPLIER_LONG
#define RANDOM_ADDEND 0xBULL
#define RANDOM_MASK (1ULL << 48) - 1

// Random::next(bits)
__host__ __device__ inline uint32_t random_next(Random *random, int32_t bits) {
    *random = (*random * RANDOM_MULTIPLIER + RANDOM_ADDEND) & RANDOM_MASK;
    return (uint32_t)(*random >> (48 - bits));
}

// Random::nextInt(bound)
__host__ __device__ inline uint32_t random_next_int(Random *random, uint32_t bound) {
    int32_t r = random_next(random, 31);
    int32_t m = bound - 1;
    if ((bound & m) == 0) {
        // Could probably use __mul64hi here
        r = (uint32_t)((bound * (uint64_t)r) >> 31);
    } else {
        r %= bound;
    }
    return r;
}

#define CHECK_GPU_ERR(code) gpuAssert((code), __FILE__, __LINE__)
inline void gpuAssert(cudaError_t code, const char* file, int32_t line) {
    if (code != cudaSuccess) {
        fprintf(stderr, "GPUassert: %s (code %d) %s %d\n", cudaGetErrorString(code), code, file, line);
        exit(code);
    }
}

// advance
#define advance_rng(rand, multiplier, addend) ((rand) = ((rand) * (multiplier) + (addend)) & RANDOM_MASK)
#define advance_16(rand) advance_rng(rand, 0x6DC260740241LL, 0xD0352014D90LL)
#define advance_m1(rand) advance_rng(rand, 0xDFE05BCB1365LL, 0x615C0E462AA9LL)
#define advance_m3759(rand) advance_rng(rand, 0x63A9985BE4ADLL, 0xA9AA8DA9BC9BLL)



#define WATERFALL_X 16
//#define WATERFALL_Y 76
#define WATERFALL_Z 10

#define TREE_X (WATERFALL_X - 5)
#define TREE_Z (WATERFALL_Z - 8)
#define TREE_HEIGHT 5

#define OTHER_TREE_COUNT 1
__device__ inline int32_t getTreeHeight(int32_t x, int32_t z) {
    if (x == TREE_X && z == TREE_Z)
        return TREE_HEIGHT;

    if (x == WATERFALL_X - 3 && z == WATERFALL_Z + 3)
        return 5;

    return 0;
}



#define MODULUS (1LL << 48)
#define X_TRANSLATE 0
#define L00 7847617LL
#define L01 (-18218081LL)
#define LI00 (24667315.0 / 16)
#define LI01 (18218081.0 / 16)
#define LI10 (-4824621.0 / 16)
#define LI11 (7847617.0 / 16)

#define CONST_MIN(a, b) ((a) < (b) ? (a) : (b))
#define CONST_MIN4(a, b, c, d) CONST_MIN(CONST_MIN(a, b), CONST_MIN(c, d))
#define CONST_MAX(a, b) ((a) > (b) ? (a) : (b))
#define CONST_MAX4(a, b, c, d) CONST_MAX(CONST_MAX(a, b), CONST_MAX(c, d))
#define CONST_FLOOR(x) ((x) < (int64_t) (x) ? (int64_t) (x) - 1 : (int64_t) (x))
#define CONST_CEIL(x) ((x) == (int64_t) (x) ? (int64_t) (x) : CONST_FLOOR((x) + 1))

// for a parallelogram ABCD https://media.discordapp.net/attachments/668607204009574411/671018577561649163/unknown.png
#define B_X LI00
#define B_Z LI10
#define C_X (LI00 + LI01)
#define C_Z (LI10 + LI11)
#define D_X LI01
#define D_Z LI11
#define LOWER_X CONST_MIN4(0, B_X, C_X, D_X)
#define LOWER_Z CONST_MIN4(0, B_Z, C_Z, D_Z)
#define UPPER_X CONST_MAX4(0, B_X, C_X, D_X)
#define UPPER_Z CONST_MAX4(0, B_Z, C_Z, D_Z)
#define ORIG_SIZE_X (UPPER_X - LOWER_X + 1)
#define SIZE_X CONST_CEIL(ORIG_SIZE_X - D_X)
#define SIZE_Z CONST_CEIL(UPPER_Z - LOWER_Z + 1)
#define TOTAL_WORK_SIZE (SIZE_X * SIZE_Z)

#define MAX_TREE_ATTEMPTS 12
#define MAX_TREE_SEARCH_BACK (3 * MAX_TREE_ATTEMPTS - 3 + 16 * OTHER_TREE_COUNT)

__constant__ uint64_t search_back_multipliers[MAX_TREE_SEARCH_BACK + 1];
__constant__ uint64_t search_back_addends[MAX_TREE_SEARCH_BACK + 1];
int32_t search_back_count;

#define WORK_UNIT_SIZE (1LL << 25)
#define BLOCK_SIZE 256

__global__ void doPreWork(uint64_t offset, Random* starts, int* num_starts) {
    // lattice tree position
    uint64_t global_id = blockIdx.x * blockDim.x + threadIdx.x;

    int64_t lattice_x = (int64_t) ((offset + global_id) % SIZE_X) + LOWER_X;
    int64_t lattice_z = (int64_t) ((offset + global_id) / SIZE_X) + LOWER_Z;
    lattice_z += (B_X * lattice_z < B_Z * lattice_x) * SIZE_Z;
    if (D_X * lattice_z > D_Z * lattice_x) {
        lattice_x += B_X;
        lattice_z += B_Z;
    }
    lattice_x += (int64_t) (TREE_X * LI00 + TREE_Z * LI01);
    lattice_z += (int64_t) (TREE_X * LI10 + TREE_Z * LI11);

    auto rand = (Random)((lattice_x * L00 + lattice_z * L01 + X_TRANSLATE) % MODULUS);
    advance_m1(rand);

    Random tree_start = rand;
    advance_m1(tree_start);

    bool res = random_next(&rand, 4) == TREE_X;
    res &= random_next(&rand, 4) == TREE_Z;
    res &= random_next_int(&rand, 3) == (uint64_t) (TREE_HEIGHT - 4);

    if (res) {
        int index = atomicAdd(num_starts, 1);
        starts[index] = tree_start;
    }
}

__global__ void doWork(const int32_t* num_starts, const Random* tree_starts, int32_t* num_seeds, uint64_t* seeds, int32_t gpu_search_back_count) {
    for (int32_t i = blockIdx.x * blockDim.x + threadIdx.x; i < *num_starts; i += blockDim.x * gridDim.x) {
        Random tree_start = tree_starts[i];

        for (int32_t treeBackCalls = 0; treeBackCalls <= gpu_search_back_count; treeBackCalls++) {
            Random start = (tree_start * search_back_multipliers[treeBackCalls] + search_back_addends[treeBackCalls]) & RANDOM_MASK;
            Random rand = start;

            bool this_res = true;

            if (random_next_int(&rand, 10) == 0)
                continue;

            int32_t generated_tree[16];
            memset(generated_tree, 0x00, sizeof(generated_tree));

            int32_t treesMatched = 0;
            for (int32_t treeAttempt = 0; treeAttempt <= MAX_TREE_ATTEMPTS; treeAttempt++) {
                int32_t treeX = random_next(&rand, 4);
                int32_t treeZ = random_next(&rand, 4);
                int32_t wantedTreeHeight = getTreeHeight(treeX, treeZ);
                int32_t treeHeight = random_next_int(&rand, 3) + 4;

                int32_t& boolpack = generated_tree[treeX];
                const int32_t mask = 1 << (treeZ % 16);

                if (treeHeight == wantedTreeHeight && !(boolpack & mask)) {
                    treesMatched++;
                    boolpack |= mask;
                    advance_16(rand);
                }
            }

            this_res &= treesMatched >= OTHER_TREE_COUNT + 1;

            if (this_res) {
                Random start_chunk_rand = start;
                advance_m3759(start_chunk_rand);

                int32_t index = atomicAdd(num_seeds, 1);
                seeds[index] = start_chunk_rand;
            }

            advance_m1(start);
        }
    }
}

struct GPU_Node {
    int32_t* num_seeds;
    uint64_t* seeds;
    int32_t* num_tree_starts;
    Random* tree_starts;
};

void setup_gpu_node(GPU_Node* node, int32_t gpu) {
    CHECK_GPU_ERR(cudaSetDevice(gpu));
    CHECK_GPU_ERR(cudaMallocManaged(&node->num_seeds, sizeof(*node->num_seeds)));
    CHECK_GPU_ERR(cudaMallocManaged(&node->seeds, (sizeof(Random)*WORK_UNIT_SIZE)));
    CHECK_GPU_ERR(cudaMallocManaged(&node->num_tree_starts, sizeof(*node->num_tree_starts)));
    CHECK_GPU_ERR(cudaMallocManaged(&node->tree_starts, (sizeof(Random)*WORK_UNIT_SIZE)));
}


#ifndef GPU_COUNT
#define GPU_COUNT 1
#endif

void calculate_search_backs() {
    bool allow_search_back[MAX_TREE_SEARCH_BACK + 1];
    memset(allow_search_back, false, sizeof(allow_search_back));

    for (int32_t i = 0; i <= MAX_TREE_ATTEMPTS - OTHER_TREE_COUNT - 1; i++) {
        allow_search_back[i * 3] = true;
    }

    for (int32_t tree = 0; tree < OTHER_TREE_COUNT; tree++) {
        for (int32_t i = 0; i <= MAX_TREE_SEARCH_BACK - 19; i++) {
            if (allow_search_back[i])
                allow_search_back[i + 19] = true;
        }
    }

    search_back_count = 0;
    uint64_t multiplier = 1;
    uint64_t addend = 0;
    uint64_t multipliers[MAX_TREE_SEARCH_BACK + 1];
    uint64_t addends[MAX_TREE_SEARCH_BACK + 1];
    for (int32_t i = 0; i <= MAX_TREE_SEARCH_BACK; i++) {
        if (allow_search_back[i]) {
            int32_t index = search_back_count++;
            multipliers[index] = multiplier;
            addends[index] = addend;
        }
        multiplier = (multiplier * 0xDFE05BCB1365LL) & RANDOM_MASK;
        addend = (0xDFE05BCB1365LL * addend + 0x615C0E462AA9LL) & RANDOM_MASK;
    }

    for (int32_t gpu = 0; gpu < GPU_COUNT; gpu++) {
        CHECK_GPU_ERR(cudaSetDevice(gpu));
        CHECK_GPU_ERR(cudaMemcpyToSymbol(search_back_multipliers, &multipliers, search_back_count * sizeof(*multipliers)));
        CHECK_GPU_ERR(cudaMemcpyToSymbol(search_back_addends, &addends, search_back_count * sizeof(*addends)));
    }
}

#ifndef OFFSET
#define OFFSET 0
#endif

int main(int argc, char *argv[]) {
    random_math::JavaRand::init();
    generator::ChunkGenerator::init();

    auto *nodes = (GPU_Node*)malloc(sizeof(GPU_Node) * GPU_COUNT);
    std::cout << "Searching " << TOTAL_WORK_SIZE << " total seeds...\n";

    calculate_search_backs();

    FILE* out_file = fopen("chunk_seeds.txt", "w");

    for (int32_t i = 0; i < GPU_COUNT; i++) {
        setup_gpu_node(&nodes[i], i);
    }

    std::vector<std::thread> threads(std::thread::hardware_concurrency() - 4);
    std::mutex fileMutex;

    std::atomic<uint64_t> count(0);
    auto lastIteration = std::chrono::system_clock::now();
    auto startTime = std::chrono::system_clock::now();
    long long* tempStorage = nullptr;
    uint64_t arraySize = 0;

    std::cout << "Using " << threads.size() << " threads for cpu work\n";

    for (uint64_t offset = OFFSET; offset < TOTAL_WORK_SIZE;) {

        for (int32_t gpu_index = 0; gpu_index < GPU_COUNT; gpu_index++) {
            CHECK_GPU_ERR(cudaSetDevice(gpu_index));

            *nodes[gpu_index].num_tree_starts = 0;
            doPreWork<<<WORK_UNIT_SIZE / BLOCK_SIZE, BLOCK_SIZE>>>(offset, nodes[gpu_index].tree_starts, nodes[gpu_index].num_tree_starts);
            offset += WORK_UNIT_SIZE;
        }

        for (int32_t gpu_index = 0; gpu_index < GPU_COUNT; gpu_index++) {
            CHECK_GPU_ERR(cudaSetDevice(gpu_index));
            CHECK_GPU_ERR(cudaDeviceSynchronize());
        }

        for (int32_t gpu_index = 0; gpu_index < GPU_COUNT; gpu_index++) {
            CHECK_GPU_ERR(cudaSetDevice(gpu_index));

            *nodes[gpu_index].num_seeds = 0;
            doWork<<<WORK_UNIT_SIZE / BLOCK_SIZE, BLOCK_SIZE>>>(nodes[gpu_index].num_tree_starts, nodes[gpu_index].tree_starts, nodes[gpu_index].num_seeds, nodes[gpu_index].seeds, search_back_count);
        }

        static auto threadFunc = [&](size_t start, size_t end) {
            int32_t myCount = 0;
            char writeBuffer[2048];
            char* writeBufCur = writeBuffer;

            for (int32_t j = start; j < end; ++j) {
                if (WRITE_BUFFER_USED + MAX_NUMBER_LEN >= WRITE_BUFFER_SIZE) {
                    *writeBufCur++ = 0;
                    {
                        std::lock_guard<std::mutex> lock(fileMutex);
                        fprintf(out_file, "%s", writeBuffer);
                        fflush(out_file);
                    }
                    writeBufCur = writeBuffer;
                }
                if (generator::ChunkGenerator::populate(tempStorage[j], X_TRANSLATE + 16)) {
                    myCount++;
                    writeBufCur += snprintf(writeBufCur, MAX_NUMBER_LEN, "%lld\n", tempStorage[j]);
                }
            }

            // Finish up - write remainder and update atomic
            {
                std::lock_guard<std::mutex> lock(fileMutex);
                fprintf(out_file, "%s", writeBuffer);
                fflush(out_file);
            }
            count += myCount;
        };


        int32_t chunkSize = arraySize / threads.size();
        for(size_t i = 0; i < threads.size(); i++)
            threads[i] = std::thread(threadFunc, i * chunkSize, (i == (threads.size() - 1)) ? arraySize : ((i + 1) * chunkSize));

        for(std::thread& x : threads)
            x.join();

        fflush(out_file);
        free(tempStorage);

        tempStorage = (long long*)malloc(sizeof(long long));
        arraySize = 0;
        for (int32_t gpu_index = 0; gpu_index < GPU_COUNT; gpu_index++) {
            CHECK_GPU_ERR(cudaSetDevice(gpu_index));
            CHECK_GPU_ERR(cudaDeviceSynchronize());
            tempStorage = (long long*) realloc(tempStorage, (*nodes[gpu_index].num_seeds + arraySize) * sizeof(long long));
            for (int32_t i = 0, e = *nodes[gpu_index].num_seeds; i < e; i++) {
                tempStorage[arraySize+i]=nodes[gpu_index].seeds[i];
            }
            arraySize += *nodes[gpu_index].num_seeds;
        }

        auto iterFinish = std::chrono::system_clock::now();
        std::chrono::duration<double> iterationTime = iterFinish - lastIteration;
        std::chrono::duration<double> elapsedTime = iterFinish - startTime;
        lastIteration = iterFinish;
        uint64_t numSearched = offset + WORK_UNIT_SIZE * GPU_COUNT - OFFSET;
        double speed = numSearched / elapsedTime.count() / 1000000;
        double progress = (double)numSearched / (double)TOTAL_WORK_SIZE * 100.0;
        double estimatedTime = (double)(TOTAL_WORK_SIZE - numSearched) / speed / 1000000;
        uint64_t curCount = count;
        char suffix = 's';
        if (estimatedTime >= 3600) {
            suffix = 'h';
            estimatedTime /= 3600.0;
        } else if (estimatedTime >= 60) {
            suffix = 'm';
            estimatedTime /= 60.0;
        }
        if (progress >= 100.0) {
            estimatedTime = 0.0;
            suffix = 's';
        }
        std::cout << "Searched: " << std::setw(13) << numSearched << " seeds. Found: " << std::setw(13) << count.load() << " matches. Uptime: " <<
                std::fixed << std::setprecision(1) << elapsedTime.count() << "s. Speed: " << std::fixed <<
                std::setprecision(2) << speed << "m seeds/s. Completion: " << std::setprecision(2) << progress <<
                "%. ETA: " << std::fixed << std::setprecision(2) << estimatedTime << suffix << ".\n";
    }

    // Last batch to do
    for (int32_t j = 0; j < arraySize; ++j) {
        if (generator::ChunkGenerator::populate(tempStorage[j], X_TRANSLATE + 16)) {
            fprintf(out_file, "%lld\n", tempStorage[j]);
            count++;
        }
    }

    fflush(out_file);
    free(tempStorage);
    fclose(out_file);
}
